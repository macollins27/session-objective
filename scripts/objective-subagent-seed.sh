#!/usr/bin/env bash
# SO-ROLE: guard
# objective-subagent-seed.sh — SubagentStart hook.
#
# A subagent's PreToolUse events carry the PARENT's session_id plus its own agent_id
# (settled empirically 2026-09-12, docs/payload-evidence/). Parent and child would
# therefore share one file, so the child's key is <session_id>/<agent_id>. This hook
# seeds that file from the parent's OBJECTIVE layer with an EMPTY ledger, and injects
# it into the subagent's context.
#
# F10: the child gets injection only — no write-before-act lock (its binding equals its
# empty ledger from the start) and no stop gate (a subagent ends by reporting).
#
# FAILURE DIRECTION (audited 2026-09-12): FAILS CLOSED on parsing, silent on absence.
#   jq missing                  -> exit 2 (F13) with the install command
#   stdin not a JSON object     -> exit 2
#   no session_id / agent_id    -> exit 2 / exit 0 (no agent_id means this is not a
#                                 subagent event and there is nothing to seed)
#   parent has no objective     -> exit 0, no output
#   child file unwritable       -> exit 2 (a child with no file would run unlocked
#                                 against a parent objective it never received)
#   SESSION_OBJECTIVE=off       -> exit 0 with one visible line (F11)
set -uo pipefail

# FAIL-CLOSED INPUT VALIDATION — see lib.
SO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/objective-lib.sh
. "$SO_DIR/lib/objective-lib.sh"

if so_disabled; then exit 0; fi
so_read_payload

AGENT="$(so_field agent_id)"
[ -n "$AGENT" ] || exit 0
SID="$(so_field session_id)"
PARENT="$(so_home)/sessions/$SID/objective.md"
[ -f "$PARENT" ] || exit 0
CHILD="$(so_file)"

mkdir -p "$(dirname "$CHILD")" 2>/dev/null \
  || so_fatal "cannot create $(dirname "$CHILD") to seed this subagent. Failing CLOSED."
{
  printf '%s\n\n' "$SO_LEDGER_HEAD"
  printf '# OBJECTIVE (seeded from the parent session at spawn, read-only copy; revision %s, bound to ledger entry 0; model inherited)\n' "$(so_revision "$PARENT")"
  so_objective_layer "$PARENT"
  printf '%s\n' "$SO_PROGRESS_HEAD"
  so_progress_template
} > "$CHILD" || so_fatal "cannot write $CHILD. Failing CLOSED."

cat <<EOF
═══ PARENT SESSION OBJECTIVE (inherited at spawn; your copy: $CHILD) ═══
$(so_objective_layer "$PARENT")
═══════════════════════════════════════
This is the operator's objective for the session that dispatched you. Your own ledger
is empty: you take no operator messages, so nothing here is yours to renegotiate. If
your brief conflicts with the objective above, say so in your report rather than
resolving it silently.
EOF
exit 0
