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
SO_WORKFLOW_HEAD='# WORKFLOW (interpreter-written with the objective; the fixed skeleton, filled for this task)'
SO_PROGRESS_HEAD='# PROGRESS (agent-written)'
# Order matters: MUST NOT is tested before MUST, or a "MUST NOT" heading reads as a
# "MUST" heading with an inline value of "NOT".
SO_OBJ_SECTIONS='OUTCOME|MUST NOT|MUST|DONE WHEN|OPEN QUESTION'
# 3.0: CURRENT REALITY and FRONTIER are gone. They were rewritten every turn by the
# same drifting context they were meant to correct, and 11 of 57 measured files carried
# an empty one. CHECKPOINTS replaces them: a proof line per checkpoint, append-only,
# each one run at the moment it is recorded.
SO_PROG_SECTIONS='CHECKPOINTS|PROOFS|IN FLIGHT|STATUS'

# The four-checkpoint skeleton. C1 and C2 are the interpreter's, per task. C3 and C4 are
# FIXED TEXT: C3 is satisfied when every D-item proof reproduces, C4 from the transcript,
# so neither carries a proof line of its own and neither is the model's to reword.
SO_C3_TEXT='C3 PROVE — every DONE WHEN item has a proof that reproduces'
SO_C4_TEXT='C4 VERIFY — a fresh-context verifier ran after the last change and returned PASS'
# The generic skeleton the hook falls back to when the interpreter could not produce a
# usable WORKFLOW twice running. It is weaker than a task-specific one and it still
# orders the work, which is the whole point of the lock.
SO_C1_GENERIC='C1 UNDERSTAND — the current state of everything the outcome touches has been observed'
SO_C2_GENERIC='C2 BUILD — the outcome exists as the objective describes it'
SO_CONVERSATION_WORKFLOW='none (conversation)'

# Three layers in 2.0, one writer each:
#   LEDGER    the hook, from genuine operator prompts only
#   OBJECTIVE the interpreter, from the ledger only
#   PROGRESS  the agent
so_ledger_layer() { # <file>
  awk '/^# OBJECTIVE \(/ { exit } { print }' "$1" 2>/dev/null || true
}
so_objective_layer() { # <file>  (body only, heading excluded)
  awk '/^# (WORKFLOW|PROGRESS) \(/ { exit } f { print } /^# OBJECTIVE \(/ { f = 1 }' "$1" 2>/dev/null || true
}
so_workflow_layer() { # <file>  (body only, heading excluded; empty on a 2.x file)
  awk '/^# PROGRESS \(/ { exit } f { print } /^# WORKFLOW \(/ { f = 1 }' "$1" 2>/dev/null || true
}
so_workflow_heading() { # <file>
  grep -m1 -E '^# WORKFLOW \(' "$1" 2>/dev/null || true
}
so_progress_layer() { # <file>  (body only, heading excluded)
  awk 'f { print } /^# PROGRESS \(/ { f = 1 }' "$1" 2>/dev/null || true
}
so_objective_heading() { # <file>
  grep -m1 -E '^# OBJECTIVE \(' "$1" 2>/dev/null || true
}
so_progress_heading() { # <file>
  grep -m1 -E '^# PROGRESS \(' "$1" 2>/dev/null || true
}

so_ledger_count() { # <file>
  local n
  n="$(so_ledger_layer "$1" | grep -cE '^- [0-9]{4}-[0-9]{2}-[0-9]{2}T' || true)"
  printf '%s' "${n:-0}"
}
so_ledger_last_ts() { # <file>
  so_ledger_layer "$1" | grep -E '^- [0-9]{4}-[0-9]{2}-[0-9]{2}T' | tail -1 \
    | sed -E 's/^- ([0-9T:Z-]+) .*/\1/' || true
}

so_bound() { # <file>  -> the K in "bound to ledger entry K"
  so_objective_heading "$1" | sed -nE 's/.*bound to ledger entry ([0-9]+).*/\1/p' | head -1
}
so_revision() { # <file>
  so_objective_heading "$1" | sed -nE 's/.*revision ([0-9]+).*/\1/p' | head -1
}

