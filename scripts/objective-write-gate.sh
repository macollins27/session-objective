#!/usr/bin/env bash
# SO-ROLE: guard
# objective-write-gate.sh — PreToolUse hook. It enforces two things: WHO WRITES WHAT,
# and, new in 3.0, THE ORDER OF THE WORK.
#
#   LEDGER     the UserPromptSubmit hook, from genuine operator prompts only
#   OBJECTIVE  the interpreter, from the ledger only
#   WORKFLOW   the interpreter, with the objective
#   PROGRESS   the agent
#
# THE EDIT LOCK (3.0, spec 5.2). While the objective is a task and no C1 proof is on
# disk, every Write / Edit / MultiEdit / NotebookEdit / apply_patch landing under the
# session cwd is DENIED, quoting C1's exit condition. Measured over 57 sessions: the
# objective was translated well and then ignored, because prose is advice. A checkpoint
# the agent cannot walk past is not advice.
#
# ITS BOUND, STATED RATHER THAN HIDDEN: Bash is NOT covered by the lock. An agent that
# wanted to evade it could write a file with `cat > x`. The lock forces ORDER on an
# agent that drifts; it is not a defence against one that evades, and nothing here
# pretends otherwise. The defence against tampering is elsewhere and unchanged: the
# LEDGER and OBJECTIVE layers are compared byte for byte on every sanctioned write.
#
# THE HOOK TIMEOUT IS PART OF THIS GUARD. A PreToolUse hook that is killed on its timeout
# is a non-blocking error, and the tool then PROCEEDS — the same fail-open shape exit 2
# exists to close. Running a checkpoint proof takes up to 60 seconds, so hooks.json gives
# this hook 75. Never lower that below the proof bound.
#
# CHECKPOINT PROOFS ARE RUN AT WRITE TIME (3.0, spec 5.1). A proof is never on disk
# unless it passed: the gate runs the command the moment the line is recorded, with the
# same bounds and the same trivial/destructive/absence classifiers the Stop gate uses,
# and denies the write with the command's own output when it does not reproduce.
# Recorded proofs are append-only: an existing Cn PROOF line may not be changed or
# removed, and C2 may not be recorded before C1 is on disk.
#
# Order of decisions:
#   1. fleet switch off                        -> allow  (F11)
#   2. Read of THIS session's objective file    -> explicit allow (it is the agent's own
#      context, and the allow is explicit because the file sits outside the project and
#      would otherwise wait on a permission prompt nobody is there to answer)
#   3. a write to that file (Write, Edit, apply_patch) -> validated, then allowed
#   4. anything else under the objective home   -> deny
#   5. a write under the session cwd with no C1 proof on disk -> deny (the edit lock)
#   6. Bash naming the objective home           -> deny (whole command string)
#   7. everything else                          -> allow
#
# FAILURE DIRECTION (audited 2026-09-13): FAILS CLOSED.
#   jq missing                    -> exit 2 (F13) with the install command
#   stdin not a JSON object       -> exit 2
#   no session_id                 -> exit 2
#   objective file absent         -> exit 0 (installed mid-session; the next message
#                                    creates it; no file, no checkpoint, no lock)
#   a 2.x file with no WORKFLOW   -> treated as C1 current (spec 5.6); never a crash
#   proposed result unreadable    -> DENY (never judge content the runtime will not write)
#   SESSION_OBJECTIVE=off         -> exit 0 with one visible line (F11)
set -uo pipefail

# FAIL-CLOSED INPUT VALIDATION — see lib.
SO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/objective-lib.sh
. "$SO_DIR/lib/objective-lib.sh"

if so_disabled; then exit 0; fi
so_read_payload

TOOL="$(so_field tool_name)"
CWD="$(so_field cwd)"; [ -n "$CWD" ] || CWD="$PWD"
FILE="$(so_file)"
HOMEDIR="$(so_realpath "$(so_home)")"
RFILE="$(so_realpath "$FILE")"

if [ "$(so_runtime)" = "codex" ]; then
  HOWTO="apply_patch, carrying exactly one file operation, on exactly this path: $FILE"
else
  HOWTO="the Write tool, or Edit, on exactly this path: $FILE"
fi

