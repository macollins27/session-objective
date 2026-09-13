#!/usr/bin/env bash
# SO-ROLE: mechanism
# objective-interpret.sh — the core of 2.0. Rewrites the OBJECTIVE layer from the
# OPERATOR LEDGER, and from nothing else.
#
# WHY THIS EXISTS. In 1.x the in-session agent wrote the objective, so whatever was in
# that agent's context wrote it too: doctrine, house rules, tool output, its own
# bookkeeping. Measured in a real session — the objective grew past 1,500 words and
# carried lines like "corpus recall before grep" and "reviewer budget", which the
# operator never said. The fix is not a better instruction to that agent. It is to take
# the pen away from it: the objective is written by a call that has never seen the
# session, the project, the doctrine, or the model's own earlier reasoning. Its entire
# world is the operator's messages.
#
# Isolation, measured 2026-09-13 on Claude Code 2.1.269 and not assumed from docs: run
# from an EMPTY temp cwd with --setting-sources "" (no user, project or local settings,
# and with them no hooks, no plugins, no CLAUDE.md), --system-prompt (REPLACES the
# default), --strict-mcp-config --mcp-config '{"mcpServers":{}}', --restricted,
# --disable-slash-commands, --no-session-persistence, stdin closed, SESSION_OBJECTIVE=off
# so this plugin cannot recurse into itself. A probe placing a loud CLAUDE.md and a
# project hook in that cwd confirmed neither reached the model.
#
# Usage: objective-interpret.sh <objective-file>
# Exit:  0 the OBJECTIVE layer was rewritten
#        1 it was not; the reason is on stdout and the file is UNCHANGED
#        2 cannot evaluate (bad arguments, unreadable file, missing dependency)
#
# FAIL-CLOSED INPUT VALIDATION: no file, an unreadable file or a missing dependency
# exits 2. A failed interpretation NEVER writes a partial objective: the candidate is
# built in a temp file and only a validated candidate is moved in.
#
# FAILURE DIRECTION (audited 2026-09-13): FAILS CLOSED onto the LAST GOOD OBJECTIVE.
#   claude missing / times out / non-zero / malformed output -> exit 1, file unchanged
#   validator refuses twice                                  -> the dropped lines are
#                                                               re-added by this script
#                                                               tagged [kept by hook]
#   anything unexpected                                      -> exit 1, file unchanged
# The session is never wedged by a failure here: the agent keeps working against the
# objective it already had, the hook says so out loud, and the next operator message
# retries. The Stop gate refuses COMPLETE while the binding lags the ledger.
set -uo pipefail

SO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/objective-lib.sh
. "$SO_DIR/lib/objective-lib.sh"

FILE="${1:-}"
[ -n "$FILE" ] || { echo "objective-interpret: no objective file given. Failing CLOSED." >&2; exit 2; }
[ -r "$FILE" ] || { echo "objective-interpret: '$FILE' is not readable. Failing CLOSED." >&2; exit 2; }
[ -w "$FILE" ] || { echo "objective-interpret: '$FILE' is not writable. Failing CLOSED." >&2; exit 2; }

PROMPT_FILE="$SO_DIR/../prompts/interpreter.md"
[ -r "$PROMPT_FILE" ] || { echo "objective-interpret: interpreter prompt missing at $PROMPT_FILE. Failing CLOSED." >&2; exit 2; }

# The test knob, and it is only that: it exists so the failure path can be exercised in
# a real session (S5) without breaking the model call, and so fixtures can drive the
# runner with a recorded answer instead of a network round trip.
#   SESSION_OBJECTIVE_INTERPRETER=fail      -> behave as if the call failed
#   SESSION_OBJECTIVE_INTERPRETER_CMD=<cmd> -> run <cmd> instead of `claude`
FORCED="${SESSION_OBJECTIVE_INTERPRETER:-}"
RUNNER="${SESSION_OBJECTIVE_INTERPRETER_CMD:-}"

