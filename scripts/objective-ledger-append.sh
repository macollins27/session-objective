#!/usr/bin/env bash
# SO-ROLE: guard
# objective-ledger-append.sh — UserPromptSubmit hook. The only writer of the LEDGER,
# and the only caller of the interpreter.
#
# Order: a harness notification is turned away; a genuine operator message is appended
# verbatim; the interpreter then rewrites the OBJECTIVE from the whole ledger; the
# OBJECTIVE and PROGRESS layers are injected. There is no write-before-act lock in 2.0
# and nothing to force: interpretation has already happened before the agent sees the
# message.
#
# FAILURE DIRECTION (audited 2026-09-13): FAILS CLOSED on recording, OPEN on
# interpretation.
#   jq missing                     -> exit 2 with the install command
#   stdin not a JSON object        -> exit 2
#   no session_id                  -> exit 2
#   SESSION_OBJECTIVE=off          -> exit 0, one visible line (the interpreter too)
#   objective home unwritable      -> exit 2 (an unrecorded operator message is the one
#                                    failure this whole system exists to prevent)
#   interpreter fails              -> exit 0 with a visible line; the OBJECTIVE is left
#                                    exactly as it was, the agent keeps working against
#                                    it, and the next operator message retries. The Stop
#                                    gate refuses COMPLETE while the binding lags.
set -uo pipefail

# FAIL-CLOSED INPUT VALIDATION — see lib.
SO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/objective-lib.sh
. "$SO_DIR/lib/objective-lib.sh"

if so_disabled; then exit 0; fi
so_read_payload

PROMPT="$(jq -r '.prompt // empty' <<< "$SO_PAYLOAD")"
FILE="$(so_file)"
DIR="$(dirname "$FILE")"
mkdir -p "$DIR" 2>/dev/null || so_fatal "cannot create $DIR; the operator ledger could not be written. Failing CLOSED."

FIRST=0
if [ ! -f "$FILE" ]; then
  FIRST=1
  {
    printf '%s\n\n' "$SO_LEDGER_HEAD"
    printf '# OBJECTIVE (interpreter-written from the ledger only; revision 0, bound to ledger entry 0; model none)\n\n'
    printf '%s\n' "$SO_PROGRESS_HEAD"
    so_progress_template
  } > "$FILE" || so_fatal "cannot write $FILE. Failing CLOSED."
fi
[ -r "$FILE" ] || so_fatal "$FILE exists but is not readable. Failing CLOSED."
[ -n "$(so_objective_heading "$FILE")" ] \
  || so_fatal "$FILE has no '# OBJECTIVE (...)' heading; refusing to append to a file I cannot parse. Failing CLOSED."

# --- a harness notification is not the operator ----------------------------
if so_is_notification "$PROMPT"; then
  ST="$(so_status "$FILE")"
  case "$ST" in
    WAITING*) so_set_status "$FILE" "ACTIVE" || true; ST="ACTIVE" ;;
  esac
  printf 'session-objective: background notification received; the objective is %s; update PROGRESS when the work it reports lands.\n' "${ST:-ACTIVE}"
  exit 0
fi

# --- migration from a 1.x file ---------------------------------------------
# A 1.x objective was written by the in-session agent. It is not upgraded in place and
# it is not thrown away: it is archived beside the file, PROGRESS is seeded from what
# it knew, and the interpreter writes the new OBJECTIVE from the ledger below.
if grep -q '^# OBJECTIVE (agent-written' "$FILE" 2>/dev/null; then
  ARCH="$DIR/objective.v1.$(date -u +%Y%m%dT%H%M%SZ).md"
  OLD_STATUS="$(awk '/^STATUS[[:space:]]*$/ { getline; print; exit }' "$FILE" 2>/dev/null || true)"
  OLD_FRONTIER="$(awk '/^FRONTIER[[:space:]]*$/ { getline; print; exit }' "$FILE" 2>/dev/null || true)"
  MIG="$(mktemp "${TMPDIR:-/tmp}/so-mig.XXXXXX")" || so_fatal "mktemp failed. Failing CLOSED."
  awk 'f { print } /^# OBJECTIVE \(/ { f = 1 }' "$FILE" > "$ARCH" 2>/dev/null || true
  {
    so_ledger_layer "$FILE"
    printf '# OBJECTIVE (interpreter-written from the ledger only; revision 0, bound to ledger entry 0; model none)\n\n'
    printf '%s\n' "$SO_PROGRESS_HEAD"
    printf 'PROOFS\n\nCURRENT REALITY\nCarried over from the version 1 objective, archived at %s\n\nFRONTIER\n%s\n\nIN FLIGHT\nnone\n\nSTATUS\n%s\n' \
      "$ARCH" "${OLD_FRONTIER:-(none recorded)}" "${OLD_STATUS:-ACTIVE}"
  } > "$MIG" && cat "$MIG" > "$FILE"
  rm -f "$MIG"
  printf 'session-objective: this session had a version 1 objective, written by the in-session agent. It is archived at %s and the OBJECTIVE below is being rewritten from the operator ledger alone.\n' "$ARCH"
