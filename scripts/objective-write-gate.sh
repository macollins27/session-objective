#!/usr/bin/env bash
# SO-ROLE: guard
# objective-write-gate.sh — PreToolUse hook. Rule 1 (write before act) and Rule 2
# (nothing the operator said disappears), plus the ledger-immutability protection.
#
# Order of decisions, and it matters:
#   1. fleet switch off                      -> allow  (F11)
#   2. anything targeting the objective home -> the protect guard decides (F9)
#      - the sanctioned rewrite of THIS session's objective file -> Rule 2 validation.
#        Claude Code spells that `Write` with file_path + content; Codex has no Write
#        tool and spells it `apply_patch`, with the path inside the patch text. Both
#        reach the SAME validation, on the content the runtime would actually leave
#        on disk.
#      - everything else under the home                        -> deny
#   3. subagent event (agent_id present)     -> allow  (F10: inject only, no lock)
#   4. permission_mode == plan               -> allow  (F6: the harness already blocks
#                                                       Write, so a lock would wedge it)
#   5. bound ledger entry != latest          -> deny every remaining tool  (Rule 1)
#   6. otherwise                             -> allow
#
# FAILURE DIRECTION (audited 2026-09-12): FAILS CLOSED.
#   jq missing                    -> exit 2 (F13) with the install command
#   stdin not a JSON object       -> exit 2
#   no session_id                 -> exit 2
#   objective file absent         -> exit 0 (the hook was installed mid-session; the
#                                    next operator message creates the file)
#   objective file unparseable    -> DENY (a file whose binding cannot be read is a
#                                    lock that cannot be released; it is never an allow)
#   proposed write unparseable    -> DENY
#   apply_patch unparseable, or
#     its result cannot be computed -> DENY (never judge content the runtime will not
#                                     write; that is the fail-open shape)
#   SESSION_OBJECTIVE=off         -> exit 0 with one visible line (F11)
# Deny is the PreToolUse JSON shape on stdout plus exit 0; exit 2 is reserved for
# "this hook could not evaluate anything at all".
set -uo pipefail

# FAIL-CLOSED INPUT VALIDATION — see lib.
SO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/objective-lib.sh
. "$SO_DIR/lib/objective-lib.sh"

if so_disabled; then exit 0; fi
so_read_payload

TOOL="$(so_field tool_name)"
CWD="$(so_field cwd)"; [ -n "$CWD" ] || CWD="$PWD"
AGENT="$(so_field agent_id)"
MODE="$(so_field permission_mode)"
FILE="$(so_file)"
HOMEDIR="$(so_realpath "$(so_home)")"
RFILE="$(so_realpath "$FILE")"

# The one sanctioned way to rewrite the objective, in THIS runtime. Codex exposes no
# Write tool, so naming `Write` at it would be an instruction it cannot follow and the
# lock would never release.
if [ "$(so_runtime)" = "codex" ]; then
  HOWTO="apply_patch, carrying exactly one file operation, on exactly this path: $FILE (an Add File or an Update File hunk; no Move to, no Delete File, and no second file in the same patch)"
else
  HOWTO="Write, with file_path=$FILE"
fi

