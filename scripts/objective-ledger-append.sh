#!/usr/bin/env bash
# SO-ROLE: guard
# objective-ledger-append.sh — UserPromptSubmit hook. The only writer of the LEDGER,
# and the only caller of the interpreter.
#
# Order: a harness notification is turned away; a 2.x file is migrated to the 3.0 layout
# (its CURRENT REALITY and FRONTIER archived beside it, its D-item proofs kept); a
# genuine operator message is appended verbatim; the interpreter then rewrites the
# OBJECTIVE and the WORKFLOW from the whole ledger; and the injection carries the
# OBJECTIVE, the WORKFLOW, the PROGRESS layer, the one derived CURRENT CHECKPOINT line
# and the instruction for recording exactly that checkpoint.
#
# What it no longer carries: any request to keep a running narrative current. 3.0 asks
# for a write when a checkpoint is reached, when work is launched in the background, and
# when the status changes — never every turn.
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
CWDNOTE="$(so_field cwd)"; [ -n "$CWDNOTE" ] || CWDNOTE="the session directory"
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
  MIG="$(mktemp "${TMPDIR:-/tmp}/so-mig.XXXXXX")" || so_fatal "mktemp failed. Failing CLOSED."
  awk 'f { print } /^# OBJECTIVE \(/ { f = 1 }' "$FILE" > "$ARCH" 2>/dev/null || true
  {
    so_ledger_layer "$FILE"
    printf '# OBJECTIVE (interpreter-written from the ledger only; revision 0, bound to ledger entry 0; model none)\n\n'
    printf '%s\n' "$SO_PROGRESS_HEAD"
    printf 'CHECKPOINTS\n\nPROOFS\n\nIN FLIGHT\nnone\n\nSTATUS\n%s\n' "${OLD_STATUS:-ACTIVE}"
  } > "$MIG" && cat "$MIG" > "$FILE"
  rm -f "$MIG"
  printf 'session-objective: this session had a version 1 objective, written by the in-session agent. It is archived at %s and the OBJECTIVE below is being rewritten from the operator ledger alone.\n' "$ARCH"
fi

# --- migration from a 2.x file (5.6) ---------------------------------------
# A 2.x file has no WORKFLOW and a PROGRESS layer built around CURRENT REALITY and
# FRONTIER, which 3.0 removed. Nothing the agent proved is thrown away: every Dn PROOF
# line, IN FLIGHT and STATUS are carried across, the narrative sections are archived
# beside the file, and the interpreter below writes the WORKFLOW from the ledger.
MIGRATE_NOTE=""
if [ -n "$(so_progress_heading "$FILE")" ] && [ -z "$(so_workflow_heading "$FILE")" ]; then
  OLDPROG="$(so_progress_layer "$FILE")"
  if grep -qE '^(CURRENT REALITY|FRONTIER)[[:space:]]*$' <<< "$OLDPROG" \
     || ! grep -qE '^CHECKPOINTS[[:space:]]*$' <<< "$OLDPROG"; then
    SO_PROG_SECTIONS_2X='PROOFS|CURRENT REALITY|FRONTIER|IN FLIGHT|STATUS'
    ARCH2="$DIR/progress-2x.$(date -u +%Y%m%dT%H%M%SZ).md"
    printf '%s\n' "$OLDPROG" > "$ARCH2" 2>/dev/null || so_fatal "cannot archive the 2.x progress layer to $ARCH2. Failing CLOSED."
    KEEP_PROOFS="$(so_section_of "$OLDPROG" "$SO_PROG_SECTIONS_2X" PROOFS | grep -E 'PROOF:' || true)"
    KEEP_FLIGHT="$(so_section_of "$OLDPROG" "$SO_PROG_SECTIONS_2X" 'IN FLIGHT' | so_trim | grep -v '^$' || true)"
    KEEP_STATUS="$(so_section_of "$OLDPROG" "$SO_PROG_SECTIONS_2X" STATUS | so_trim | grep -v '^$' | head -1 || true)"
    MIG2="$(mktemp "${TMPDIR:-/tmp}/so-mig3.XXXXXX")" || so_fatal "mktemp failed. Failing CLOSED."
    {
      so_ledger_layer "$FILE"
      so_objective_heading "$FILE"
      so_objective_layer "$FILE"
      printf '%s\n' "$SO_PROGRESS_HEAD"
      printf 'CHECKPOINTS\n\nPROOFS\n%s\n\nIN FLIGHT\n%s\n\nSTATUS\n%s\n' \
        "$KEEP_PROOFS" "${KEEP_FLIGHT:-none}" "${KEEP_STATUS:-ACTIVE}"
    } > "$MIG2" && cat "$MIG2" > "$FILE"
    rm -f "$MIG2"
    MIGRATE_NOTE="session-objective: this session's file was written by version 2. Its CURRENT REALITY and FRONTIER text is archived at $ARCH2; every D-item proof, IN FLIGHT and STATUS were kept. The WORKFLOW below is being written from the operator ledger now, and until a C1 proof is recorded no file under the session directory may be written."
  fi
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
CPNOW="$(so_current_checkpoint "$FILE")"
# 8,000 characters is where Claude Code stops injecting and writes the payload to a file
# instead, so the block is rendered and then held under that, MUST lines first and the
# WORKFLOW never (so_trim_injection).
so_trim_injection 8000 <<EOF
═══ SESSION OBJECTIVE (file: $FILE) ═══
ledger: $COUNT entries, last at $(so_ledger_last_ts "$FILE")