fi

# --- append the message verbatim -------------------------------------------
# One prompt, one entry. Measured 2026-09-13 on Codex CLI 0.154.0: a single typed
# message fired UserPromptSubmit twice and the ledger recorded it twice, which is a
# small lie about what he said. An identical prompt arriving in the same minute as the
# entry already at the end of the ledger is the same prompt, not a second one; it is not
# appended and the interpreter is not re-run, because nothing changed.
DUP=0
if [ "$(so_ledger_last_text "$FILE")" = "$PROMPT" ]    && [ "$(so_ledger_last_ts "$FILE")" = "$(so_now)" ]; then
  DUP=1
else
  so_append_entry "$FILE" "$PROMPT" \
    || so_fatal "cannot rewrite $FILE; the operator message was not recorded. Failing CLOSED."
fi
COUNT="$(so_ledger_count "$FILE")"

# --- interpret --------------------------------------------------------------
INTERP_NOTE=""
if [ "$DUP" = "1" ] && [ "$(so_bound "$FILE")" = "$COUNT" ]; then
  : # the same prompt arriving twice changed nothing; there is nothing to reinterpret
elif ! WHY="$("$SO_DIR/objective-interpret.sh" "$FILE" 2>/dev/null)"; then
  INTERP_NOTE="session-objective: interpreter failed (${WHY:-no reason given}); objective is bound to entry $(so_bound "$FILE") of $COUNT. Work against the objective below; the next message retries, and COMPLETE is refused until the binding catches up."
fi

# --- inject -----------------------------------------------------------------
# The ledger is the interpreter's input, not the agent's. It is never injected; one
# line says how much of it there is. That is what keeps this far under the 8,000
# characters at which Claude Code stops injecting and writes the payload to a file
# instead — measured in 1.x at 10.8 KB, on the one turn the objective was needed most.
cat <<EOF
═══ SESSION OBJECTIVE (file: $FILE) ═══
ledger: $COUNT entries, last at $(so_ledger_last_ts "$FILE")

$(so_objective_heading "$FILE")
$(so_objective_layer "$FILE")
$(so_progress_heading "$FILE")
$(so_progress_layer "$FILE")
═══════════════════════════════════════
${INTERP_NOTE}
The OBJECTIVE above is not yours. It is written from the operator's own messages by a
call that has never seen this session, and you may not edit a byte of it or of the
ledger. If it is wrong, that is a fact about what he asked for: say so and let him
correct it — his next message rewrites it.

PROGRESS is yours. Keep it current with $(so_write_instruction "$FILE") or an Edit on
that same path:
  PROOFS           one line per D-item from DONE WHEN, in one of two forms:
                     D1 PROOF: <command> => exit <code>     the Stop hook re-runs it
                     D1 PROOF: reply contains "<phrase>"    it checks your final message
                   Use the reply form when the outcome IS your reply. Never create a
                   marker file to prove advice; a file whose only purpose is to be
                   absent proves nothing and is refused.
  CURRENT REALITY  at most 80 words. What is true now, not what you did.
  FRONTIER         one line: the next concrete action.
  IN FLIGHT        background task ids, or none.
  STATUS           ACTIVE | WAITING: <what is in flight> | NEEDS-DECISION: <one plain
                   question> | COMPLETE. COMPLETE is accepted only when every D-item's
                   proof reproduces and the objective is bound to entry $COUNT.
Long content belongs in a plan or spec file that the objective points at, not in here.
EOF
if [ "$FIRST" = "1" ]; then
  cat <<'EOF'
This is the first message of the session: if OPEN QUESTION is not "none", ask exactly
that question and stop. Otherwise write PROGRESS and go.
EOF
fi
exit 0
