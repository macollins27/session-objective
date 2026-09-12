#!/usr/bin/env bash
# SO-ROLE: guard
# objective-stop-gate.sh — Stop hook. Rule 3: an ACTIVE objective cannot end a turn.
#
#   ACTIVE          -> deny with the FRONTIER text, bounded at 3 denials per session
#                      (F14), then allow with a visible line.
#   ACTIVE + a turn with zero tool calls after the operator's last message
#                   -> denied regardless of the budget. That is the
#                      apology-that-ends-the-turn failure and it never passes.
#   NEEDS-DECISION  -> allowed only if the question is non-empty AND the final
#                      assistant message actually contains it (F2).
#   COMPLETE        -> allowed only if every SUCCESS CONDITION carries a PROOF and
#                      re-running it in the session cwd reproduces the recorded exit
#                      code. This is the defense against the agent grading itself.
#
# FAILURE DIRECTION (audited 2026-09-12): FAILS CLOSED, with one deliberate exception.
#   jq missing                     -> exit 2 (F13) with the install command
#   stdin not a JSON object        -> exit 2
#   no session_id                  -> exit 2
#   stop_hook_active true          -> exit 0 (never block a continuation we caused;
#                                     honoured exactly as lead-persistence-gate.py does)
#   objective file missing         -> exit 0 with a visible line (F16)
#   STATUS unreadable              -> exit 2 (deny: an unreadable status is not a pass)
#   transcript unreadable or its
#     format changed               -> THE EXCEPTION (F12): the zero-tool-call check
#                                     alone fails OPEN with a visible line. A parser
#                                     bug must never wedge a session. Every other
#                                     branch stays fail-closed.
#   SESSION_OBJECTIVE=off          -> exit 0 with one visible line (F11)
set -uo pipefail

# FAIL-CLOSED INPUT VALIDATION — see lib.
SO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/objective-lib.sh
. "$SO_DIR/lib/objective-lib.sh"

if so_disabled; then exit 0; fi
so_read_payload

# Never block a continuation this hook itself caused.
if [ "$(jq -r '.stop_hook_active // false' <<< "$SO_PAYLOAD")" = "true" ]; then exit 0; fi
# F10 — subagents end by reporting; the parent's gate covers the session.
[ -n "$(so_field agent_id)" ] && exit 0

FILE="$(so_file)"
if [ ! -f "$FILE" ]; then
  printf 'session-objective: no objective file for this session (%s); nothing to enforce. The next operator message creates it.\n' "$FILE" >&2
  exit 0
fi

CWD="$(so_field cwd)"; [ -d "$CWD" ] || CWD="$PWD"
STATUS="$(so_status "$FILE")"
LASTMSG="$(jq -r '.last_assistant_message // empty' <<< "$SO_PAYLOAD")"
TRANSCRIPT="$(so_field transcript_path)"
STATE_DIR="$(dirname "$FILE")"
COUNTF="$STATE_DIR/stop-denials.count"

deny() { printf 'session-objective: %s\n' "$*" >&2; exit 2; }

# --- the zero-tool-call check (F12: this check alone fails OPEN) ------------
# Returns: "none" (an assistant turn with no tool calls since the operator's last
# message), "some", or "unknown".
tool_calls_since_last_user() {
  [ -n "$TRANSCRIPT" ] && [ -r "$TRANSCRIPT" ] || { printf 'unknown'; return 0; }
  local seq tail_
  seq="$(jq -r '
      def blocks: (.message.content // []);
      if (.type == "user") and (((.isMeta // false) | not))
         and ( (blocks | type) == "string"
               or ((blocks | type) == "array" and ((blocks | map(select(.type? == "tool_result")) | length) == 0)) )
      then "U"
      elif ((blocks | type) == "array") and ((blocks | map(select(.type? == "tool_use")) | length) > 0)
      then "T"
      else empty end' "$TRANSCRIPT" 2>/dev/null | tr -d '\n')" || { printf 'unknown'; return 0; }
  case "$seq" in *U*) ;; *) printf 'unknown'; return 0 ;; esac
  tail_="${seq##*U}"
  case "$tail_" in *T*) printf 'some' ;; *) printf 'none' ;; esac
}