$(so_objective_heading "$FILE")
$(so_objective_layer "$FILE")
$(so_workflow_heading "$FILE")
$(so_workflow_layer "$FILE")
$(so_progress_heading "$FILE")
$(so_progress_layer "$FILE")
═══════════════════════════════════════
CURRENT CHECKPOINT: $(so_checkpoint_text "$FILE" "$CPNOW")
${MIGRATE_NOTE}
${INTERP_NOTE}
The OBJECTIVE and the WORKFLOW above are not yours. They are written from the operator's
own messages by a call that has never seen this session, and you may not edit a byte of
them or of the ledger. If they are wrong, that is a fact about what he asked for: say so
and let him correct it — his next message rewrites them.

EOF
printf '\n'
# Is he asking for a thing, or for your thoughts? The instruction differs, because on a
# conversation the reply IS the deliverable and there is nothing to write down. Emitted
# here, at the top level: a heredoc nested inside a command substitution inside another
# heredoc does not parse, and a guidance block that silently failed to render would leave
# the agent with no instruction at all.
if [ "$(so_objective_kind "$FILE")" = "conversation" ]; then
  cat <<'CONV'
KIND is conversation: he asked for an answer, not for a thing. YOUR REPLY IS THE
DELIVERABLE. No PROGRESS write is needed and the turn may end on your reply alone — the
Stop hook stands down. Answer him properly: decide, say what you would do and why, in
plain English, and do not hand the decision back to him. If he then asks for the thing,
KIND flips to task on his next message, and everything he said while talking it through
becomes that task's requirements.
CONV
else
  cat <<EOF
PROGRESS is yours, via $(so_write_instruction "$FILE") or an Edit on that same path.
Write it when you reach a checkpoint, when you launch something in the background, and
when the status changes — not every turn.
  CHECKPOINTS  C1 PROOF: <command> => exit <code>, then C2 the same way. The hook RUNS
               the command the moment you record it: a proof that does not reproduce is
               refused and nothing lands. Recorded proofs are append-only, C2 cannot be
               recorded before C1 is on disk, and until C1 is recorded no Write, Edit or
               patch under ${CWDNOTE} is permitted.
  PROOFS       one line per D-item from DONE WHEN, in one of two forms:
                 D1 PROOF: <command> => exit <code>     the Stop hook re-runs it
                 D1 PROOF: reply contains "<phrase>"    it checks your final message
               Use the reply form when the outcome IS your reply. Never create a marker
               file to prove advice; a file whose only purpose is to be absent is refused.
  IN FLIGHT    background task ids, or none.
  STATUS       ACTIVE | WAITING: <what is in flight> | NEEDS-DECISION: <one plain
               question> | COMPLETE. COMPLETE is accepted only when C1 and C2 reproduce,
               every D-item's proof reproduces, a fresh-context verifier answered PASS
               after your last change, and the objective is bound to entry $COUNT.
NOW — $(so_checkpoint_instruction "$FILE" "$CPNOW")
Long content belongs in a plan or spec file that the objective points at, not in here.
EOF
fi

if [ "$FIRST" = "1" ]; then
  cat <<'EOF'
This is the first message of the session: if OPEN QUESTION is not "none", ask exactly
that question and stop. Otherwise answer him, or write PROGRESS and go.
EOF
fi
exit 0