# ---------------------------------------------------------------------------
# The sanctioned rewrite: Rule 2, the word cap, F1 and ledger immutability, run on
# the content the runtime would actually leave on disk. Called by the Write branch
# and by the apply_patch branch; it never returns on a refusal.
# ---------------------------------------------------------------------------
validate_proposal() { # <file holding the proposed objective>
  local NEW="$1"
  # jq treats "" as truthy, so `.content // empty` yields a one-byte line for an
  # empty write. Test the content, not the file size.
  if [ ! -s "$NEW" ] || [ -z "$(tr -d '[:space:]' < "$NEW")" ]; then
    so_deny_pretooluse "session-objective: the proposed objective file is empty. Write the whole file: the OPERATOR LEDGER layer byte-for-byte unchanged, then the OBJECTIVE layer."
  fi
  if [ -z "$(so_objective_heading "$NEW")" ]; then
    so_deny_pretooluse "session-objective: the proposed file has no '# OBJECTIVE (agent-written, rewritten every turn, revision N, bound to ledger entry K)' heading. Without it the binding cannot be read and the lock can never release."
  fi

  OLD_LEDGER="$(so_ledger_layer "$FILE")"
  NEW_LEDGER="$(so_ledger_layer "$NEW")"
  if [ "$OLD_LEDGER" != "$NEW_LEDGER" ]; then
    so_deny_pretooluse "session-objective: the OPERATOR LEDGER layer changed. It is append-only and hook-written; the agent may not edit it. Reproduce it byte-for-byte and change only the OBJECTIVE layer below the '# OBJECTIVE (...)' heading."
  fi

  COUNT="$(so_ledger_count "$FILE")"
  OLD_BOUND="$(so_bound "$FILE")"; [ -n "$OLD_BOUND" ] || OLD_BOUND=0
  NEW_BOUND="$(so_bound "$NEW")"
  if [ -z "$NEW_BOUND" ]; then
    so_deny_pretooluse "session-objective: the proposed heading does not state 'bound to ledger entry <number>'. There are $COUNT ledger entries; bind to $COUNT."
  fi
  if [ "$NEW_BOUND" -gt "$COUNT" ]; then
    so_deny_pretooluse "session-objective: the proposed objective binds to ledger entry $NEW_BOUND but only $COUNT entries exist. Bind to $COUNT."
  fi
  if [ "$NEW_BOUND" -lt "$OLD_BOUND" ]; then
    so_deny_pretooluse "session-objective: the binding went backwards ($OLD_BOUND -> $NEW_BOUND). Bind to $COUNT."
  fi
  # F1 — the lock is released by ADVANCING the binding, never by rewriting the same
  # text under the same number. Semantic quality of the rewrite is not mechanically
  # decidable; an identical body under an advanced binding is allowed on purpose.
  if [ "$OLD_BOUND" -lt "$COUNT" ] && [ "$NEW_BOUND" -le "$OLD_BOUND" ]; then
    so_deny_pretooluse "session-objective: the objective is locked to ledger entry $OLD_BOUND and there are $COUNT entries. The binding must ADVANCE: set 'bound to ledger entry $COUNT' in the heading and rewrite the OBJECTIVE layer to reflect every entry, including entry $COUNT."
  fi

  WORDS="$(so_objective_layer "$NEW" | wc -w | tr -d ' ')"
  if [ "$WORDS" -gt 1800 ]; then
    so_deny_pretooluse "session-objective: the OBJECTIVE layer is $WORDS words; the cap is 1,800. Cut CURRENT REALITY and FAILED APPROACHES first; CONSTRAINTS and REJECTED INTERPRETATIONS may only shrink through a SUPERSEDED line."
  fi

  # Rule 2 — nothing the operator said disappears.
  NEWTEXT="$(so_objective_layer "$NEW")"
  for SEC in CONSTRAINTS "REJECTED INTERPRETATIONS"; do
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      case "$line" in SUPERSEDED\ *) continue ;; esac
      if grep -qxF -- "$line" <<< "$(printf '%s\n' "$NEWTEXT" | sed -E 's/^[[:space:]]*[-*][[:space:]]+//' | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//')"; then
        continue
      fi
      if grep -qE "^SUPERSEDED [0-9]{4}-[0-9]{2}-[0-9]{2} by ledger entry [0-9]+: $(printf '%s' "$line" | sed -E 's/[][\\.^$*+?(){}|\/]/\\&/g')$" \
           <<< "$(printf '%s\n' "$NEWTEXT" | sed -E 's/^[[:space:]]*[-*][[:space:]]+//' | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//')"; then
        continue
      fi
      so_deny_pretooluse "session-objective: this line under $SEC would disappear from the objective, and nothing the operator said disappears silently. Missing line: $line — restore it, or record: SUPERSEDED $(so_today) by ledger entry <K>: $line"
    done <<< "$(so_entries "$FILE" "$SEC")"
  done

  # F3 — a PROOF that cannot fail proves nothing.
  while IFS= read -r cond; do
    [ -n "$cond" ] || continue
    case "$cond" in *PROOF:*) ;; *) continue ;; esac
    pcmd="$(printf '%s' "$cond" | sed -E 's/.*PROOF:[[:space:]]*//; s/[[:space:]]*=>[[:space:]]*exit[[:space:]]*[0-9]+[[:space:]]*$//')"
    if so_proof_trivial "$pcmd"; then
      so_deny_pretooluse "session-objective: this SUCCESS CONDITION carries a PROOF that cannot fail, so it proves nothing: $cond — give it a command whose exit code actually depends on the outcome."
    fi
  done <<< "$(so_entries "$NEW" "SUCCESS CONDITIONS")"
  return 0
}

