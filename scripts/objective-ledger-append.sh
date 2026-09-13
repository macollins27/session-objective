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

# --- D1: a harness notification is not the operator ------------------------
if so_is_notification "$PROMPT"; then
  # It is not appended, it does not advance the count, and it does not lock. It does
  # clear WAITING (D3): the thing that was in flight has landed, so the objective is
  # live again.
  ST="$(so_status "$FILE")"
  case "$ST" in
    WAITING*) so_set_status "$FILE" "ACTIVE" || true; ST="ACTIVE" ;;
  esac
  printf 'session-objective: background notification received; the objective is %s; update the OBJECTIVE layer when the work it reports lands.\n' "${ST:-ACTIVE}"
  exit 0
fi

# --- append the message verbatim -------------------------------------------
# The entry opens with "- <ISO-8601 UTC>  ". A multi-line message keeps its
# remaining lines raw and unindented; entries are counted by their timestamp
# prefix, and the LEDGER layer ends at the OBJECTIVE heading, so raw text can
# neither forge an entry boundary in the objective layer nor be lost.
so_append_entry "$FILE" "$PROMPT" \
  || so_fatal "cannot rewrite $FILE; the operator message was not recorded. Failing CLOSED."

COUNT="$(so_ledger_count "$FILE")"

# --- inject, under a HARD 8,000-character cap (D2, F7) ----------------------
# Measured 2026-09-13 02:12:33: a 10.8 KB injection was persisted to a file instead of
# injected ("Output too large"), so the objective was not in context that turn at all —
# the one turn it most needed to be. A cap that is merely a word budget is not a cap.
# Four stages, each tried in order, the first that fits wins; the last one always fits.
SO_INJECT_CAP=8000

render_ledger() { # <recent-cap> <old-cap> ; 0 means "no limit"
  so_ledger_layer "$FILE" | awk -v keep=3 -v total="$COUNT" -v rcap="$1" -v ocap="$2" '
    function clip(s, n, i) {
      gsub(/\n/, " ", s)
      if (n > 0 && length(s) > n) return substr(s, 1, n) "  … [entry " i " truncated for injection; full text in the file]"
      return s
    }
    /^- [0-9]{4}-[0-9]{2}-[0-9]{2}T/ { idx++; buf[idx] = $0; next }
    idx > 0 { buf[idx] = buf[idx] "\n" $0; next }
    { print }
    END {
      for (i = 1; i <= idx; i++) {
        if (i > total - keep) print clip(buf[i], rcap, i)
        else print clip(buf[i], ocap, i)
      }
    }'
}

render_tail_only() {
  so_ledger_layer "$FILE" | awk -v total="$COUNT" '
    /^- [0-9]{4}-[0-9]{2}-[0-9]{2}T/ { idx++; buf[idx] = $0; next }
    idx > 0 { buf[idx] = buf[idx] "\n" $0; next }
    { print }
    END {
      printf "… [%d ledger entries; only the latest is rendered here, the rest are in the file]\n", total
      s = buf[idx]; gsub(/\n/, " ", s)
      if (length(s) > 600) s = substr(s, 1, 600) "  … [truncated; full text in the file]"
      print s
    }'
}

instruction() {
  cat <<EOF
INSTRUCTION — rewrite the OBJECTIVE layer to reflect EVERY ledger entry above
(there are now $COUNT), then work.

$(if [ "$FIRST" = "1" ]; then
    printf 'Use %s' "$(so_write_instruction "$FILE")"
  else
    printf 'Two tool calls, in this order, and no others in between:\n'
    printf '  1. Read %s   — the hook appended to it a moment ago, so the copy the tool\n' "$FILE"
    printf '     last saw is stale and the write will be refused without this. The Read is\n'
    printf '     permitted while the lock is engaged; it is one of the two calls Rule 1 allows.\n'
    printf '  2. %s\n' "$(so_write_instruction "$FILE")"
    printf '     — or Edit on that same path, which is far cheaper once the objective is long.\n'
  fi)
Rewrite the WHOLE file: keep the OPERATOR LEDGER layer byte-for-byte unchanged, and
replace the OBJECTIVE layer. Set its heading to:
  # OBJECTIVE (agent-written, rewritten every turn, revision <N+1>, bound to ledger entry $COUNT)
Until that write lands, every other tool call is denied.

A line under CONSTRAINTS or REJECTED INTERPRETATIONS may only disappear if the new
text carries: SUPERSEDED $(so_today) by ledger entry <K>: <the old line>
Each SUCCESS CONDITION ends with either
  PROOF: <command> => exit <code>        the Stop hook re-runs the command
  PROOF: reply contains "<phrase>"       the Stop hook checks your final message
before it will accept STATUS COMPLETE. When the outcome IS the reply — advice, a
recommendation, an answer — use the reply form and quote a phrase of at least 12
characters that your answer will actually contain. Never create a marker file to prove
advice was given: a file whose only purpose is to be absent proves nothing, and the
Stop hook refuses it.
STATUS is ACTIVE, WAITING: <what is in flight>, NEEDS-DECISION: <one plain question>,
or COMPLETE. Use WAITING when a background agent or job you launched has not reported
yet — it is the honest way to end a turn, and the hook checks the transcript for a
launch that has not landed.
The OBJECTIVE layer is capped at 1,800 words.
EOF
  if [ "$FIRST" = "1" ]; then
    cat <<'EOF'
This is the first message of the session: ask at most one question, and only if the
desired outcome is genuinely ambiguous; otherwise write the objective and go.
EOF
  fi
}

assemble() { # <ledger render>
  cat <<EOF
═══ SESSION OBJECTIVE (file: $FILE) ═══
$1

$(so_objective_heading "$FILE")
$(so_objective_layer "$FILE")
═══════════════════════════════════════
$(instruction)
EOF
}

OUT="$(assemble "$(render_ledger 600 600)")"
if [ "${#OUT}" -gt "$SO_INJECT_CAP" ]; then OUT="$(assemble "$(render_ledger 600 200)")"; fi
if [ "${#OUT}" -gt "$SO_INJECT_CAP" ]; then OUT="$(assemble "$(render_tail_only)")"; fi
if [ "${#OUT}" -gt "$SO_INJECT_CAP" ]; then
  # Last resort: the objective layer alone is over budget. Emit what decides the next
  # action and say where the rest is. This always fits.
  OUT="$(cat <<EOF
═══ SESSION OBJECTIVE (file: $FILE) ═══
$(so_objective_heading "$FILE")
… [$COUNT ledger entries and the full OBJECTIVE layer are too long to inject; read the
file with the Read tool on $FILE — that call is permitted]
STATUS
$(so_status "$FILE")
FRONTIER
$(so_frontier "$FILE")
═══════════════════════════════════════
INSTRUCTION — Read $FILE, then rewrite its OBJECTIVE layer to reflect all $COUNT ledger
entries, using $(so_write_instruction "$FILE"). Until that write lands, every other tool
call is denied.
EOF
)"
fi
printf '%s\n' "$OUT"
exit 0