# Body of one section of a given layer. An inline value on the heading line is
# emitted as the section's first line.
so_section_of() { # <layer text> <section-name list> <wanted section>
  printf '%s\n' "$1" | awk -v want="$3" -v names="$2" '
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

so_obj_section() {  so_section_of "$(so_objective_layer "$1")" "$SO_OBJ_SECTIONS"  "$2"; }
so_prog_section() { so_section_of "$(so_progress_layer  "$1")" "$SO_PROG_SECTIONS" "$2"; }

so_trim() { sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//' ; }

so_entries_of() { # <layer text> <names> <section>
  so_section_of "$1" "$2" "$3" | sed -E 's/^[[:space:]]*[-*][[:space:]]+//' | so_trim | grep -v '^$' || true
}
so_obj_entries()  { so_entries_of "$(so_objective_layer "$1")" "$SO_OBJ_SECTIONS"  "$2"; }
so_prog_entries() { so_entries_of "$(so_progress_layer  "$1")" "$SO_PROG_SECTIONS" "$2"; }

# STATUS lives in PROGRESS.
so_status() {   so_prog_section "$1" STATUS   | so_trim | grep -v '^$' | head -1 || true; }

# The D-items the interpreter declared, as bare ids (D1, D2 ...).
so_done_ids() { # <file>
  so_obj_section "$1" "DONE WHEN" | sed -nE 's/^[[:space:]]*(D[0-9]+)([[:space:]].*)?$/\1/p' || true
}
# The PROGRESS proof line for one D-item, if any.
so_proof_line() { # <file> <Dn>
  so_prog_section "$1" PROOFS | grep -E "^[[:space:]]*$2[[:space:]]" | head -1 || true
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
    # cannot fail, by construction
    grep -qE '^(true|/bin/true|:|exit[[:space:]]+0)$' <<< "$seg" && continue
    grep -qE '^(echo|printf|/bin/echo|/usr/bin/printf)([[:space:]].*)?$' <<< "$seg" && continue
    # A BARE WORD proves nothing about anything. Measured 2026-09-13: `date` attached to a
    # D-item about a file that did not exist passed both gates and the session reported
    # COMPLETE. A command with no argument, no path and no operator cannot be about the
    # outcome it is attached to; it only reports that the machine is running. The
    # over-block this buys is real and cheap: a bare `make` is refused, and `make check`
    # is not.
    grep -qE '^[A-Za-z_][A-Za-z0-9_-]*$' <<< "$seg" && continue
    # and these report the machine's own state whatever arguments they are given
    grep -qE '^(date|pwd|whoami|hostname|id|uname|uptime|sleep)([[:space:]].*)?$' <<< "$seg" && continue
    return 1
  done <<< "$(printf '%s' "$c" | awk '{ gsub(/\|\||&&|;|\|/, "\n"); print }')"
  return 0
}

# The reply form. Some outcomes ARE the reply: advice, a recommendation, an answer.
# Measured 2026-09-12 on a real advice-only session: to satisfy the per-condition PROOF
# rule the agent invented `test ! -e <scratchpad>/code-written.flag => exit 0` — a file
# that never existed and never would — and the Stop gate accepted COMPLETE on it. That
# is proof theater: a command engineered to pass, attached to an outcome nothing on
# disk can witness. So there is an honest form for those outcomes:
#
#     PROOF: reply contains "<phrase>"
#
# The Stop hook satisfies it only when the final assistant message contains the phrase
# verbatim, case-sensitive. The phrase must be at least 12 characters: a short one is
# as easy to hit by accident as `true` is, so it is refused as trivial.
SO_REPLY_PHRASE_MIN=12

so_proof_reply_phrase() { # <success-condition line> -> the phrase, or nothing
  sed -nE 's/.*PROOF:[[:space:]]*reply contains[[:space:]]*"(.*)"[[:space:]]*$/\1/p' <<< "$1" | head -1
}

so_is_reply_proof() { # <success-condition line>
  grep -qE 'PROOF:[[:space:]]*reply contains[[:space:]]*".*"[[:space:]]*$' <<< "$1"
}

# A negative-existence proof — `test ! -e X`, `[ ! -f X ]` — passes whenever X is
# absent, and the easiest way to make X absent is never to create it. It is admitted
# only when X is named somewhere that is NOT this proof line: the WORKFLOW the
# interpreter wrote, or a proof line already recorded. That is the case where the
# absence is a real claim about work done ("the old file was removed") rather than a
# claim about a file nobody ever made. (2.x witnessed it from CURRENT REALITY, which
# 3.0 removed; the witness moved, the rule did not.)
so_proof_negative_existence_path() { # <command> -> the tested path, or nothing
  sed -nE 's/^[[:space:]]*(test|\[)[[:space:]]+![[:space:]]*-[efdsL][[:space:]]+([^][:space:]]+).*/\2/p' <<< "$1" | head -1
}

# Everything that may witness an absence in <file>, minus the line under judgement.
so_absence_witness() { # <objective-file> <the proof line being judged>
  local file="$1" self="$2"
  so_workflow_layer "$file"
  so_prog_section "$file" CHECKPOINTS | grep -vxF -- "$self" || true
  so_prog_section "$file" PROOFS      | grep -vxF -- "$self" || true
}

so_proof_absence_is_unwitnessed() { # <command> <witness-text>
  local path; path="$(so_proof_negative_existence_path "$1")"
  [ -n "$path" ] || return 1
  grep -qF -- "$path" <<< "$2" && return 1
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

# The same bound, with the command's own output kept. A proof is refused AT THE MOMENT
# IT IS RECORDED in 3.0, and a refusal that does not show what the command printed
# leaves the agent guessing at what it must change.
so_run_bounded_capture() { # <seconds> <command> <cwd> <out-file>
  local secs="$1" cmd="$2" dir="$3" out="$4" tb
  tb="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
  if [ -n "$tb" ]; then
    ( cd "$dir" 2>/dev/null || exit 127; "$tb" "$secs" bash -c "$cmd" > "$out" 2>&1 )
    return $?
  fi
  (
    cd "$dir" 2>/dev/null || exit 127
    bash -c "$cmd" > "$out" 2>&1 & p=$!
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
    so_objective_layer "$file"
    so_workflow_heading "$file"
    so_workflow_layer "$file"
    so_progress_heading "$file"
    so_progress_layer "$file"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  cat "$tmp" > "$file" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  # The operator speaking again reactivates the objective: a NEEDS-DECISION he has just
  # answered, a WAITING whose work he has overtaken, and a COMPLETE he has reopened all
  # become ACTIVE. STATUS lives in PROGRESS in 2.0, so it is set there.
  so_set_status "$file" "ACTIVE"
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

# ---------------------------------------------------------------------------
# D1 — a harness notification is not the operator
# ---------------------------------------------------------------------------
# Background task-notifications arrive through UserPromptSubmit exactly as a typed
# message does. Measured 2026-09-13: two of them were appended verbatim to the
# OPERATOR LEDGER as entries 5 and 6, one of them a 4.6 KB verifier report, in a layer
# headed "hook-written, append-only, agent may not edit" whose whole purpose is to hold
# what HE said. They advance nothing and they lock nothing.
so_is_notification() { # <prompt text>
  local t head
  t="$(printf '%s' "$1" | sed -E 's/^[[:space:]]+//')"
  case "$t" in '<task-notification>'*) return 0 ;; esac
  head="$(printf '%s' "$t" | head -c 200)"
  grep -qF -- '[SYSTEM NOTIFICATION - NOT USER INPUT]' <<< "$head" && return 0
  return 1
}

# Rewrite the STATUS section in place, without touching anything else.
so_set_status() { # <file> <new status line>
  local file="$1" new="$2" tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/so-status.XXXXXX")" || return 1
  {
    so_ledger_layer "$file"
    so_objective_heading "$file"
    so_objective_layer "$file"
    so_workflow_heading "$file"
    so_workflow_layer "$file"
    so_progress_heading "$file"
    so_progress_layer "$file" | awk -v names="$SO_PROG_SECTIONS" -v newstatus="$new" '
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
          if (cur == "STATUS") { print "STATUS"; print newstatus; seen = 1; next }
          print; next
        }
        if (cur == "STATUS") next
        print
      }
      END { if (!seen) { print "STATUS"; print newstatus } }'
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  cat "$tmp" > "$file" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# D4 — apply one Edit to a copy, so an 11 KB objective need not be rewritten whole
# ---------------------------------------------------------------------------
# Literal, single-occurrence replacement, done with awk and index() so the guard keeps
# its bash+jq dependency set. old_string and new_string travel through FILES, never
# through `$( )` or `awk -v`: command substitution strips trailing newlines, so an edit
# whose old_string ends with a newline — which is how a whole line is deleted — would
# be silently mis-applied, and `awk -v` would re-interpret backslashes in the operator's
# own text. The whole file is read as one record so byte-for-byte fidelity is kept.
# Exit: 0 written · 3 empty old_string · 4 not found · 5 more than one occurrence
#       · 6 a file could not be read.
so_apply_edit_to_copy() { # <current-file> <old-string-file> <new-string-file> <out-file>
  SO_SRC="$1" SO_OLDF="$2" SO_NEWF="$3" awk '
    BEGIN {
      RS = "\001"
      if ((getline src < ENVIRON["SO_SRC"]) < 0) exit 6
      if ((getline old < ENVIRON["SO_OLDF"]) < 0) exit 6
      if ((getline new < ENVIRON["SO_NEWF"]) < 0) new = ""
      if (old == "") exit 3
      cnt = 0; rest = src
      while ((i = index(rest, old)) > 0) { cnt++; rest = substr(rest, i + length(old)) }
      if (cnt == 0) exit 4
      if (cnt > 1) exit 5
      i = index(src, old)
      printf "%s", substr(src, 1, i - 1) new substr(src, i + length(old))
    }' > "$4"
}

# The PROGRESS layer a brand-new session starts with. The agent owns every line of it.
so_progress_template() {
  cat <<'TPL'
CHECKPOINTS

PROOFS

IN FLIGHT
none

STATUS
ACTIVE
TPL
}

# The text of the last ledger entry, without its timestamp prefix. Used to recognise the
# same prompt arriving twice from a runtime that fires the hook more than once.
so_ledger_last_text() { # <file>
  so_ledger_layer "$1" | awk '
    /^- [0-9]{4}-[0-9]{2}-[0-9]{2}T/ { n++; buf[n] = substr($0, index($0, "  ") + 2); next }
    n > 0 { buf[n] = buf[n] "\n" $0 }
    END { if (n > 0) printf "%s", buf[n] }'
}

# Is he asking for a thing, or for your thoughts? The interpreter decides it from his
# words; the Stop gate reads it here. Anything unreadable is treated as `task`, which is
# the stricter of the two — a gate that stands down on a line it could not parse is a
# gate that stands down whenever the format drifts.
so_objective_kind() { # <file> -> task | conversation
  local k
  k="$(so_objective_layer "$1" | sed -nE 's/^KIND:[[:space:]]*(task|conversation)[[:space:]]*$/\1/p' | head -1)"
  printf '%s' "${k:-task}"
}

# ---------------------------------------------------------------------------
# 3.0 — the WORKFLOW skeleton and the checkpoints cut into it
# ---------------------------------------------------------------------------
# Measured 2026-09-13 over 57 sessions: the OBJECTIVE was translated well and then
# ignored, because it is prose and prose is advice. A checkpoint is not advice: C1's
# exit condition is a file the agent may not write until a proof of observation is on
# disk, and every proof is run at the moment it is recorded. Order is physical.

# One line of the WORKFLOW, by id. Empty on a 2.x file or a conversation.
so_workflow_line() { # <file> <C1|C2|C3|C4>
  so_workflow_layer "$1" | grep -m1 -E "^[[:space:]]*$2[[:space:]]" | so_trim || true
}

# The exit condition: everything after the em dash. Falls back to the whole line when
# the dash is missing, so a malformed WORKFLOW still says something rather than nothing.
so_workflow_exit() { # <file> <Cn>
  local line; line="$(so_workflow_line "$1" "$2")"
  [ -n "$line" ] || { printf ''; return 0; }
  if grep -qF -- '—' <<< "$line"; then
    printf '%s' "${line#*— }"
  else
    printf '%s' "$line"
  fi
}

# The exit condition to quote at the agent, with a usable fallback for a 2.x file that
# has no WORKFLOW at all (5.6: such a file is treated as C1 current).
so_checkpoint_text() { # <file> <Cn>
  local t; t="$(so_workflow_line "$1" "$2")"
  if [ -n "$t" ]; then printf '%s' "$t"; return 0; fi
  case "$2" in
    C1) printf '%s' "$SO_C1_GENERIC" ;;
    C2) printf '%s' "$SO_C2_GENERIC" ;;
    C3) printf '%s' "$SO_C3_TEXT" ;;
    C4) printf '%s' "$SO_C4_TEXT" ;;
  esac
}