TMPDIR_RUN="$(mktemp -d "${TMPDIR:-/tmp}/so-interp.XXXXXX")" || { echo "objective-interpret: mktemp failed. Failing CLOSED." >&2; exit 2; }
trap 'rm -rf "$TMPDIR_RUN"' EXIT
CAND="$TMPDIR_RUN/candidate.md"
PREVF="$TMPDIR_RUN/previous.md"
so_objective_layer "$FILE" > "$PREVF"

N="$(so_ledger_count "$FILE")"
REV="$(so_revision "$FILE")"; [ -n "$REV" ] || REV=0

# The interpreter's whole world.
build_input() { # <extra instruction, may be empty>
  printf 'OPERATOR LEDGER\n'
  so_ledger_layer "$FILE" | grep -E '^- [0-9]{4}-[0-9]{2}-[0-9]{2}T' -A0 >/dev/null 2>&1 || true
  so_ledger_layer "$FILE" | awk '
    /^- [0-9]{4}-[0-9]{2}-[0-9]{2}T/ { n++; sub(/^- /, ""); printf "#%d  %s\n", n, $0; next }
    n > 0 { print }'
  printf '\nPREVIOUS OBJECTIVE\n'
  if [ -s "$PREVF" ] && [ -n "$(tr -d '[:space:]' < "$PREVF")" ]; then cat "$PREVF"; else printf 'NONE\n'; fi
  if [ -n "${1:-}" ]; then printf '\nCORRECTION — your previous answer was refused: %s\nFix exactly that and answer again.\n' "$1"; fi
}

MODEL_NOTE="unrecorded"
call_interpreter() { # <input-file> <out-file>
  if [ "$FORCED" = "fail" ]; then return 1; fi
  local bin; bin="${RUNNER:-claude}"
  command -v "$bin" >/dev/null 2>&1 || return 1
  ( cd "$TMPDIR_RUN" || exit 1
    SESSION_OBJECTIVE=off so_run_interpreter_call "$bin" "$1" ) > "$TMPDIR_RUN/raw.json" 2>"$TMPDIR_RUN/err" || return 1
  # --output-format json so the model that answered is recorded rather than guessed.
  # A stub runner may answer in plain text; that is accepted too.
  if jq -e 'type == "object" and has("result")' >/dev/null 2>&1 < "$TMPDIR_RUN/raw.json"; then
    jq -r '.result // ""' < "$TMPDIR_RUN/raw.json" > "$2"
    local m; m="$(jq -r '(.modelUsage // {}) | keys | join(",")' < "$TMPDIR_RUN/raw.json" 2>/dev/null || true)"
    [ -n "$m" ] && MODEL_NOTE="$m"
    if [ "$(jq -r '.is_error // false' < "$TMPDIR_RUN/raw.json")" = "true" ]; then return 1; fi
  else
    cat "$TMPDIR_RUN/raw.json" > "$2"
  fi
  return 0
}

so_run_interpreter_call() { # <bin> <input-file>
  local bin="$1" input="$2" tb
  tb="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
  set -- "$bin" -p \
    --system-prompt "$(cat "$PROMPT_FILE")" \
    --setting-sources "" \
    --no-session-persistence \
    --output-format json \
    --restricted \
    --disable-slash-commands \
    --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
    -- "$(cat "$input")"
  if [ -n "$tb" ]; then "$tb" 60 "$@" < /dev/null; else "$@" < /dev/null; fi
}

attempt() { # <extra instruction>
  build_input "${1:-}" > "$TMPDIR_RUN/input.txt"
  call_interpreter "$TMPDIR_RUN/input.txt" "$CAND" || return 1
  [ -s "$CAND" ] || return 1
  # Strip a code fence if the model wrapped the document in one; everything else is
  # judged as written.
  sed -i.bak -E '/^```/d' "$CAND" 2>/dev/null || true
  rm -f "$CAND.bak"
  return 0
}

