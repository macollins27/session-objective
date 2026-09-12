# shellcheck shell=bash
# SO-ROLE: lib
# objective-lib.sh — shared payload parsing, path resolution and objective-file
# parsing for every session-objective hook.
#
# FAILURE DIRECTION (audited 2026-09-12): FAILS CLOSED.
#   jq missing                    -> exit 2 (F13), install command on stderr
#   stdin is not a JSON object    -> exit 2
#   session_id absent             -> exit 2 (no key, therefore no file, therefore no rule)
#   objective file unreadable     -> the CALLER decides; the helpers return empty and
#                                    every caller that gates on emptiness denies.
#   SESSION_OBJECTIVE=off         -> the caller exits 0 with one visible line (F11).
#
# Every helper here is pure: it reads files and the cached payload, and writes
# nothing. The only writers in this repo are the ledger-append hook and the subagent
# seed hook. Nothing an agent can invoke writes to the ledger: the operator typing a
# message is the only thing that ever appends an entry.

# ---------------------------------------------------------------------------
# FAIL-CLOSED INPUT VALIDATION
# ---------------------------------------------------------------------------
# Claude Code treats exit 2 as BLOCK and ANY OTHER non-zero exit as a NON-BLOCKING
# error, which lets the tool PROCEED. A guard that cannot parse its input and exits
# 1 has allowed the thing it exists to refuse. So: unparseable input is exit 2.

SO_PAYLOAD=""

so_fatal() { # <message...>
  printf 'session-objective: %s\n' "$*" >&2
  exit 2
}

so_require_jq() {
  command -v jq >/dev/null 2>&1 || so_fatal \
    "jq not found; cannot parse the hook payload, so this hook cannot evaluate anything. Failing CLOSED. Install it: brew install jq"
}

# The fleet switch (F11). A headless or automated session sets SESSION_OBJECTIVE=off
# and every hook stands down with ONE visible line, so an un-endable turn can never
# wedge automation. Any other value (including unset) leaves the hooks armed.
so_disabled() {
  if [ "${SESSION_OBJECTIVE:-}" = "off" ]; then
    printf 'session-objective: disabled by SESSION_OBJECTIVE=off (fleet switch); no objective rule is in force this session.\n' >&2
    return 0
  fi
  return 1
}

so_read_payload() {
  so_require_jq
  SO_PAYLOAD="$(cat)"
  [ -n "$SO_PAYLOAD" ] || so_fatal "empty stdin; expected a hook JSON payload. Failing CLOSED."
  jq -e 'type == "object"' >/dev/null 2>&1 <<< "$SO_PAYLOAD" \
    || so_fatal "stdin did not parse as a JSON object. Failing CLOSED."
}

