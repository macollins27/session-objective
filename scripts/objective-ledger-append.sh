#!/usr/bin/env bash
# SO-ROLE: guard
# objective-ledger-append.sh — UserPromptSubmit hook. Rule 1, first half.
#
# Appends the operator's message to the ledger VERBATIM, resets STATUS to ACTIVE
# (F2, so nothing can park in NEEDS-DECISION), then injects the whole file plus one
# instruction: rewrite the OBJECTIVE layer to reflect every ledger entry, then work.
#
# The lock itself lives in objective-write-gate.sh; this hook only moves the number
# the lock compares against.
#
# FAILURE DIRECTION (audited 2026-09-12): FAILS CLOSED on parsing, OPEN on injection.
#   jq missing                     -> exit 2 with the install command (F13)
#   stdin not a JSON object        -> exit 2
#   no session_id                  -> exit 2
#   SESSION_OBJECTIVE=off          -> exit 0, one visible line (F11)
#   objective home unwritable      -> exit 2 (an unrecorded operator message is the one
#                                     failure this whole system exists to prevent)
#   file present but unparseable   -> exit 2 (never silently re-template over it)
# A UserPromptSubmit hook cannot "allow" or "deny": exit 2 aborts the prompt with the
# reason shown, which is the correct direction for a ledger that could not be written.
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
  { printf '%s\n\n' "$SO_LEDGER_HEAD"; so_template; } > "$FILE" \
    || so_fatal "cannot write $FILE. Failing CLOSED."
fi
[ -r "$FILE" ] || so_fatal "$FILE exists but is not readable. Failing CLOSED."
[ -n "$(so_objective_heading "$FILE")" ] \
  || so_fatal "$FILE has no '# OBJECTIVE (...)' heading; refusing to append to a file I cannot parse. Failing CLOSED."

# --- append the message verbatim -------------------------------------------
# The entry opens with "- <ISO-8601 UTC>  ". A multi-line message keeps its
# remaining lines raw and unindented; entries are counted by their timestamp
# prefix, and the LEDGER layer ends at the OBJECTIVE heading, so raw text can
# neither forge an entry boundary in the objective layer nor be lost.
so_append_entry "$FILE" "$PROMPT" \
  || so_fatal "cannot rewrite $FILE; the operator message was not recorded. Failing CLOSED."

COUNT="$(so_ledger_count "$FILE")"

# --- inject (F7: bounded rendering) ----------------------------------------
# Last 3 entries in full; older entries truncated to 200 characters with a pointer
# to the file. The ledger render is then capped at 1,100 words, which with the
# 1,800-word OBJECTIVE cap and this instruction keeps the whole injection near the
# 3,000-word budget.
LEDGER_RENDER="$(so_ledger_layer "$FILE" | awk -v keep=3 -v total="$COUNT" '
  /^- [0-9]{4}-[0-9]{2}-[0-9]{2}T/ { idx++; buf[idx] = $0; next }
  idx > 0 { buf[idx] = buf[idx] "\n" $0; next }
  { print }
  END {
    for (i = 1; i <= idx; i++) {
      if (i > total - keep) { print buf[i] }
      else {
        s = buf[i]
        gsub(/\n/, " ", s)
        if (length(s) > 200) s = substr(s, 1, 200) "  … [entry " i " truncated for injection; full text in the file]"
        print s
      }
    }
  }')"
if [ "$(printf '%s' "$LEDGER_RENDER" | wc -w | tr -d ' ')" -gt 1100 ]; then
  LEDGER_RENDER="$(printf '%s' "$LEDGER_RENDER" | awk '{ for (i=1;i<=NF;i++) { w++; if (w>1100) { print "\n… [ledger render capped at 1,100 words; the complete ledger is in the file]"; exit } printf "%s%s", $i, (i==NF?"\n":" ") } }')"
fi

cat <<EOF
═══ SESSION OBJECTIVE (file: $FILE) ═══
$LEDGER_RENDER

$(so_objective_heading "$FILE")
$(so_objective_layer "$FILE")
═══════════════════════════════════════
INSTRUCTION — rewrite the OBJECTIVE layer to reflect EVERY ledger entry above
(there are now $COUNT), then work.

Use $(so_write_instruction "$FILE")
Rewrite the WHOLE file: keep the OPERATOR LEDGER layer byte-for-byte unchanged, and
replace the OBJECTIVE layer. Set its heading to:
  # OBJECTIVE (agent-written, rewritten every turn, revision <N+1>, bound to ledger entry $COUNT)
Until that write lands, every other tool call is denied.

A line under CONSTRAINTS or REJECTED INTERPRETATIONS may only disappear if the new
text carries: SUPERSEDED $(so_today) by ledger entry <K>: <the old line>
Each SUCCESS CONDITION ends with  PROOF: <command> => exit <code>  and the Stop hook
re-runs those commands before it will accept STATUS COMPLETE.
The OBJECTIVE layer is capped at 1,800 words.
EOF

if [ "$FIRST" = "1" ]; then
  cat <<'EOF'
This is the first message of the session: ask at most one question, and only if the
desired outcome is genuinely ambiguous; otherwise write the objective and go.
EOF
fi
exit 0
