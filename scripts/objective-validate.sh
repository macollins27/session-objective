#!/usr/bin/env bash
# SO-ROLE: mechanism
# objective-validate.sh — grade one candidate OBJECTIVE layer, mechanically.
#
# The interpreter is a language model, so its output is a CLAIM until something checks
# it. This is that something, and it is the only thing standing between a fabricated
# objective and the file the whole system treats as authority.
#
# Usage: objective-validate.sh <candidate-file> [<previous-objective-layer-file>]
# Exit:  0 valid · 1 invalid (reasons on stdout, one per line) · 2 cannot evaluate
#
# FAIL-CLOSED INPUT VALIDATION: a missing candidate, an unreadable file or a missing
# dependency exits 2 — never 0. An objective nobody could read is never a pass.
#
# FAILURE DIRECTION (audited 2026-09-13): FAILS CLOSED.
#   no arguments / unreadable candidate -> exit 2
#   awk or grep missing                 -> exit 2
#   empty candidate                     -> exit 1 (invalid), never silently accepted
#   any violation                       -> exit 1 with every reason listed
set -uo pipefail

SO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/objective-lib.sh
. "$SO_DIR/lib/objective-lib.sh"

command -v awk >/dev/null 2>&1 || { echo "objective-validate: awk not found; cannot evaluate. Failing CLOSED." >&2; exit 2; }
CAND="${1:-}"
[ -n "$CAND" ] || { echo "objective-validate: no candidate file given; cannot evaluate. Failing CLOSED." >&2; exit 2; }
[ -r "$CAND" ] || { echo "objective-validate: candidate '$CAND' is not readable; cannot evaluate. Failing CLOSED." >&2; exit 2; }
PREV="${2:-}"

FAILS=0
say() { printf '%s\n' "$1"; FAILS=$((FAILS + 1)); }

BODY="$(cat "$CAND")"
if [ -z "$(printf '%s' "$BODY" | tr -d '[:space:]')" ]; then
  say "the interpreter returned nothing"
  exit 1
fi

# 1. every heading present, in order, spelled exactly
ORDER="$(printf '%s\n' "$BODY" | grep -nE '^(OUTCOME|MUST NOT|MUST|DONE WHEN|OPEN QUESTION)[[:space:]]*$' \
         | sed -E 's/^[0-9]+://' | tr '\n' '|')"
WANT='OUTCOME|MUST|MUST NOT|DONE WHEN|OPEN QUESTION|'
[ "$ORDER" = "$WANT" ] \
  || say "the headings are wrong or out of order (found: ${ORDER:-none}); required, in this order: OUTCOME, MUST, MUST NOT, DONE WHEN, OPEN QUESTION"

# 1b. KIND — exactly one, one of exactly two values, above MUST
KINDN="$(printf '%s\n' "$BODY" | grep -cE '^KIND:' || true)"
if [ "${KINDN:-0}" != "1" ]; then
  say "there must be exactly one KIND: line (found ${KINDN:-0}); write  KIND: task  or  KIND: conversation  on the line after OUTCOME"
else
  grep -qE '^KIND:[[:space:]]*(task|conversation)[[:space:]]*$' <<< "$BODY" \
    || say "the KIND: line must read exactly 'KIND: task' or 'KIND: conversation' (found: $(grep -m1 -E '^KIND:' <<< "$BODY"))"
  KLINE="$(printf '%s\n' "$BODY" | grep -nE '^KIND:' | head -1 | cut -d: -f1)"
  MLINE="$(printf '%s\n' "$BODY" | grep -nE '^MUST[[:space:]]*$' | head -1 | cut -d: -f1)"
  if [ -n "$KLINE" ] && [ -n "$MLINE" ] && [ "$KLINE" -gt "$MLINE" ]; then
    say "the KIND: line belongs directly after OUTCOME, above MUST"
  fi
fi

# 2. the word cap
WORDS="$(printf '%s' "$BODY" | wc -w | tr -d ' ')"
[ "$WORDS" -le 200 ] || say "the objective is $WORDS words; the cap is 200"
OUT_WORDS="$(so_section_of "$BODY" "$SO_OBJ_SECTIONS" OUTCOME | wc -w | tr -d ' ')"
[ "$OUT_WORDS" -le 120 ] || say "OUTCOME is $OUT_WORDS words; the cap is 120"

# 3. at least one DONE WHEN item, numbered D1.. in order
IDS="$(so_section_of "$BODY" "$SO_OBJ_SECTIONS" "DONE WHEN" | sed -nE 's/^[[:space:]]*(D[0-9]+)([[:space:]].*)?$/\1/p')"
if [ -z "$IDS" ]; then
  say "DONE WHEN carries no D-items; at least one observable end state is required, numbered D1"
else
  n=0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    n=$((n + 1))
    [ "$id" = "D$n" ] || { say "DONE WHEN items must be numbered D1, D2, D3 in order; found '$id' where D$n was expected"; break; }
  done <<< "$IDS"
fi

# 4. exactly one OPEN QUESTION (or the word none)
OQ="$(so_section_of "$BODY" "$SO_OBJ_SECTIONS" "OPEN QUESTION" | so_trim | grep -v '^$' || true)"
OQN="$(printf '%s\n' "$OQ" | grep -c . || true)"
[ "${OQN:-0}" -le 1 ] || say "OPEN QUESTION carries $OQN lines; it carries exactly one question, or the single word none"

# 5. Rule 2 — a MUST or MUST NOT line may vanish only behind a SUPERSEDED line
if [ -n "$PREV" ] && [ -r "$PREV" ]; then
  PREVBODY="$(cat "$PREV")"
  NEWFLAT="$(printf '%s\n' "$BODY" | sed -E 's/^[[:space:]]*[-*][[:space:]]+//' | so_trim)"
  for SEC in MUST "MUST NOT"; do
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      case "$line" in SUPERSEDED\ *) continue ;; esac
      grep -qxF -- "$line" <<< "$NEWFLAT" && continue
      grep -qE "^SUPERSEDED by #[0-9]+: $(printf '%s' "$line" | sed -E 's/[][\\.^$*+?(){}|\/]/\\&/g')$" <<< "$NEWFLAT" && continue
      say "a line under $SEC disappeared without a SUPERSEDED line: $line"
    done <<< "$(so_entries_of "$PREVBODY" "$SO_OBJ_SECTIONS" "$SEC")"
  done
fi

[ "$FAILS" -eq 0 ] || exit 1
exit 0