so_field() { # <jq-path-without-leading-dot>
  jq -r ".$1 // empty" <<< "$SO_PAYLOAD" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
so_home() {
  printf '%s' "${SESSION_OBJECTIVE_HOME:-$HOME/.session-objective}"
}

# The file key. Settled empirically 2026-09-12 (docs/payload-evidence/):
# inside a subagent, PreToolUse/PostToolUse carry the PARENT's session_id and the
# subagent's own agent_id. Parent and child would therefore share one file and write
# over each other, which breaks the one-writer rule — so whenever agent_id is present
# the key is <session_id>/<agent_id>.
so_key() {
  local sid aid
  sid="$(so_field session_id)"
  aid="$(so_field agent_id)"
  [ -n "$sid" ] || so_fatal "payload carries no session_id; cannot resolve an objective file. Failing CLOSED."
  case "$sid$aid" in
    */*|*..*) so_fatal "session_id/agent_id contains a path separator; refusing to resolve a file from it." ;;
  esac
  if [ -n "$aid" ]; then printf '%s/%s' "$sid" "$aid"; else printf '%s' "$sid"; fi
}

so_file() {
  printf '%s/sessions/%s/objective.md' "$(so_home)" "$(so_key)"
}

# ---------------------------------------------------------------------------
# File parsing
# ---------------------------------------------------------------------------
SO_LEDGER_HEAD='# OPERATOR LEDGER (hook-written, append-only, agent may not edit)'
SO_SECTIONS='DESIRED OUTCOME|SUCCESS CONDITIONS|CONSTRAINTS|REJECTED INTERPRETATIONS|FAILED APPROACHES|CURRENT REALITY|FRONTIER|STATUS'

# Everything up to, but not including, the OBJECTIVE heading.
so_ledger_layer() { # <file>
  awk '/^# OBJECTIVE \(/ { exit } { print }' "$1" 2>/dev/null || true
}

# Everything after the OBJECTIVE heading.
so_objective_layer() { # <file>
  awk 'f { print } /^# OBJECTIVE \(/ { f = 1 }' "$1" 2>/dev/null || true
}

so_objective_heading() { # <file>
  grep -m1 -E '^# OBJECTIVE \(' "$1" 2>/dev/null || true
}

so_ledger_count() { # <file>
  local n
  n="$(so_ledger_layer "$1" | grep -cE '^- [0-9]{4}-[0-9]{2}-[0-9]{2}T' || true)"
  printf '%s' "${n:-0}"
}

so_bound() { # <file>  -> the K in "bound to ledger entry K", or empty if unparseable
  so_objective_heading "$1" | sed -nE 's/.*bound to ledger entry ([0-9]+).*/\1/p' | head -1
}

so_revision() { # <file>
  so_objective_heading "$1" | sed -nE 's/.*revision ([0-9]+).*/\1/p' | head -1
}

# Body of one OBJECTIVE section, in file order. An inline value on the heading line
# ("STATUS ACTIVE", "STATUS: ACTIVE") is emitted as the section's first line.
so_section() { # <file> <SECTION NAME>
  so_objective_layer "$1" | awk -v want="$2" -v names="$SO_SECTIONS" '
    BEGIN { n = split(names, H, "|") }
    function head(line,   i, nm, rest) {
      for (i = 1; i <= n; i++) {
        nm = H[i]
        if (substr(line, 1, length(nm)) != nm) continue
        rest = substr(line, length(nm) + 1)
        if (rest == "" || rest ~ /^[[:space:]]/ || rest ~ /^:/) { HEAD = nm; INLINE = rest; return 1 }
      }
      return 0
    }
    {
      if (head($0)) {
        cur = HEAD
        sub(/^[[:space:]]*:?[[:space:]]*/, "", INLINE)
        if (cur == want && INLINE != "") print INLINE
        next
      }
      if (cur == want) print
    }'
}

so_trim() { sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//' ; }

# A section entry stripped of its bullet, for comparison.
so_entries() { # <file> <SECTION NAME>
  so_section "$1" "$2" | sed -E 's/^[[:space:]]*[-*][[:space:]]+//' | so_trim | grep -v '^$' || true
}

so_status() { # <file> -> ACTIVE | NEEDS-DECISION: ... | COMPLETE | empty
  so_section "$1" STATUS | so_trim | grep -v '^$' | head -1 || true
}

so_frontier() { # <file>
  so_section "$1" FRONTIER | so_trim | grep -v '^$' | head -5 || true
}

# ---------------------------------------------------------------------------
# Deny shapes
# ---------------------------------------------------------------------------
# PreToolUse denies with hookSpecificOutput.permissionDecision "deny" on stdout and
# exit 0; Stop denies with exit 2 and stderr. Both shapes are the spec's, verbatim.
so_deny_pretooluse() { # <reason...>
  jq -cn --arg r "$*" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

# The mirror of so_deny_pretooluse. The objective file lives OUTSIDE the project by
# design, so in `default` and `acceptEdits` a Read or Write of it needs the operator's
# permission — and in a headless session nobody is there to grant it. Measured
# 2026-09-12: the permission system refused the Read ("Claude requested permissions to
# read from …, but you haven't granted it yet") while the lock refused everything else,
# and the session wedged on message one. So the gate does not merely stand aside for
# the two calls Rule 1 permits: it ALLOWS them explicitly, which is the only decision
# that clears the prompt. It grants nothing beyond this session's own objective file —
# the file the hook itself just injected — and every other tool call is untouched.
so_allow_pretooluse() { # <reason...>
  jq -cn --arg r "$*" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",permissionDecisionReason:$r}}'
  exit 0
}

so_now() { date -u +%Y-%m-%dT%H:%MZ; }
so_today() { date -u +%Y-%m-%d; }

# The empty objective template written for a brand-new session.
so_template() {
  cat <<'TPL'
# OBJECTIVE (agent-written, rewritten every turn, revision 0, bound to ledger entry 0)
DESIRED OUTCOME

SUCCESS CONDITIONS

CONSTRAINTS

REJECTED INTERPRETATIONS

FAILED APPROACHES

CURRENT REALITY

FRONTIER

STATUS
ACTIVE
TPL
}

# ---------------------------------------------------------------------------
# Path resolution (F9)
# ---------------------------------------------------------------------------
# A relative path, a `~`, a `..` segment or a symlink must not be able to reach the
# objective file behind the guard's back. Resolved with cd/pwd -P plus a bounded
# readlink loop, so the guard depends on nothing but bash.
so_realpath() { # <path> [base-dir]
  local p="$1" base="${2:-$PWD}" i=0 t d rest real
  [ -n "$p" ] || return 0
  case "$p" in "~"|"~/"*) p="$HOME${p#\~}" ;; esac
  case "$p" in /*) ;; *) p="$base/$p" ;; esac
  # Follow a symlinked final component while one exists.
  while [ -L "$p" ] && [ "$i" -lt 10 ]; do
    t="$(readlink "$p")"
    case "$t" in /*) p="$t" ;; *) p="$(dirname "$p")/$t" ;; esac
    i=$((i + 1))
  done
  # Collapse "." and ".." textually, so sessions/../sessions/<id> cannot slip past
  # the prefix comparison.
  p="$(printf '%s' "$p" | awk -F/ '{
    n = 0
    for (i = 1; i <= NF; i++) {
      if ($i == "" || $i == ".") continue
      if ($i == "..") { if (n > 0) n--; continue }
      st[++n] = $i
    }
    out = ""
    for (i = 1; i <= n; i++) out = out "/" st[i]
    print (out == "" ? "/" : out)
  }')"
  # Resolve the longest EXISTING directory prefix with pwd -P, then re-attach the
  # rest. Without this a path whose parent does not exist yet keeps an unresolved
  # ancestor (/var vs /private/var on macOS) and silently fails every comparison
  # against a path that WAS resolved — which is a guard that allows what it names.
  [ -n "$p" ] || return 0
  case "$p" in /*) ;; *) return 0 ;; esac
  d="$p"; rest=""
  while [ ! -d "$d" ] && [ "$d" != "/" ] && [ "$d" != "." ] && [ -n "$d" ]; do
    rest="$(basename "$d")${rest:+/$rest}"
    d="$(dirname "$d")"
  done
  real="$( cd "$d" 2>/dev/null && pwd -P )" || real="$d"
  [ -n "$real" ] || real="$d"
  case "$real" in /) printf '/%s' "$rest" ;; *) if [ -n "$rest" ]; then printf '%s/%s' "$real" "$rest"; else printf '%s' "$real"; fi ;; esac
}

# ---------------------------------------------------------------------------
# PROOF denylists
# ---------------------------------------------------------------------------
# F3 — a proof that cannot fail proves nothing. Trivial means the WHOLE command
# cannot fail: every composition segment's OUTER command is a bare `true`, `:`,
# `exit 0`, `echo` or `printf`. A pipeline or a real command anywhere in it makes the
# exit code depend on something, so it is a proof.
#
# TWO MEASURED DEFECTS, BOTH FIXED (2026-09-12):
#   * The first version anchored `^echo .*$` / `^printf .*$`, so it refused the genuine
#     proof `printf 'shipped' | cmp -s - done.txt` for starting with printf. A guard
#     that refuses the real proof trains the agent to write a weaker one.
#   * The second version treated a command substitution as evidence of real work and
#     returned "proof" for anything containing one — so `echo $(false)` passed, and the
#     Stop gate accepted STATUS COMPLETE on it. A simple command's exit status is its
#     own; the status inside `$(...)` does not propagate, so `echo $(false)` exits 0
#     every time. Substitutions are therefore ERASED before classifying, and what is
#     judged is the outer command that actually sets the exit code.
so_strip_substitutions() { # <command> -> the command with every $(...), `...`, <(...) replaced by X
  local c="$1" prev=""
  local i=0
  while [ "$c" != "$prev" ] && [ "$i" -lt 20 ]; do
    prev="$c"
    c="$(printf '%s' "$c" | sed -E 's/[$]\([^()]*\)/X/g; s/<\([^()]*\)/X/g; s/`[^`]*`/X/g')"
    i=$((i + 1))
  done
  printf '%s' "$c"
}

so_proof_trivial() { # <command>
  local c seg
  c="$(printf '%s' "$1" | so_trim)"
  [ -z "$c" ] && return 0
  c="$(so_strip_substitutions "$c")"
  while IFS= read -r seg; do
    seg="$(printf '%s' "$seg" | sed -E 's/[<>]+[[:space:]]*[^[:space:]]*//g' | so_trim)"
    [ -z "$seg" ] && continue
    grep -qE '^(true|/bin/true|:|exit[[:space:]]+0)$' <<< "$seg" && continue
    grep -qE '^(echo|printf|/bin/echo|/usr/bin/printf)([[:space:]].*)?$' <<< "$seg" && continue
    return 1
  done <<< "$(printf '%s' "$c" | awk '{ gsub(/\|\||&&|;|\|/, "\n"); print }')"
  return 0
}

# F4 — the Stop hook RE-RUNS proof commands. A proof that deletes, pushes, resets,
# elevates, reaches the network with a method, drives docker or redirects into a file
# would make verification itself destructive, so it is never executed: COMPLETE is
# denied naming the condition instead.
so_proof_destructive() { # <command>
  local c; c="$(printf '%s' "$1" | so_trim)"
  grep -qE '(^|[;&|[:space:]])(sudo|rm|rmdir|shred|mkfs|dd|docker|podman|kubectl|systemctl|launchctl|chown|chmod|mv|truncate)([[:space:]]|$)' <<< "$c" && return 0
  grep -qE '(^|[;&|[:space:]])git[[:space:]]+(push|reset|clean|checkout|rebase|merge|commit|filter-branch|gc|prune)([[:space:]]|$)' <<< "$c" && return 0
  grep -qE 'curl[^|;&]*(-X|--request)([[:space:]]|=)' <<< "$c" && return 0
  grep -qE '(^|[^0-9<>&])>' <<< "$c" && return 0
  return 1
}

# Run one PROOF command with a hard time bound, in the session cwd, never elevated.
# Returns the command's exit code; 124 if it was killed on the time bound.
so_run_bounded() { # <seconds> <command> <cwd>
  local secs="$1" cmd="$2" dir="$3" tb rc p w
  tb="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
  if [ -n "$tb" ]; then
    ( cd "$dir" 2>/dev/null || exit 127; "$tb" "$secs" bash -c "$cmd" >/dev/null 2>&1 )
    return $?
  fi
  (
    cd "$dir" 2>/dev/null || exit 127
    bash -c "$cmd" >/dev/null 2>&1 & p=$!
    ( sleep "$secs"; kill -9 "$p" 2>/dev/null ) & w=$!
    wait "$p"; rc=$?
    kill "$w" 2>/dev/null
    exit "$rc"
  )
}

# Append one operator message to the ledger VERBATIM and reset STATUS to ACTIVE (F2).
# Called from exactly one place, the UserPromptSubmit hook, and deliberately: an
# agent-invocable way to add a ledger entry is an agent-invocable way to put words in
# the operator's mouth. Returns non-zero if the file could not be rewritten.
so_append_entry() { # <file> <text>
  local file="$1" text="$2" tmp
  [ -n "$(so_objective_heading "$file")" ] || return 1
  tmp="$(mktemp "${TMPDIR:-/tmp}/so-append.XXXXXX")" || return 1
  {
    so_ledger_layer "$file" | awk '
      BEGIN { blank = 0 }
      { if ($0 == "") { blank++ } else { for (i = 0; i < blank; i++) print ""; blank = 0; print } }'
    printf -- '- %s  %s\n' "$(so_now)" "$text"
    printf '\n'
    so_objective_heading "$file"
    so_objective_layer "$file" | awk -v names="$SO_SECTIONS" '
      BEGIN { n = split(names, H, "|") }
      function head(line,   i, nm, rest) {
        for (i = 1; i <= n; i++) {
          nm = H[i]
          if (substr(line, 1, length(nm)) != nm) continue
          rest = substr(line, length(nm) + 1)
          if (rest == "" || rest ~ /^[[:space:]]/ || rest ~ /^:/) { HEAD = nm; return 1 }
        }
        return 0
      }
      {
        if (head($0)) {
          cur = HEAD
          if (cur == "STATUS") { print "STATUS"; print "ACTIVE"; seen = 1; next }
          print; next
        }
        if (cur == "STATUS") next
        print
      }
      END { if (!seen) { print "STATUS"; print "ACTIVE" } }'
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  cat "$tmp" > "$file" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  return 0
}

# ---------------------------------------------------------------------------
# Runtime, and the tool that rewrites the objective in it
# ---------------------------------------------------------------------------
# Claude Code stamps `prompt_id` on its events; Codex stamps `turn_id`. Measured on
# both runtimes 2026-09-12 (docs/payload-evidence/). The distinction matters for one
# reason only: Codex exposes no Write tool, so the instruction that releases the
# write-before-act lock has to name the tool the agent actually has.
so_runtime() {
  local t p
  t="$(so_field turn_id)"; p="$(so_field prompt_id)"
  if [ -n "$t" ] && [ -z "$p" ]; then printf 'codex'; else printf 'claude'; fi
}

# The one sentence that tells the agent how to rewrite the file, in its own runtime.
so_write_instruction() { # <objective-file>
  if [ "$(so_runtime)" = "codex" ]; then
    printf 'apply_patch, with exactly one file operation, on exactly this path: %s' "$1"
  else
    printf 'the Write tool, with file_path exactly: %s' "$1"
  fi
}

# ---------------------------------------------------------------------------
# Codex apply_patch (F17 — the Codex half of Rule 1)
# ---------------------------------------------------------------------------
# Codex has no Write tool. Its only file-writing tool is `apply_patch`, whose
# tool_input is one `command` string holding a patch. The target path is inside that
# text, on the `*** Add File: `, `*** Update File: `, `*** Delete File: ` and
# `*** Move to: ` lines, so the guard reads it there — the same shape
# ~/Developer/vision-to-plan/scripts/block-codex-tools.py reads.

# Every path a patch would touch, one per line, unresolved.
so_patch_targets() { # <patch-text>
  printf '%s\n' "$1" | sed -nE 's/^\*\*\* (Add File|Update File|Delete File|Move to): (.*)$/\2/p'
}

# The file operations a patch declares, one per line (Add|Update|Delete|Move).
so_patch_ops() { # <patch-text>
  printf '%s\n' "$1" | sed -nE 's/^\*\*\* (Add|Update|Delete) File: .*$/\1/p; s/^\*\*\* (Move) to: .*$/\1/p'
}

# Produce the file the patch WOULD leave on disk, into <out>.
#
# An Add File hunk carries the whole content, so it is read straight out of the `+`
# lines. An Update File hunk is a partial diff — the real Codex patches measured here
# replace only the OBJECTIVE layer and never mention the ledger — so reconstructing it
# by hand would be a second parser that can disagree with the one Codex will actually
# run, and a guard that checks content Codex will not write is a guard that fails OPEN.
# So the applier is Codex's own: `codex --codex-run-as-apply-patch`, against a COPY.
# Its stdout is discarded because stdout is this hook's deny channel.
#
# Returns 0 on success; 1 with a reason on stderr when the patch cannot be evaluated,
# and every caller turns that into a denial.
so_apply_patch_to_copy() { # <patch-text> <current-file> <out-file>
  local patch="$1" cur="$2" out="$3" op tmpdir rewritten codexbin
  op="$(so_patch_ops "$patch" | head -1)"
  case "$op" in
    Add)
      printf '%s\n' "$patch" \
        | awk '/^\*\*\* (Add|Update|Delete) File: /{f=1; next} /^\*\*\* End Patch$/{f=0} f && /^\+/{print substr($0,2)}' > "$out"
      [ -s "$out" ] || { printf 'the patch adds no content\n' >&2; return 1; }
      return 0
      ;;
    Update)
      codexbin="$(command -v codex 2>/dev/null || true)"
      [ -n "$codexbin" ] || { printf 'an Update File patch can only be evaluated by Codex own patch parser, and the codex binary is not on PATH\n' >&2; return 1; }
      tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/so-patch.XXXXXX")" || return 1
      cp "$cur" "$tmpdir/objective.md" || { rm -rf "$tmpdir"; return 1; }
      rewritten="$(printf '%s\n' "$patch" | awk -v t="$tmpdir/objective.md" '
        /^\*\*\* Update File: /{ print "*** Update File: " t; next } { print }')"
      if ! "$codexbin" --codex-run-as-apply-patch "$rewritten" >/dev/null 2>&1; then
        printf 'the patch does not apply to the current file\n' >&2
        rm -rf "$tmpdir"; return 1
      fi
      cat "$tmpdir/objective.md" > "$out" || { rm -rf "$tmpdir"; return 1; }
      rm -rf "$tmpdir"
      return 0
      ;;
    *)
      printf 'only an Add File or an Update File operation can rewrite the objective\n' >&2
      return 1
      ;;
  esac
}
