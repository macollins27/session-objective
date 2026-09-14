#!/usr/bin/env bash
# SO-ROLE: guard
# objective-stop-gate.sh — Stop hook. Rule 3: an ACTIVE objective cannot end a turn.
#
#   WAITING: <what>  -> allowed ONLY when the transcript shows a background launch
#                      since the operator's last message that has not reported back.
#   ACTIVE, KIND: conversation -> ALLOW. He asked for an answer, not for a thing; the
#                      reply is the deliverable and there is nothing to keep working on.
#   ACTIVE          -> deny naming the CURRENT CHECKPOINT — the first of C1, C2 without
#                      a proof on disk, else C3 if a D-item has no proof, else C4 — with
#                      its exit condition and how to record it. Bounded at 3 denials per
#                      operator message (F14), then allow with a visible line.
#   ACTIVE + a turn with zero tool calls after the operator's last message
#                   -> denied regardless of the budget. That is the
#                      apology-that-ends-the-turn failure and it never passes.
#   NEEDS-DECISION  -> allowed only if the question is non-empty AND the final
#                      assistant message actually contains it (F2).
#   COMPLETE        -> allowed only if the C1 and C2 checkpoint proofs are on disk and
#                      still reproduce, every D-item in DONE WHEN carries a PROOF that
#                      reproduces in the session cwd, and the transcript shows a
#                      fresh-context verifier answering PASS after the last product
#                      write (C4, spec 5.4). This is the defense against the agent
#                      grading itself.
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
#     format changed               -> THE EXCEPTION (F12): the zero-tool-call check and
#                                     the C4 verifier check fail OPEN with a visible
#                                     line. A parser bug must never wedge a session, and
#                                     a checkpoint nobody can observe is not a refusal
#                                     anyone can act on. Every other branch stays
#                                     fail-closed — WAITING included, which is still
#                                     refused on an unreadable transcript.
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
KIND="$(so_objective_kind "$FILE")"
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
  # Two transcript formats, because there are two runtimes. Claude Code writes one
  # event per line with `.type` and `.message.content` blocks; Codex writes a rollout
  # with `.payload.type`. Reading only one of them would leave the apology-that-ends-
  # the-turn rule silently unenforced on the other, which is a hole, not a bound.
  seq="$(jq -r '
      def blocks: (.message.content // []);
      def cxp: (.payload // {});
      def cxtext: ((cxp.content // []) | map(select(.text? != null)) | map(.text) | join(""));
      if (.type == "user") and (((.isMeta // false) | not))
         and ( (blocks | type) == "string"
               or ((blocks | type) == "array" and ((blocks | map(select(.type? == "tool_result")) | length) == 0)) )
      then "U"
      elif ((blocks | type) == "array") and ((blocks | map(select(.type? == "tool_use")) | length) > 0)
      then "T"
      elif (cxp.type == "message") and (cxp.role == "user") and ((cxtext | startswith("<")) | not)
      then "U"
      elif (cxp.type == "custom_tool_call") or (cxp.type == "function_call") or (cxp.type == "local_shell_call")
      then "T"
      else empty end' "$TRANSCRIPT" 2>/dev/null | tr -d '\n')" || { printf 'unknown'; return 0; }
  case "$seq" in *U*) ;; *) printf 'unknown'; return 0 ;; esac
  tail_="${seq##*U}"
  case "$tail_" in *T*) printf 'some' ;; *) printf 'none' ;; esac
}

# --- C4: did a fresh verifier run after the last product write? (5.4) ------
# The definition is mechanical and deliberately narrow: after the LAST tool_use that
# wrote a file under the session cwd, there is a later tool_use that is an Agent / Task
# / Workflow call or a shell call carrying `claude -p` or `codex exec`, and THAT call's
# result carries the whole word PASS. If the transcript holds no product write at all
# (the outcome was made by Bash, or outside cwd), the verifier must come after the
# operator's last message instead.
#
# Both runtimes, as the zero-tool-call check already does. This check fails OPEN on an
# unreadable or unrecognisable transcript, with a visible line: it is the F12 exception,
# and it is the only other place in this gate where a check standing down is preferred
# to a session that cannot end.
verifier_pass_after_last_write() {
  [ -n "$TRANSCRIPT" ] && [ -r "$TRANSCRIPT" ] || { printf 'unknown'; return 0; }
  local v
  v="$(jq -rs --arg cwd "$CWD" '
      def undercwd($p): ($p|type == "string") and (($p|length) > 0)
                        and ((($p|startswith("/")) | not) or ($p|startswith($cwd)));
      def wnames: ["Write","Edit","MultiEdit","NotebookEdit","apply_patch"];
      def patchpaths($t): (($t // "") | tostring) | [scan("\\*\\*\\* (?:Add|Update|Delete) File: (.*)")] | flatten;
      def cl_uses: (.message.content // []) | if type == "array" then [.[] | select(.type? == "tool_use")] else [] end;
      def cl_results: (.message.content // []) | if type == "array" then [.[] | select(.type? == "tool_result")] else [] end;
      def genuine_user:
        (.type == "user") and (((.isMeta // false) | not))
        and ( ((.message.content // []) | type) == "string"
              or ( ((.message.content // []) | type) == "array"
                   and (((.message.content // []) | map(select(.type? == "tool_result")) | length) == 0) ) );
      to_entries
      | map( .key as $i | .value as $e
             | ( [ $e | select(genuine_user) | {i: $i, k: "user"} ]
               + [ $e | select(.payload.type? == "message" and .payload.role? == "user") | {i: $i, k: "user"} ]
               + ( [ $e | cl_uses[] | {i: $i, name: (.name // ""), id: (.id // ""), input: (.input // {})} ]
                   | map( . as $u
                          | if ((wnames | index($u.name)) != null)
                             and (( (if $u.name == "apply_patch"
                                     then patchpaths($u.input.command)
                                     else [ ($u.input.file_path // $u.input.notebook_path // "") ] end)
                                   | map(select(undercwd(.))) | length) > 0)
                          then {i: $u.i, k: "write"}
                          elif ((wnames | index($u.name)) == null)
                               and ((["Agent","Task","Workflow"] | index($u.name)) != null
                                    or (($u.input | tostring) | test("claude -p|codex exec")))
                          then {i: $u.i, k: "verifier", id: $u.id}
                          else empty end ) )
               + ( [ $e | select((.payload.type? == "custom_tool_call") or (.payload.type? == "function_call") or (.payload.type? == "local_shell_call"))
                     | {i: $i, name: ((.payload.name // "") | tostring),
                        id: ((.payload.call_id // .payload.id // "") | tostring),
                        args: ((.payload.arguments // .payload.action // "") | tostring)} ]
                   | map( . as $c
                          | if (($c.name | test("apply_patch")) and ((patchpaths($c.args) | map(select(undercwd(.))) | length) > 0))
                          then {i: $c.i, k: "write"}
                          elif (($c.args | test("claude -p|codex exec")) or ($c.name | test("spawn_agent")))
                          then {i: $c.i, k: "verifier", id: $c.id}
                          else empty end ) )
               + [ $e | select(((.payload.type? // "") | tostring) | test("_call_output"))
                     | {i: $i, k: "result", id: ((.payload.call_id // "") | tostring), text: ((.payload.output // "") | tostring)} ]
               + [ $e | cl_results[] | {i: $i, k: "result", id: ((.tool_use_id // "") | tostring), text: ((.content // "") | tostring)} ]
               ) )
      | flatten
      | . as $r
      | if ($r | length) == 0 then "unknown"
        else
          ( ($r | map(select(.k == "write")) | last) as $lw
          | ($r | map(select(.k == "user"))  | last) as $lu
          | (if $lw != null then $lw.i elif $lu != null then $lu.i else -1 end) as $b
          | [ $r[] | select(.k == "verifier" and .i > $b) ] as $cands
          | if ($cands | length) == 0 then "no"
            else ( [ $cands[]
                     | .id as $id | .i as $ci
                     | [ $r[] | select(.k == "result" and .i > $ci and (.id == $id) and ((.text) | test("\\bPASS\\b"))) ] | length ]
                   | add ) as $hits
                 | if ($hits // 0) > 0 then "yes" else "no" end
            end )
        end' "$TRANSCRIPT" 2>/dev/null)" || { printf 'unknown'; return 0; }
  case "$v" in yes|no) printf '%s' "$v" ;; *) printf 'unknown' ;; esac
}

# --- D3: is background work actually in flight? ----------------------------
# Measured 2026-09-13: twice the agent had a verifier running in the background, needed
# to end the turn to receive its notification, was denied for ACTIVE, and set COMPLETE
# to escape — with FRONTIER still reading "relay the verifier verdict". The gate turned
# an honest wait into a false completion. WAITING is the third exit, and it is checked:
# the transcript must show a launch after the operator's last message that has not
# reported back.
#
# Claude Code: an `Agent`/`Task`/`Workflow` tool_use, or a `Bash` tool_use with
# run_in_background true, whose id is not later named by a <task-notification> record.
# Codex: a `custom_tool_call` naming `spawn_agent`/`collaboration.spawn_agent`. Codex
# rollouts carry NO record correlating a completion back to a launch id — there is no
# <task-notification> equivalent — so on Codex a launch after the last operator message
# counts as in flight and the correlation half is simply unavailable. Stated, not hidden.
#
# Returns "yes", "no", or "unknown". Unlike the zero-tool-call check this one fails
# CLOSED: WAITING is an exit, and an exit granted on a transcript nobody could read is
# the false COMPLETE wearing a different name.
background_in_flight() {
  [ -n "$TRANSCRIPT" ] && [ -r "$TRANSCRIPT" ] || { printf 'unknown'; return 0; }
  local report
  report="$(jq -rs '
      def genuine_user:
        (.type == "user") and (((.isMeta // false) | not))
        and ( ((.message.content // []) | type) == "string"
              or ( ((.message.content // []) | type) == "array"
                   and (((.message.content // []) | map(select(.type? == "tool_result")) | length) == 0) ) );
      . as $ev
      | ( [ range(0; ($ev | length)) | select($ev[.] | genuine_user) ] | last // -1 ) as $lastuser
      | ( [ range(0; ($ev | length)) | select(. > $lastuser) | $ev[.] ] ) as $after
      | ( [ $after[]
            | (.message.content // [])
            | select(type == "array")
            | .[]
            | select(.type? == "tool_use")
            | select((.name == "Agent") or (.name == "Task") or (.name == "Workflow")
                     or ((.name == "Bash") and ((.input.run_in_background // false) == true)))
            | .id ] ) as $launches
      | ( [ $after[]
            | (.message.content // [])
            | if type == "string" then .
              elif type == "array" then (map(select(.type? == "text")) | map(.text) | join(" "))
              else "" end ] | join(" ") ) as $notifs
      | ( [ $after[]
            | (.payload // {})
            | select(.type == "custom_tool_call")
            | select((.name // "") | test("spawn_agent")) ] | length ) as $cx
      | ( [ $launches[] | . as $id | select(($notifs | index($id)) == null) ] | length ) as $open
      | "\($open) \($cx) \($launches | length)"
    ' "$TRANSCRIPT" 2>/dev/null)" || { printf 'unknown'; return 0; }
  [ -n "$report" ] || { printf 'unknown'; return 0; }
  local open cx total
  open="$(printf '%s' "$report" | awk '{print $1}')"
  cx="$(printf '%s' "$report" | awk '{print $2}')"
  total="$(printf '%s' "$report" | awk '{print $3}')"
  SO_LAUNCH_TOTAL="${total:-0}"
  if [ "${open:-0}" -gt 0 ] || [ "${cx:-0}" -gt 0 ]; then printf 'yes'; else printf 'no'; fi
}

case "$STATUS" in
  COMPLETE)
    # 2.0: the D-items are the interpreter's, not the agent's, so the agent cannot
    # shrink what "done" means by editing the list — it can only supply a proof for
    # each one. And a completion is refused while the objective still lags the ledger:
    # a COMPLETE bound to entry 3 of 5 is a claim about a question nobody asked.
    N="$(so_ledger_count "$FILE")"
    K="$(so_bound "$FILE")"; [ -n "$K" ] || K=0
    if [ "$K" != "$N" ]; then
      deny "STATUS is COMPLETE but the objective is bound to ledger entry $K of $N — the interpreter has not caught up with everything the operator said, so this is a completion of a question nobody finished asking. Send another message, or set STATUS back to ACTIVE."
    fi
    # C1 and C2 first: a completion whose checkpoints were never met is a completion of
    # work nobody watched happen. Each was run when it was recorded; each is run again
    # here, because a proof that reproduced once and does not reproduce now is describing
    # a world that has moved.
    if [ "$KIND" != "conversation" ] && ! so_workflow_is_conversation "$FILE"; then
      for CP in C1 C2; do
        CPL="$(so_checkpoint_proof_line "$FILE" "$CP")"
        [ -n "$CPL" ] \
          || deny "STATUS is COMPLETE but there is no $CP proof under CHECKPOINTS. $(so_checkpoint_text "$FILE" "$CP")
$(so_checkpoint_instruction "$FILE" "$CP")"
        cpcmd="$(printf '%s' "$CPL" | sed -E 's/.*PROOF:[[:space:]]*//; s/[[:space:]]*=>[[:space:]]*exit[[:space:]]*[0-9]+[[:space:]]*$//')"
        cpexp="$(printf '%s' "$CPL" | sed -nE 's/.*=>[[:space:]]*exit[[:space:]]*([0-9]+)[[:space:]]*$/\1/p')"
        [ -n "$cpexp" ] || deny "STATUS is COMPLETE but $CP's proof does not end with '=> exit <code>': $CPL"
        if so_proof_destructive "$cpcmd"; then
          deny "STATUS is COMPLETE but $CP's proof is destructive and will not be re-run by a hook: $CPL"
        fi
        so_run_bounded 60 "$cpcmd" "$CWD"
        cprc=$?
        if [ "$cprc" != "$cpexp" ]; then
          deny "STATUS is COMPLETE but the $CP checkpoint no longer reproduces. $CPL — re-run in $CWD it exited $cprc, not $cpexp."
        fi
      done
    fi
    IDS="$(so_done_ids "$FILE")"
    [ -n "$(printf '%s' "$IDS" | tr -d '[:space:]')" ] \
      || deny "STATUS is COMPLETE but DONE WHEN carries no D-items, so there is nothing to reproduce."
    while IFS= read -r did; do
      [ -n "$did" ] || continue
      cond="$(so_proof_line "$FILE" "$did")"
      [ -n "$cond" ] \
        || deny "STATUS is COMPLETE but PROGRESS has no PROOFS line for $did. Every D-item in DONE WHEN needs one:  $did PROOF: <command> => exit <code>  or  $did PROOF: reply contains \"<phrase>\""
      if so_is_reply_proof "$cond"; then
        phrase="$(so_proof_reply_phrase "$cond")"
        if [ "${#phrase}" -lt "$SO_REPLY_PHRASE_MIN" ]; then
          deny "STATUS is COMPLETE but $did rests on a phrase of ${#phrase} characters, which proves nothing: $cond"
        fi
        [ -n "$LASTMSG" ] \
          || deny "STATUS is COMPLETE but no final assistant message was available to check $did against: $cond"
        grep -qF -- "$phrase" <<< "$LASTMSG" \
          || deny "STATUS is COMPLETE but your reply does not contain the phrase $did promised: $cond — say it, in those words, or change the proof to what you actually delivered."
        continue
      fi
      case "$cond" in *PROOF:*) ;; *) deny "STATUS is COMPLETE but $did's line carries no PROOF: $cond" ;; esac
      pcmd="$(printf '%s' "$cond" | sed -E 's/.*PROOF:[[:space:]]*//; s/[[:space:]]*=>[[:space:]]*exit[[:space:]]*[0-9]+[[:space:]]*$//')"
      pexp="$(printf '%s' "$cond" | sed -nE 's/.*=>[[:space:]]*exit[[:space:]]*([0-9]+)[[:space:]]*$/\1/p')"
      [ -n "$pexp" ] || deny "STATUS is COMPLETE but $did does not end with '=> exit <code>', so there is no recorded exit code to reproduce: $cond"
      if so_proof_trivial "$pcmd"; then
        deny "STATUS is COMPLETE but $did's proof cannot fail, so it proves nothing: $cond — if the outcome IS your reply, write  $did PROOF: reply contains \"<phrase>\""
      fi
      if so_proof_absence_is_unwitnessed "$pcmd" "$(so_absence_witness "$FILE" "$cond")"; then
        deny "STATUS is COMPLETE but $did rests on the ABSENCE of a path that neither the WORKFLOW nor an earlier proof names: $cond — never creating the file is not evidence."
      fi
      if so_proof_destructive "$pcmd"; then
        deny "STATUS is COMPLETE but $did's proof is destructive and will not be re-run by a hook: $cond — replace it with a read-only command."
      fi
      so_run_bounded 60 "$pcmd" "$CWD"
      rc=$?
      if [ "$rc" = "124" ] || [ "$rc" = "137" ]; then
        deny "STATUS is COMPLETE but $did's proof did not finish within 60 seconds: $cond"
      fi
      if [ "$rc" != "$pexp" ]; then
        deny "STATUS is COMPLETE but $did does not reproduce. $cond — re-run in $CWD it exited $rc, not $pexp. Fix the work or set STATUS back to ACTIVE."
      fi
    done <<< "$IDS"
    # C4 — the fresh verifier, read from the transcript (5.4). Conversations are exempt:
    # the reply is the deliverable and there is no product for a verifier to observe.
    if [ "$KIND" != "conversation" ] && ! so_workflow_is_conversation "$FILE"; then
      VER="$(verifier_pass_after_last_write)"
      case "$VER" in
        yes) ;;
        unknown)
          printf 'session-objective: the transcript at %s could not be read or recognised, so the C4 verifier check did not run this turn; every other rule still applied.\n' "${TRANSCRIPT:-<none>}" >&2 ;;
        *)
          deny "STATUS is COMPLETE but C4 is not met: $(so_checkpoint_text "$FILE" C4)
The transcript shows no fresh-context verifier answering PASS after your last change under $CWD. $(so_checkpoint_instruction "$FILE" C4)" ;;
      esac
    fi
    printf 'session-objective: objective COMPLETE; C1, C2 and every D-item reproduced, the verifier check is satisfied, and the objective is bound to all %s ledger entries.\n' "$N" >&2
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
  WAITING*)
    W="$(printf '%s' "$STATUS" | sed -E 's/^WAITING[[:space:]]*:?[[:space:]]*//' | so_trim)"
    [ -n "$W" ] \
      || deny "STATUS is WAITING but does not say what is in flight. Write it as: WAITING: <the agent or job you launched and are waiting on>."
    IF="$(background_in_flight)"
    case "$IF" in
      yes) printf 'session-objective: objective WAITING on %s; a background launch is still open.\n' "$W" >&2; exit 0 ;;
      unknown) deny "STATUS is WAITING but the transcript at ${TRANSCRIPT:-<none>} could not be read, so nothing in flight could be confirmed. WAITING is an exit and it is not granted on an unverified claim: set ACTIVE and continue, or COMPLETE with proof." ;;
      *) deny "STATUS is WAITING on \"$W\" but nothing is in flight: no background agent or job was launched since the operator's last message that has not already reported back. Set ACTIVE and continue or COMPLETE with proof." ;;
    esac
    ;;
  ACTIVE)
    # When the operator is talking, not asking for a thing, the REPLY is the deliverable
    # and a text-only turn is the finished work. Under the task rules every such turn was
    # denied for making no tool calls, and the only way out was to write a PROGRESS
    # COMPLETE with a reply-contains proof — correct by the rules and wrong for a
    # conversation. So on KIND: conversation the ACTIVE denial and the zero-tool-call
    # rule stand down, and PROGRESS is not required. The moment he asks for the thing the
    # interpreter flips KIND to task and every rule is back, with everything he said
    # while talking it through carried into the task's MUST and MUST NOT lines.
    if [ "$KIND" = "conversation" ]; then
      printf 'session-objective: the objective is a conversation, not a task; your reply is the deliverable.\n' >&2
      exit 0
    fi
    ;;
  *)
    deny "STATUS in $FILE is not readable as ACTIVE, WAITING: <what is in flight>, NEEDS-DECISION: <question>, or COMPLETE (read: '${STATUS:-<empty>}'). Rewrite the objective with a STATUS the gate can read."
    ;;
esac

# --- ACTIVE ----------------------------------------------------------------
# 3.0: the refusal names the CURRENT CHECKPOINT, not a FRONTIER line the agent wrote
# about itself. What the turn is missing is decided from the file and the transcript,
# never from the agent's own account of where it is.
CPNOW="$(so_current_checkpoint "$FILE" "$(verifier_pass_after_last_write)")"
CPTEXT="$(so_checkpoint_text "$FILE" "$CPNOW")"
CPHOW="$(so_checkpoint_instruction "$FILE" "$CPNOW")"

TC="$(tool_calls_since_last_user)"
if [ "$TC" = "unknown" ]; then
  printf 'session-objective: transcript at %s could not be read or parsed, so the zero-tool-call check did not run this turn; every other rule still applied.\n' "${TRANSCRIPT:-<none>}" >&2
fi
if [ "$TC" = "none" ]; then
  deny "the objective is ACTIVE and this turn made no tool calls after the operator's message. Replying without acting is not work. The checkpoint you are on is $CPNOW: $CPTEXT
$CPHOW"
fi

USED=0
[ -r "$COUNTF" ] && USED="$(tr -dc '0-9' < "$COUNTF" 2>/dev/null || true)"
[ -n "$USED" ] || USED=0
if [ "$USED" -ge 3 ]; then
  printf 'objective still ACTIVE; stop-hook budget exhausted\n' >&2
  exit 0
fi
printf '%s' "$((USED + 1))" > "$COUNTF" 2>/dev/null || true
deny "the objective is ACTIVE, so this turn does not end. The checkpoint you are on is $CPNOW: $CPTEXT
$CPHOW
COMPLETE is accepted when C1 and C2 reproduce, every D-item in DONE WHEN has a proof that reproduces, and a fresh verifier answered PASS after your last change. If a background job is still running, set WAITING: <what>. If a decision is genuinely the operator's, set NEEDS-DECISION: <one plain question> and ask that exact question in your reply."