under_home() { case "$1" in "$HOMEDIR"|"$HOMEDIR"/*) return 0 ;; esac; return 1; }
RCWD="$(so_realpath "$CWD")"
under_cwd() { case "$1" in "$RCWD"|"$RCWD"/*) return 0 ;; esac; return 1; }

# ---------------------------------------------------------------------------
# THE EDIT LOCK (5.2)
# ---------------------------------------------------------------------------
# Product source is everything under the session cwd. The scratchpad, /tmp and the
# objective file itself are outside it and are never locked: the lock exists to stop the
# agent changing the thing it has not looked at, not to stop it thinking on paper.
check_edit_lock() { # <tool> <target as written> <resolved target>
  [ -f "$FILE" ] || return 0
  [ "$(so_objective_kind "$FILE")" = "conversation" ] && return 0
  so_workflow_is_conversation "$FILE" && return 0
  so_has_checkpoint_proof "$FILE" C1 && return 0
  under_cwd "$3" || return 0
  so_deny_pretooluse "session-objective: $1 on $2 is denied — no C1 proof is on disk, and nothing under $CWD changes before the first checkpoint is met.
$(so_checkpoint_text "$FILE" C1)
$(so_checkpoint_instruction "$FILE" C1)
The command you record is run right then: if it does not exit the code you wrote, the write is refused and nothing lands. Files outside $CWD are not locked."
}

# ---------------------------------------------------------------------------
# The only thing the agent may change: the PROGRESS layer.
# ---------------------------------------------------------------------------
validate_progress() { # <file holding the proposed whole file>
  local NEW="$1" cond pcmd phrase

  if [ ! -s "$NEW" ] || [ -z "$(tr -d '[:space:]' < "$NEW")" ]; then
    so_deny_pretooluse "session-objective: the proposed file is empty. Write the whole file: the OPERATOR LEDGER and OBJECTIVE layers byte-for-byte unchanged, then your PROGRESS layer."
  fi
  if [ -z "$(so_progress_heading "$NEW")" ]; then
    so_deny_pretooluse "session-objective: the proposed file has no '$SO_PROGRESS_HEAD' heading. PROGRESS is the layer you own; it has to be there."
  fi
  if [ "$(so_ledger_layer "$FILE")" != "$(so_ledger_layer "$NEW")" ]; then
    so_deny_pretooluse "session-objective: the OPERATOR LEDGER layer changed. It holds what the operator typed, verbatim, and only the hook appends to it. Reproduce it byte-for-byte."
  fi
  if [ "$(so_objective_heading "$FILE")$(so_objective_layer "$FILE")" != "$(so_objective_heading "$NEW")$(so_objective_layer "$NEW")" ]; then
    so_deny_pretooluse "session-objective: the OBJECTIVE layer changed. It is not yours: it is written from the operator's own messages by a call that has never seen this session, and an agent editing it is the whole defect 2.0 exists to close. If it is wrong, say so in your reply — his next message rewrites it. Reproduce it byte-for-byte and change only PROGRESS."
  fi
  if [ "$(so_workflow_heading "$FILE")$(so_workflow_layer "$FILE")" != "$(so_workflow_heading "$NEW")$(so_workflow_layer "$NEW")" ]; then
    so_deny_pretooluse "session-objective: the WORKFLOW layer changed. The checkpoints are written with the objective by the same call that has never seen this session; an agent that can reword its own exit conditions has no exit conditions. Reproduce it byte-for-byte and change only PROGRESS."
  fi

  local WORDS; WORDS="$(so_progress_layer "$NEW" | wc -w | tr -d ' ')"
  if [ "$WORDS" -gt 300 ]; then
    so_deny_pretooluse "session-objective: PROGRESS is $WORDS words; the cap is 300. CURRENT REALITY is capped at 80 words and FRONTIER is one line. Long content belongs in a plan or spec file that the objective points at."
  fi

  # -------------------------------------------------------------------------
  # CHECKPOINTS (5.1): append-only, ordered, and run at the moment of recording
  # -------------------------------------------------------------------------
  local cur_cp new_cp line cn
  cur_cp="$(so_prog_section "$FILE" CHECKPOINTS | so_trim | grep -v '^$' || true)"
  new_cp="$(so_prog_section "$NEW"  CHECKPOINTS | so_trim | grep -v '^$' || true)"

  # append-only: every proof line already on disk survives this write, byte for byte
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in *PROOF:*) ;; *) continue ;; esac
    grep -qxF -- "$line" <<< "$new_cp" && continue
    so_deny_pretooluse "session-objective: this write changes or removes a checkpoint proof that is already on disk: $line — recorded checkpoint proofs are append-only. A checkpoint that can be rewritten after the fact records nothing. Add the next one; leave the ones behind you alone."
  done <<< "$cur_cp"

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in *PROOF:*) ;; *) continue ;; esac
    cn="$(sed -nE 's/^[[:space:]]*(C[0-9]+)[[:space:]]+PROOF:.*/\1/p' <<< "$line")"
    [ -n "$cn" ] || so_deny_pretooluse "session-objective: a line under CHECKPOINTS carries a PROOF but names no checkpoint: $line — write it as  C1 PROOF: <command> => exit <code>"
    case "$cn" in
      C1|C2) ;;
      C3) so_deny_pretooluse "session-objective: C3 carries no proof line of its own: it is satisfied when every D-item in DONE WHEN has a PROOFS line that reproduces. Record those under PROOFS, not under CHECKPOINTS." ;;
      C4) so_deny_pretooluse "session-objective: C4 carries no proof line of its own: it is satisfied from the transcript, by a fresh-context verifier that ran after your last change and answered PASS. There is nothing to write down." ;;
      *)  so_deny_pretooluse "session-objective: there is no checkpoint $cn. The workflow has exactly four: C1 UNDERSTAND, C2 BUILD, C3 PROVE, C4 VERIFY." ;;
    esac
    # already on disk, already judged when it was recorded
    grep -qxF -- "$line" <<< "$cur_cp" && continue
    if [ "$cn" = "C2" ] && ! so_has_checkpoint_proof "$FILE" C1; then
      so_deny_pretooluse "session-objective: C2 cannot be recorded before C1 is on disk. The order is physical, not advisory: $(so_checkpoint_text "$FILE" C1)"
    fi
    if so_is_reply_proof "$line"; then
      so_deny_pretooluse "session-objective: a checkpoint proof is a command, never a phrase: $line — C1 and C2 are conditions about the world, and the hook runs them. The reply form belongs to a D-item whose outcome IS your reply."
    fi
    case "$line" in *'=> exit '*|*'=>exit '*) ;; *)
      so_deny_pretooluse "session-objective: this checkpoint proof does not end with '=> exit <code>', so there is nothing to reproduce: $line" ;;
    esac
    local pcmd pexp rc outf out
    pcmd="$(printf '%s' "$line" | sed -E 's/.*PROOF:[[:space:]]*//; s/[[:space:]]*=>[[:space:]]*exit[[:space:]]*[0-9]+[[:space:]]*$//')"
    pexp="$(printf '%s' "$line" | sed -nE 's/.*=>[[:space:]]*exit[[:space:]]*([0-9]+)[[:space:]]*$/\1/p')"
    if so_proof_trivial "$pcmd"; then
      so_deny_pretooluse "session-objective: this checkpoint proof cannot fail, so it proves nothing: $line — give it a command whose exit code depends on what you actually observed or built."
    fi
    if so_proof_destructive "$pcmd"; then
      so_deny_pretooluse "session-objective: this checkpoint proof is destructive and the hook will not run it: $line — a checkpoint is re-run, so it has to be read-only."
    fi
    if so_proof_absence_is_unwitnessed "$pcmd" "$(so_absence_witness "$NEW" "$line")"; then
      so_deny_pretooluse "session-objective: this checkpoint proof rests on the ABSENCE of a path that neither the WORKFLOW nor an earlier proof names: $line — never creating a file is not an observation."
    fi
    outf="$(mktemp "${TMPDIR:-/tmp}/so-proofout.XXXXXX")" || so_fatal "mktemp failed. Failing CLOSED."
    so_run_bounded_capture 60 "$pcmd" "$CWD" "$outf"
    rc=$?
    out="$(head -c 600 "$outf" 2>/dev/null)"; rm -f "$outf"
    if [ "$rc" = "124" ] || [ "$rc" = "137" ]; then
      so_deny_pretooluse "session-objective: this checkpoint proof did not finish within 60 seconds, so it was not recorded: $line"
    fi
    if [ "$rc" != "$pexp" ]; then
      so_deny_pretooluse "session-objective: this checkpoint proof does not reproduce, so it is not recorded and nothing was written: $line — run in $CWD it exited $rc, not $pexp. Its output was:
${out:-(no output)}"
    fi
  done <<< "$new_cp"

  # Every proof line is judged the moment it is recorded, not only when it is consumed.
  while IFS= read -r cond; do
    [ -n "$cond" ] || continue
    case "$cond" in *PROOF:*) ;; *) continue ;; esac
    if so_is_reply_proof "$cond"; then
      phrase="$(so_proof_reply_phrase "$cond")"
      if [ "${#phrase}" -lt "$SO_REPLY_PHRASE_MIN" ]; then
        so_deny_pretooluse "session-objective: this proof rests on a phrase of ${#phrase} characters, which is as easy to hit by accident as \`true\` is: $cond — quote at least $SO_REPLY_PHRASE_MIN characters of the answer you are actually going to give."
      fi
      continue
    fi
    pcmd="$(printf '%s' "$cond" | sed -E 's/.*PROOF:[[:space:]]*//; s/[[:space:]]*=>[[:space:]]*exit[[:space:]]*[0-9]+[[:space:]]*$//')"
    if so_proof_trivial "$pcmd"; then
      so_deny_pretooluse "session-objective: this proof cannot fail, so it proves nothing: $cond — give it a command whose exit code depends on the outcome, or, if the outcome IS your reply, write  PROOF: reply contains \"<a phrase of at least $SO_REPLY_PHRASE_MIN characters>\""
    fi
    if so_proof_absence_is_unwitnessed "$pcmd" "$(so_absence_witness "$NEW" "$cond")"; then
      so_deny_pretooluse "session-objective: this proof rests on the ABSENCE of a path that neither the WORKFLOW nor an earlier proof names: $cond — never creating the file is not evidence. If the absence is real work, the path belongs in a checkpoint proof you already recorded. If the outcome IS your reply, write  PROOF: reply contains \"<phrase>\"."
    fi
  done <<< "$(so_prog_entries "$NEW" PROOFS)"
  return 0
}