# ---------------------------------------------------------------------------
# 2. The protect guard (F9). Every file-tool target is resolved to a real path
#    before it is compared, and every Bash command is scanned for the home path.
# ---------------------------------------------------------------------------
under_home() { # <resolved-path>
  case "$1" in "$HOMEDIR"|"$HOMEDIR"/*) return 0 ;; esac
  return 1
}

case "$TOOL" in
  Write|Edit|MultiEdit|NotebookEdit)
    TGT="$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<< "$SO_PAYLOAD")"
    if [ -n "$TGT" ]; then
      RTGT="$(so_realpath "$TGT" "$CWD")"
      if under_home "$RTGT"; then
        if [ "$RTGT" = "$RFILE" ] && [ "$TOOL" = "Write" ]; then
          : # falls through to the Rule 2 validation below
        else
          so_deny_pretooluse "session-objective: $TOOL on $TGT is denied. The objective home ($(so_home)) is hook-written. This session's objective file is $FILE and the ONLY sanctioned change to it is $HOWTO, rewriting the whole file with the OPERATOR LEDGER layer byte-for-byte unchanged."
        fi
      else
        RTGT=""
      fi
    else
      RTGT=""
    fi
    ;;
  apply_patch)
    # Codex's only file-writing tool. The target path lives inside the patch text, so
    # the guard reads it there rather than declaring the payload unreadable.
    PATCHTEXT="$(jq -r '.tool_input.command // empty' <<< "$SO_PAYLOAD")"
    TOUCHES_HOME=0
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      under_home "$(so_realpath "$t" "$CWD")" && TOUCHES_HOME=1
    done <<< "$(so_patch_targets "$PATCHTEXT")"
    # A patch the parser could not read, that still NAMES the home, is refused: an
    # unreadable patch is never an allow.
    if [ "$TOUCHES_HOME" = "0" ] \
       && { grep -qF -- "$(so_home)" <<< "$PATCHTEXT" || grep -qF -- "$HOMEDIR" <<< "$PATCHTEXT"; }; then
      so_deny_pretooluse "session-objective: this apply_patch names the objective home ($(so_home)) but its file operations could not be read, so what it would write cannot be judged. The only sanctioned rewrite is $HOWTO."
    fi
    if [ "$TOUCHES_HOME" = "1" ]; then
      NOPS="$(so_patch_ops "$PATCHTEXT" | grep -c . || true)"
      OP1="$(so_patch_ops "$PATCHTEXT" | head -1)"
      TGT1="$(so_realpath "$(so_patch_targets "$PATCHTEXT" | head -1)" "$CWD")"
      if [ "${NOPS:-0}" != "1" ] || [ "$TGT1" != "$RFILE" ]; then
        so_deny_pretooluse "session-objective: this apply_patch touches the objective home ($(so_home)) and is denied. A patch that reaches this session's objective file must carry exactly ONE file operation, on exactly $FILE, and nothing else. Split the rest of the patch into its own call. The sanctioned form is $HOWTO."
      fi
      case "$OP1" in
        Add|Update) ;;
        *) so_deny_pretooluse "session-objective: this apply_patch would $OP1 $FILE. The objective file is never deleted or moved; it is rewritten in place. The sanctioned form is $HOWTO." ;;
      esac
      if [ ! -f "$FILE" ]; then exit 0; fi
      NEW="$(mktemp "${TMPDIR:-/tmp}/so-proposed.XXXXXX")" || so_fatal "mktemp failed. Failing CLOSED."
      trap 'rm -f "$NEW"' EXIT
      if ! WHY="$(so_apply_patch_to_copy "$PATCHTEXT" "$FILE" "$NEW" 2>&1)"; then
        so_deny_pretooluse "session-objective: this apply_patch cannot be evaluated, so what it would leave on disk cannot be checked and it is refused — $WHY. Re-send it as $HOWTO."
      fi
      validate_proposal "$NEW"
      exit 0
    fi
    RTGT=""
    ;;
  Bash)
    CMD="$(jq -r '.tool_input.command // empty' <<< "$SO_PAYLOAD")"
    if grep -qF -- "$(so_home)" <<< "$CMD" || grep -qF -- "$HOMEDIR" <<< "$CMD"; then
      # The two sanctioned entry points are this plugin's own scripts. Their bound,
      # stated plainly: this allows the mechanism's own writer by name. It stops
      # shell edits, heredocs, sed -i, tee and python -c; it does not stop an agent
      # that chooses to invoke the sanctioned writer. The ledger stays append-only
      # either way, so nothing the operator said can be removed by this path.
      if grep -qE '(^|[[:space:]"'"'"'])[^[:space:]]*objective-(decide|show)\.sh([[:space:]]|$)' <<< "$CMD"; then
        exit 0
      fi
      so_deny_pretooluse "session-objective: this Bash command names the objective home ($(so_home)) and is denied. The OPERATOR LEDGER layer is append-only and hook-written; the OBJECTIVE layer is changed only by $HOWTO. Command refused: $CMD"
    fi
    RTGT=""
    ;;
  *) RTGT="" ;;
esac

# ---------------------------------------------------------------------------
# The sanctioned Write: Rule 2, the word cap, F1 and ledger immutability.
# ---------------------------------------------------------------------------
if [ -n "${RTGT:-}" ] && [ "$RTGT" = "$RFILE" ]; then
  [ -f "$FILE" ] || exit 0   # first write of a brand-new file: nothing to diff
  NEW="$(mktemp "${TMPDIR:-/tmp}/so-proposed.XXXXXX")" || so_fatal "mktemp failed. Failing CLOSED."
  trap 'rm -f "$NEW"' EXIT
  jq -r '.tool_input.content // empty' <<< "$SO_PAYLOAD" > "$NEW"
  validate_proposal "$NEW"
  exit 0
fi

# ---------------------------------------------------------------------------
# 3/4. Subagents and plan mode: inject only, never lock.
# ---------------------------------------------------------------------------
[ -n "$AGENT" ] && exit 0     # F10
[ "$MODE" = "plan" ] && exit 0 # F6

# ---------------------------------------------------------------------------
# 5. Rule 1 — write before act.
# ---------------------------------------------------------------------------
[ -f "$FILE" ] || exit 0      # hook installed mid-session; the next message creates it
COUNT="$(so_ledger_count "$FILE")"
BOUND="$(so_bound "$FILE")"
if [ -z "$BOUND" ]; then
  so_deny_pretooluse "session-objective: $FILE has no readable 'bound to ledger entry <number>' heading, so the write-before-act lock cannot release. Rewrite the whole file with $HOWTO, heading: # OBJECTIVE (agent-written, rewritten every turn, revision 1, bound to ledger entry $COUNT)"
fi
if [ "$BOUND" != "$COUNT" ]; then
  so_deny_pretooluse "session-objective: $TOOL is denied — the objective is bound to ledger entry $BOUND and the operator's latest message is entry $COUNT. Rewrite the objective FIRST, then work. Exactly one tool call is permitted right now: $HOWTO, rewriting the whole file, OPERATOR LEDGER layer unchanged, heading bound to ledger entry $COUNT. No other tool, no shell heredoc, no Edit. If the write tool refuses because the file changed on disk, write it again: the copy in the SESSION OBJECTIVE block in your context IS the current file, so you do not need to read it first."
fi
exit 0