# The recorded proof line for one checkpoint, if any.
so_checkpoint_proof_line() { # <file> <Cn>
  so_prog_section "$1" CHECKPOINTS | grep -m1 -E "^[[:space:]]*$2[[:space:]]+PROOF:" | so_trim || true
}
so_has_checkpoint_proof() { # <file> <Cn>
  [ -n "$(so_checkpoint_proof_line "$1" "$2")" ]
}

# Is the workflow the conversation one-liner?
so_workflow_is_conversation() { # <file>
  grep -qxF -- "$SO_CONVERSATION_WORKFLOW" <<< "$(so_workflow_layer "$1" | so_trim)"
}

# THE CURRENT CHECKPOINT (5.3): the first of C1, C2 without a proof on disk; else C3 if
# any D-item has no proof line; else C4 unless the verifier has already been seen; else
# `none`, which means COMPLETE is available.
#
# BOUND, STATED: C3 here is decided on the PRESENCE of a D-item proof line, not on
# re-running it. The re-run is the COMPLETE gate's job, where it is paid once; running
# every D-item proof to word a refusal would put a 60-second bound per item on the end
# of every turn.
so_current_checkpoint() { # <file> [verifier: yes|no|unknown]
  local file="$1" ver="${2:-unknown}" did
  so_has_checkpoint_proof "$file" C1 || { printf 'C1'; return 0; }
  so_has_checkpoint_proof "$file" C2 || { printf 'C2'; return 0; }
  while IFS= read -r did; do
    [ -n "$did" ] || continue
    [ -n "$(so_proof_line "$file" "$did")" ] || { printf 'C3'; return 0; }
  done <<< "$(so_done_ids "$file")"
  [ "$ver" = "yes" ] && { printf 'none'; return 0; }
  printf 'C4'
}

# The one-line recording instruction for exactly that checkpoint (5.5).
so_checkpoint_instruction() { # <file> <Cn>
  local file="$1" cn="$2" how; how="$(so_write_instruction "$file")"
  case "$cn" in
    C1|C2)
      printf 'Record it with %s: add under CHECKPOINTS the line  %s PROOF: <command> => exit <code>  — the hook runs that command the moment you write it, and refuses the write unless it reproduces.' "$how" "$cn" ;;
    C3)
      printf 'Record it with %s: one PROOFS line per D-item in DONE WHEN,  D1 PROOF: <command> => exit <code>  or  D1 PROOF: reply contains "<phrase>".' "$how" ;;
    C4)
      printf 'Run a verifier that has not seen this session — an Agent call, or a shell call to `claude -p` / `codex exec` — AFTER your last change, and have it answer PASS. The Stop hook reads that from the transcript; there is no line to write.' ;;
    *)
      printf 'Every checkpoint is satisfied: set STATUS COMPLETE in PROGRESS.' ;;
  esac
}
