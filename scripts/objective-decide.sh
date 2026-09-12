#!/usr/bin/env bash
# SO-ROLE: mechanism
# objective-decide.sh — the /objective decide operator surface. Appends the
# operator's answer to the ledger, exactly as typing it would.
#
# It is a mechanism, not a tool, because it WRITES the append-only ledger and the
# write gate allows it by name.
#
# FAIL-CLOSED INPUT VALIDATION: a missing file, a missing answer, an unparseable
# objective file or a failed rewrite all exit 2 and write nothing. An answer that was
# not recorded must never look recorded.
#
# FAILURE DIRECTION (audited 2026-09-12): FAILS CLOSED.
#   no arguments / empty answer  -> exit 2, nothing written
#   file missing or unparseable  -> exit 2, nothing written
#   rewrite fails                -> exit 2, original file untouched
#
# Usage: objective-decide.sh <path-to-objective.md> <answer...>
set -uo pipefail

SO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/objective-lib.sh
. "$SO_DIR/lib/objective-lib.sh"

FILE="${1:-}"; shift || true
ANSWER="$*"
[ -n "$FILE" ] || so_fatal "usage: objective-decide.sh <path-to-objective.md> <answer>. Nothing was written."
[ -f "$FILE" ] || so_fatal "$FILE does not exist. Nothing was written."
[ -n "$(printf '%s' "$ANSWER" | so_trim)" ] || so_fatal "the answer is empty. Nothing was written."
[ -n "$(so_objective_heading "$FILE")" ] || so_fatal "$FILE has no '# OBJECTIVE (...)' heading. Nothing was written."

so_append_entry "$FILE" "$ANSWER" || so_fatal "could not rewrite $FILE. Nothing was written."
printf 'session-objective: recorded as ledger entry %s in %s. STATUS reset to ACTIVE.\n' "$(so_ledger_count "$FILE")" "$FILE"