# ---------------------------------------------------------------------------
case "$TOOL" in
  Read)
    TGT="$(jq -r '.tool_input.file_path // empty' <<< "$SO_PAYLOAD")"
    if [ -n "$TGT" ]; then
      RTGT="$(so_realpath "$TGT" "$CWD")"
      if [ "$RTGT" = "$RFILE" ]; then
        so_allow_pretooluse "session-objective: reading this session's own objective file is always permitted."
      fi
      if under_home "$RTGT"; then
        so_deny_pretooluse "session-objective: Read on $TGT is denied. Another session's objective file is not this session's business. This session's file is $FILE."
      fi
    fi
    ;;
  Write|Edit)
    TGT="$(jq -r '.tool_input.file_path // empty' <<< "$SO_PAYLOAD")"
    [ -n "$TGT" ] || exit 0
    RTGT="$(so_realpath "$TGT" "$CWD")"
    if ! under_home "$RTGT"; then
      check_edit_lock "$TOOL" "$TGT" "$RTGT"
      exit 0
    fi
    if [ "$RTGT" != "$RFILE" ]; then
      so_deny_pretooluse "session-objective: $TOOL on $TGT is denied. The objective home ($(so_home)) is hook-written except for this session's own PROGRESS layer, at $FILE."
    fi
    [ -f "$FILE" ] || exit 0
    NEW="$(mktemp "${TMPDIR:-/tmp}/so-proposed.XXXXXX")" || so_fatal "mktemp failed. Failing CLOSED."
    if [ "$TOOL" = "Write" ]; then
      trap 'rm -f "$NEW"' EXIT
      jq -r '.tool_input.content // empty' <<< "$SO_PAYLOAD" > "$NEW"
    else
      OLDF="$(mktemp "${TMPDIR:-/tmp}/so-old.XXXXXX")"; NEWF="$(mktemp "${TMPDIR:-/tmp}/so-new.XXXXXX")"
      trap 'rm -f "$NEW" "$OLDF" "$NEWF"' EXIT
      if [ "$(jq -r '.tool_input.replace_all // false' <<< "$SO_PAYLOAD")" = "true" ]; then
        so_deny_pretooluse "session-objective: an Edit with replace_all on $FILE is denied — a replacement landing in an unknown number of places cannot be checked against the layers you may not touch. Edit one exact, unique piece of text."
      fi
      jq -j '.tool_input.old_string // ""' <<< "$SO_PAYLOAD" > "$OLDF"
      jq -j '.tool_input.new_string // ""' <<< "$SO_PAYLOAD" > "$NEWF"
      so_apply_edit_to_copy "$FILE" "$OLDF" "$NEWF" "$NEW"
      case "$?" in
        0) ;;
        3) so_deny_pretooluse "session-objective: this Edit carries an empty old_string, so what it would leave on disk cannot be computed." ;;
        4) so_deny_pretooluse "session-objective: this Edit's old_string does not appear in $FILE. The hook may have rewritten the objective since you last read it — Read the file again, then Edit." ;;
        5) so_deny_pretooluse "session-objective: this Edit's old_string appears more than once in $FILE, so which occurrence it would change is undecidable. Include enough surrounding text to make it unique." ;;
        *) so_deny_pretooluse "session-objective: this Edit could not be applied to a copy, so what it would write cannot be checked." ;;
      esac
    fi
    validate_progress "$NEW"
    so_allow_pretooluse "session-objective: this changes only this session's PROGRESS layer, and the file it would leave on disk passed every check."
    ;;
  MultiEdit|NotebookEdit)
    TGT="$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<< "$SO_PAYLOAD")"
    if [ -n "$TGT" ]; then
      RTGT="$(so_realpath "$TGT" "$CWD")"
      if under_home "$RTGT"; then
        so_deny_pretooluse "session-objective: $TOOL on $TGT is denied — a multi-part edit cannot be applied to a copy and checked as one result. Use $HOWTO."
      fi
      check_edit_lock "$TOOL" "$TGT" "$RTGT"
    fi
    ;;
  apply_patch)
    PATCHTEXT="$(jq -r '.tool_input.command // empty' <<< "$SO_PAYLOAD")"
    TOUCHES_HOME=0
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      under_home "$(so_realpath "$t" "$CWD")" && TOUCHES_HOME=1
    done <<< "$(so_patch_targets "$PATCHTEXT")"
    if [ "$TOUCHES_HOME" = "0" ] \
       && { grep -qF -- "$(so_home)" <<< "$PATCHTEXT" || grep -qF -- "$HOMEDIR" <<< "$PATCHTEXT"; }; then
      so_deny_pretooluse "session-objective: this apply_patch names the objective home ($(so_home)) but its file operations could not be read, so what it would write cannot be judged. The sanctioned form is $HOWTO."
    fi
    if [ "$TOUCHES_HOME" = "1" ]; then
      NOPS="$(so_patch_ops "$PATCHTEXT" | grep -c . || true)"
      OP1="$(so_patch_ops "$PATCHTEXT" | head -1)"
      TGT1="$(so_realpath "$(so_patch_targets "$PATCHTEXT" | head -1)" "$CWD")"
      if [ "${NOPS:-0}" != "1" ] || [ "$TGT1" != "$RFILE" ]; then
        so_deny_pretooluse "session-objective: this apply_patch touches the objective home and is denied. A patch reaching this session's file must carry exactly ONE file operation, on exactly $FILE, and nothing else."
      fi
      case "$OP1" in
        Add|Update) ;;
        *) so_deny_pretooluse "session-objective: this apply_patch would $OP1 $FILE. The file is never deleted or moved; PROGRESS is rewritten in place." ;;
      esac
      [ -f "$FILE" ] || exit 0
      NEW="$(mktemp "${TMPDIR:-/tmp}/so-proposed.XXXXXX")" || so_fatal "mktemp failed. Failing CLOSED."
      trap 'rm -f "$NEW"' EXIT
      if ! WHY="$(so_apply_patch_to_copy "$PATCHTEXT" "$FILE" "$NEW" 2>&1)"; then
        so_deny_pretooluse "session-objective: this apply_patch cannot be evaluated, so what it would leave on disk cannot be checked and it is refused — $WHY."
      fi
      validate_progress "$NEW"
      so_allow_pretooluse "session-objective: this patch changes only this session's PROGRESS layer, and the file it would leave on disk passed every check."
    fi
    # The lock is judged only after the objective-home rules have had their say: a patch
    # that reaches into the home is refused for THAT, and a reason naming the wrong rule
    # sends the agent to fix the wrong thing.
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      check_edit_lock "apply_patch" "$t" "$(so_realpath "$t" "$CWD")"
    done <<< "$(so_patch_targets "$PATCHTEXT")"
    ;;
  Bash)
    CMD="$(jq -r '.tool_input.command // empty' <<< "$SO_PAYLOAD")"
    SID="$(so_field session_id)"
    # THE WHOLE COMMAND, newlines included. `grep` is line-based and a Bash command is
    # routinely several lines; a first line that looked harmless once hid a ledger
    # append on its second. `case` matches the entire string.
    #
    # Two passes, because a literal match is not enough. MEASURED 2026-09-13: with the
    # cwd set to the objective home's PARENT, `printf x >> home/sessions/<sid>/objective.md`
    # contains none of the literal strings this used to look for, was allowed, and the
    # append landed in the append-only ledger.
    #
    #   pass 1  the names the agent never needs in a shell command at all. It has Read
    #           for its own objective file and nothing else in that home is its business,
    #           so `objective.md`, `.session-objective` and `sessions/<this session id>`
    #           are refused wherever they appear. This over-blocks a command that merely
    #           MENTIONS objective.md in a comment, in any repository. That is a real cost
    #           and a cheap one: one reframe.
    #   pass 2  every token that looks like a path is resolved against the payload's cwd
    #           and compared to the home's REAL path, so a relative path, a `../` hop or a
    #           differently-spelled route is refused by where it lands, not by how it reads.
    #
    # THE REMAINING BOUND, stated rather than hidden: a path assembled purely from shell
    # variables or command substitution — `printf x >> "$D/$F"` — contains none of those
    # names and no resolvable token, and no static check can see where it points. That
    # residual is the same class as the one above, and it is why the LEDGER and OBJECTIVE
    # layers are ALSO compared byte-for-byte on every sanctioned write: a tamper that gets
    # past this guard still cannot be carried forward by any write the agent makes.
    case "$CMD" in
      *objective.md*|*.session-objective*)
        so_deny_pretooluse "session-objective: this Bash command names the objective file or home and is denied — every character of the command was read, not just its first line. To read this session's objective, use the Read tool on $FILE, which is permitted. To change PROGRESS, use $HOWTO. Command refused: $CMD" ;;
    esac
    if [ -n "$SID" ]; then
      case "$CMD" in
        *"sessions/$SID"*)
          so_deny_pretooluse "session-objective: this Bash command names this session's objective directory and is denied. Use the Read tool on $FILE to read it, and $HOWTO to change PROGRESS. Command refused: $CMD" ;;
      esac
    fi
    case "$CMD" in
      *"$(so_home)"*|*"$HOMEDIR"*|*"$FILE"*|*"$RFILE"*)
        so_deny_pretooluse "session-objective: this Bash command names the objective home ($(so_home)) and is denied. Use the Read tool on $FILE to read it, and $HOWTO to change PROGRESS. Command refused: $CMD" ;;
    esac
    while IFS= read -r tok; do
      [ -n "$tok" ] || continue
      case "$tok" in
        */*|*.*) ;;
        *) continue ;;
      esac
      if under_home "$(so_realpath "$tok" "$CWD")"; then
        so_deny_pretooluse "session-objective: this Bash command carries the path '$tok', which resolves inside the objective home ($(so_home)) — a relative path, a '../' hop and a differently-spelled route all land in the same place, and the guard compares where a token LANDS, not how it reads. Use the Read tool on $FILE, and $HOWTO to change PROGRESS. Command refused: $CMD"
      fi
    done <<< "$(printf '%s' "$CMD" | tr '\n' ' ' | sed -E 's/[;&|<>()"'"'"'`]/ /g' | tr -s ' ' '\n')"
    ;;
esac
exit 0
