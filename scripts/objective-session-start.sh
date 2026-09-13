#!/usr/bin/env bash
# SO-ROLE: guard
# objective-session-start.sh — SessionStart hook (startup|resume|compact|clear).
#
# Continuity: a --resume'd session keeps its id and therefore its file, and a
# compaction does not lose it, because the file is re-injected here.
# F8: source=clear is the one case where the id survives but the intent does not, so
# the file is ARCHIVED as objective.<timestamp>.md and the session starts empty.
#
# FAILURE DIRECTION (audited 2026-09-12): FAILS CLOSED on parsing, silent on absence.
#   jq missing                  -> exit 2 (F13) with the install command
#   stdin not a JSON object     -> exit 2
#   no session_id               -> exit 2
#   no objective file           -> exit 0, no output (a new session in the same folder
#                                  starts empty, by design)
#   archive on clear fails      -> exit 2 (never inject an objective the operator cleared)
#   SESSION_OBJECTIVE=off       -> exit 0 with one visible line (F11)
set -uo pipefail

# FAIL-CLOSED INPUT VALIDATION — see lib.
SO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/objective-lib.sh
. "$SO_DIR/lib/objective-lib.sh"

if so_disabled; then exit 0; fi
so_read_payload

SOURCE="$(so_field source)"
FILE="$(so_file)"
[ -f "$FILE" ] || exit 0

if [ "$SOURCE" = "clear" ]; then
  ARCHIVE="$(dirname "$FILE")/objective.$(date -u +%Y%m%dT%H%M%SZ).md"
  mv "$FILE" "$ARCHIVE" 2>/dev/null \
    || so_fatal "could not archive $FILE on /clear; refusing to carry a cleared objective forward. Failing CLOSED."
  printf 'session-objective: /clear — the previous objective was archived to %s and this session starts empty. Your next message opens a new ledger.\n' "$ARCHIVE"
  exit 0
fi

cat <<EOF
═══ SESSION OBJECTIVE (restored on ${SOURCE:-startup}; file: $FILE) ═══
ledger: $(so_ledger_count "$FILE") entries, last at $(so_ledger_last_ts "$FILE")

$(so_objective_heading "$FILE")
$(so_objective_layer "$FILE")
$(so_progress_heading "$FILE")
$(so_progress_layer "$FILE")
═══════════════════════════════════════
The OBJECTIVE above is written from the operator's own messages by a call that has never
seen this session; you may not edit a byte of it or of the ledger. PROGRESS is yours,
via $(so_write_instruction "$FILE") or an Edit on that same path.
EOF
exit 0