case "$STATUS" in
  COMPLETE)
    CONDS="$(so_entries "$FILE" "SUCCESS CONDITIONS")"
    [ -n "$CONDS" ] && [ -n "$(printf '%s' "$CONDS" | tr -d '[:space:]')" ] \
      || deny "STATUS is COMPLETE but there are no SUCCESS CONDITIONS. A completion with nothing to reproduce is the agent grading itself. Add conditions, each ending with  PROOF: <command> => exit <code>  or set STATUS back to ACTIVE."
    while IFS= read -r cond; do
      [ -n "$cond" ] || continue
      case "$cond" in
        *PROOF:*) ;;
        *) deny "STATUS is COMPLETE but this SUCCESS CONDITION has no PROOF line, so nothing can reproduce it: $cond" ;;
      esac
      pcmd="$(printf '%s' "$cond" | sed -E 's/.*PROOF:[[:space:]]*//; s/[[:space:]]*=>[[:space:]]*exit[[:space:]]*[0-9]+[[:space:]]*$//')"
      pexp="$(printf '%s' "$cond" | sed -nE 's/.*=>[[:space:]]*exit[[:space:]]*([0-9]+)[[:space:]]*$/\1/p')"
      [ -n "$pexp" ] || deny "STATUS is COMPLETE but this SUCCESS CONDITION does not end with '=> exit <code>', so there is no recorded exit code to reproduce: $cond"
      if so_proof_trivial "$pcmd"; then
        deny "STATUS is COMPLETE but this condition's PROOF cannot fail, so it proves nothing: $cond"
      fi
      if so_proof_destructive "$pcmd"; then
        deny "STATUS is COMPLETE but this condition's PROOF is destructive and will not be re-run by a hook: $cond — replace it with a read-only command whose exit code reports the outcome."
      fi
      so_run_bounded 60 "$pcmd" "$CWD"
      rc=$?
      if [ "$rc" = "124" ] || [ "$rc" = "137" ]; then
        deny "STATUS is COMPLETE but this condition's PROOF did not finish within 60 seconds: $cond"
      fi
      if [ "$rc" != "$pexp" ]; then
        deny "STATUS is COMPLETE but this condition does not reproduce. Condition: $cond — re-run in $CWD it exited $rc, not $pexp. Fix the work or set STATUS back to ACTIVE; a recorded exit code that the machine will not reproduce is the agent grading itself."
      fi
    done <<< "$CONDS"
    printf 'session-objective: objective COMPLETE; every PROOF reproduced its recorded exit code.\n' >&2
    exit 0
    ;;
  NEEDS-DECISION*)
    Q="$(printf '%s' "$STATUS" | sed -E 's/^NEEDS-DECISION[[:space:]]*:?[[:space:]]*//' | so_trim)"
    [ -n "$Q" ] \
      || deny "STATUS is NEEDS-DECISION but names no question. Write it as: NEEDS-DECISION: <one plain question>, and ask that exact question in your reply."
    if [ -z "$LASTMSG" ]; then
      deny "STATUS is NEEDS-DECISION but no final assistant message was available to check the question against. Ask the operator this question, in these words: $Q"
    fi
    grep -qF -- "$Q" <<< "$LASTMSG" \
      || deny "STATUS is NEEDS-DECISION but your reply does not contain the question. Ask it, in these words: $Q"
    exit 0
    ;;
  ACTIVE)
    : # handled below
    ;;
  *)
    deny "STATUS in $FILE is not readable as ACTIVE, NEEDS-DECISION: <question>, or COMPLETE (read: '${STATUS:-<empty>}'). Rewrite the objective with a STATUS the gate can read."
    ;;
esac

# --- ACTIVE ----------------------------------------------------------------
FRONTIER="$(so_frontier "$FILE")"
[ -n "$FRONTIER" ] || FRONTIER="(no FRONTIER recorded — write the next concrete action into the objective, then do it)"

TC="$(tool_calls_since_last_user)"
if [ "$TC" = "unknown" ]; then
  printf 'session-objective: transcript at %s could not be read or parsed, so the zero-tool-call check did not run this turn; every other rule still applied.\n' "${TRANSCRIPT:-<none>}" >&2
fi
if [ "$TC" = "none" ]; then
  deny "the objective is ACTIVE and this turn made no tool calls after the operator's message. Replying without acting is not work. Do the next concrete action now: $FRONTIER"
fi

USED=0
[ -r "$COUNTF" ] && USED="$(tr -dc '0-9' < "$COUNTF" 2>/dev/null || true)"
[ -n "$USED" ] || USED=0
if [ "$USED" -ge 3 ]; then
  printf 'objective still ACTIVE; stop-hook budget exhausted\n' >&2
  exit 0
fi
printf '%s' "$((USED + 1))" > "$COUNTF" 2>/dev/null || true
deny "the objective is ACTIVE, so this turn does not end. Next concrete action (FRONTIER): $FRONTIER
When it is genuinely done, rewrite the objective with STATUS COMPLETE and a PROOF command per SUCCESS CONDITION — the hook re-runs them. If a decision is genuinely the operator's, set STATUS to NEEDS-DECISION: <one plain question> and ask that exact question in your reply."
