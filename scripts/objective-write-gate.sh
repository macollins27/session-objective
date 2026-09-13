#!/usr/bin/env bash
# SO-ROLE: guard
# objective-write-gate.sh — PreToolUse hook. In 2.0 it enforces one thing: WHO WRITES
# WHAT.
#
#   LEDGER     the UserPromptSubmit hook, from genuine operator prompts only
#   OBJECTIVE  the interpreter, from the ledger only
#   PROGRESS   the agent
#
# There is no write-before-act lock in 2.0 and nothing to force: the interpreter has
# already run, inside the hook, before the agent saw the message. What is left is the
# boundary — any write whose RESULT changes a byte of LEDGER or OBJECTIVE is denied, and
# PROGRESS is judged on the content the runtime would actually leave on disk.
#
# Order of decisions:
#   1. fleet switch off                        -> allow  (F11)
#   2. Read of THIS session's objective file    -> explicit allow (it is the agent's own
#      context, and the allow is explicit because the file sits outside the project and
#      would otherwise wait on a permission prompt nobody is there to answer)
#   3. a write to that file (Write, Edit, apply_patch) -> validated, then allowed
#   4. anything else under the objective home   -> deny
#   5. Bash naming the objective home           -> deny (whole command string)
#   6. everything else                          -> allow
#
# FAILURE DIRECTION (audited 2026-09-13): FAILS CLOSED.
#   jq missing                    -> exit 2 (F13) with the install command
#   stdin not a JSON object       -> exit 2
#   no session_id                 -> exit 2
#   objective file absent         -> exit 0 (installed mid-session; the next message
#                                    creates it)
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

  local WORDS; WORDS="$(so_progress_layer "$NEW" | wc -w | tr -d ' ')"
  if [ "$WORDS" -gt 300 ]; then
    so_deny_pretooluse "session-objective: PROGRESS is $WORDS words; the cap is 300. CURRENT REALITY is capped at 80 words and FRONTIER is one line. Long content belongs in a plan or spec file that the objective points at."
  fi
  local CRW; CRW="$(so_prog_section "$NEW" "CURRENT REALITY" | wc -w | tr -d ' ')"
  if [ "$CRW" -gt 80 ]; then
    so_deny_pretooluse "session-objective: CURRENT REALITY is $CRW words; the cap is 80. It says what is true now, not what you did."
  fi

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
    if so_proof_absence_is_unwitnessed "$pcmd" "$NEW"; then
      so_deny_pretooluse "session-objective: this proof rests on the ABSENCE of a file that nothing in PROGRESS says ever existed: $cond — never creating the file is not evidence. If the absence is real work, name the path in CURRENT REALITY. If the outcome IS your reply, write  PROOF: reply contains \"<phrase>\"."
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
    under_home "$RTGT" || exit 0
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
    if [ -n "$TGT" ] && under_home "$(so_realpath "$TGT" "$CWD")"; then
      so_deny_pretooluse "session-objective: $TOOL on $TGT is denied — a multi-part edit cannot be applied to a copy and checked as one result. Use $HOWTO."
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