if ! attempt ""; then
  printf 'the interpreter call did not produce an answer\n'
  exit 1
fi

REASONS="$("$SO_DIR/objective-validate.sh" "$CAND" "$PREVF")"; VRC=$?
if [ "$VRC" = "2" ]; then printf 'the objective validator could not evaluate the answer\n'; exit 1; fi
if [ "$VRC" != "0" ]; then
  # One retry, with the violation in front of it.
  if ! attempt "$(printf '%s' "$REASONS" | tr '\n' ';')"; then
    printf 'the interpreter call did not produce an answer on retry\n'
    exit 1
  fi
  REASONS="$("$SO_DIR/objective-validate.sh" "$CAND" "$PREVF")"; VRC=$?
fi

if [ "$VRC" != "0" ]; then
  # Still refused. If the ONLY remaining complaints are dropped MUST / MUST NOT lines,
  # the hook puts them back itself: the operator's own words are not lost because a
  # model would not repeat them. Anything else is a failure and the file is untouched.
  OTHER="$(printf '%s\n' "$REASONS" | grep -v '^a line under ' || true)"
  if [ -n "$(printf '%s' "$OTHER" | tr -d '[:space:]')" ]; then
    printf 'the answer did not pass validation: %s\n' "$(printf '%s' "$REASONS" | tr '\n' ';')"
    exit 1
  fi
  KEPT="$TMPDIR_RUN/kept.md"
  : > "$KEPT"
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    case "$r" in
      "a line under MUST NOT disappeared"*) printf 'MUSTNOT\t%s\n' "${r#*: }" >> "$KEPT" ;;
      "a line under MUST disappeared"*)     printf 'MUST\t%s\n'    "${r#*: }" >> "$KEPT" ;;
    esac
  done <<< "$REASONS"
  SO_KEPT="$KEPT" awk '
    BEGIN {
      while ((getline l < ENVIRON["SO_KEPT"]) > 0) {
        i = index(l, "\t")
        sec = substr(l, 1, i - 1); txt = substr(l, i + 1)
        K[sec] = K[sec] "- " txt " [kept by hook]\n"
      }
    }
    { print }
    /^MUST NOT[[:space:]]*$/ { if (K["MUSTNOT"] != "") printf "%s", K["MUSTNOT"]; next }
    /^MUST[[:space:]]*$/     { if (K["MUST"]    != "") printf "%s", K["MUST"] }
  ' "$CAND" > "$TMPDIR_RUN/kept-cand.md" && mv "$TMPDIR_RUN/kept-cand.md" "$CAND"
  REASONS="$("$SO_DIR/objective-validate.sh" "$CAND" "$PREVF")"; VRC=$?
  if [ "$VRC" != "0" ]; then
    printf 'the answer dropped the operator own lines and could not be repaired: %s\n' "$(printf '%s' "$REASONS" | tr '\n' ';')"
    exit 1
  fi
fi

# Apply: ledger unchanged, new OBJECTIVE layer, PROGRESS unchanged.
OUT="$TMPDIR_RUN/new.md"
{
  so_ledger_layer "$FILE"
  printf '# OBJECTIVE (interpreter-written from the ledger only; revision %s, bound to ledger entry %s; model %s)\n' \
    "$((REV + 1))" "$N" "$MODEL_NOTE"
  cat "$CAND"
  printf '\n'
  if [ -n "$(so_progress_heading "$FILE")" ]; then
    so_progress_heading "$FILE"
    so_progress_layer "$FILE"
  else
    printf '%s\n' "$SO_PROGRESS_HEAD"
    so_progress_template
  fi
} > "$OUT" || { printf 'the new objective could not be assembled\n'; exit 1; }
cat "$OUT" > "$FILE" || { printf 'the new objective could not be written\n'; exit 1; }
exit 0
