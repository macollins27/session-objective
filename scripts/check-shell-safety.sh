#!/usr/bin/env bash
# SO-ROLE: mechanism
# check-shell-safety.sh — THE CLASS, CLOSED MECHANICALLY.
#
# WHY THIS EXISTS (promotion ladder: memory -> hook -> lint -> type).
# The `pipe | grep -q` shape under `set -o pipefail` has now been "fixed" TWICE at
# individual call sites without the CLASS ever being closed:
#   66b5757 (2026-07-07) — check-deliverable.sh: "design.md flapped PASS/FAIL/PASS
#                          on identical content."
#   2026-07-14           — block-bash-approval-tamper.sh: same shape, same race.
# And it was still live in four more guards. Two prose fixes at call sites means the
# third occurrence is not a third patch — it is a mechanism.
#
# THE BUG, precisely: `grep -q` exits the instant it matches. The upstream `printf`
# then takes SIGPIPE (141). `pipefail` propagates that, turning a SUCCESSFUL MATCH
# into a FAILED pipeline. So `if cmd | grep -Eq PAT; then deny; fi` silently does not
# deny, and `... || exit 0` silently allows.
#
# THE DIRECTION IS WHAT MAKES IT SERIOUS: every occurrence was in a GUARD, and every
# one failed OPEN — the deny quietly did not fire. It is timing-dependent, it only
# manifests on large real inputs, and it passes every small test you would write for
# it. (Bash 3.2 on the operator's machine; a bash-5 sandbox did not reproduce it.)
#
# A guard whose failure mode is fail-open is worse than no guard: it reports green
# while permitting the exact thing it names.
#
# WHAT THIS CHECKS
#   1. BANNED SHAPE   — no `... | grep -<flags>q ...` anywhere in scripts/ or hooks/
#                       (comment lines excluded, so the scars can stay documented).
#   2. FAIL-CLOSED    — every PreToolUse/Stop guard validates its input and exits 2
#                       (BLOCK) when it cannot parse it. Claude Code treats exit 2 as
#                       BLOCK and ANY OTHER non-zero as a NON-BLOCKING error, which
#                       lets the tool PROCEED. Measured 2026-07-14: all five guards
#                       returned rc=5 on malformed input and therefore ALLOWED it.
#   3. DIRECTION      — every guard declares its FAILURE DIRECTION in a header, so the
#                       next reader can audit it without running it.
#
# Exit: 0 clean · 1 violations (listed) · 2 fail-closed (cannot evaluate)
#
# FAILURE DIRECTION (audited 2026-07-14): FAILS CLOSED.
#   grep/awk missing              -> exit 2 (cannot evaluate)
#   root is not a directory       -> exit 2
#   no scripts/ under root        -> exit 2 (never bless a tree it cannot read)
#   ZERO files scanned            -> exit 2 (AN EMPTY SCAN CAN NEVER BE A PASS)
#   any violation                 -> exit 1
#   MEASURED FAIL-OPEN, NOW FIXED: this file declared itself a `tool`, tools carried no
#   fail-closed obligation, and `check-shell-safety.sh /nonexistent` printed PASS/exit 0
#   while scanning nothing -- the enforcer exempting itself from the rule it enforces.
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# --- FAIL-CLOSED INPUT VALIDATION (2026-07-14) ---
# THE ENFORCER EXEMPTED ITSELF FROM THE RULE IT ENFORCES. This file declared itself a
# `tool`, and tools carried no fail-closed obligation — yet run-contracts.sh reads its exit
# code and fails the build on it. MEASURED: `check-shell-safety.sh /nonexistent-root` scanned
# ZERO files, found zero violations, and printed **PASS, exit 0**. The gate would have gone
# green on a repo the checker never read. Same fail-open shape, at the keystone.
#
# THE RULE (operator, 2026-07-14): if the gate reads your exit code, you are a MECHANISM,
# not a tool — and a mechanism must be able to refuse.
#
# An empty scan can never be a pass. That is the same three-state discipline run-contracts.sh
# already applies to its own fixtures ("an empty check can never pass green").
command -v grep >/dev/null 2>&1 || { echo "check-shell-safety: grep not found; cannot evaluate. Failing CLOSED." >&2; exit 2; }
command -v awk  >/dev/null 2>&1 || { echo "check-shell-safety: awk not found; cannot evaluate. Failing CLOSED." >&2; exit 2; }
[ -d "$ROOT" ] || { echo "check-shell-safety: root '$ROOT' is not a directory; cannot evaluate. Failing CLOSED." >&2; exit 2; }
[ -d "$ROOT/scripts" ] || { echo "check-shell-safety: no scripts/ under '$ROOT'; refusing to bless a tree I cannot read. Failing CLOSED." >&2; exit 2; }

FAILS=0
SCANNED=0
say() { echo "FAIL: $1"; FAILS=$((FAILS+1)); }

# --- ROLE IS DECLARED, NEVER INFERRED (operator tightening, 2026-07-14) ---------
# The previous version carried hardcoded lists of "which files are guards" and "which
# are mechanisms". That left the load-bearing question — *is this file a guard?* — as a
# JUDGMENT CALL for the next agent, which means a NEW mechanism added without a header
# would simply not be on the list and would pass the gate in silence. That is the same
# fail-open shape one level up: the checker reports green on a file it never classified.
#
# So the default is inverted. EVERY .sh in scripts/ and hooks/ MUST declare, on its own
# second line:
#     # SO-ROLE: guard | mechanism | lib | tool
# An UNDECLARED file is a FAIL. Classification cannot be forgotten, because writing the
# file at all now requires making the claim.
#
#   guard     a PreToolUse/Stop hook. Must declare its FAILURE DIRECTION, carry the
#             fail-closed input validation, be able to `exit 2` (the ONLY code Claude Code
#             treats as BLOCK), and be covered by must-block/must-allow fixtures.
#   mechanism anything that can REFUSE something — a grader, an injector, a marker gate.
#             Must declare its FAILURE DIRECTION and be exercised by a fixture that feeds
#             it garbage. A mechanism with no fixture is an unproven no-op.
#   lib       sourced, never executed. Must declare its FAILURE DIRECTION.
#   tool      a runner or pure function with no refusal semantics (it blesses nothing).
VALID_ROLES="guard mechanism lib tool"

role_of() { grep -m1 -oE '^# SO-ROLE: [a-z]+' "$1" 2>/dev/null | awk '{print $3}'; }

# A mechanism is PROVEN only if something feeds it garbage. These are the fixture suites
# the gate runs; a mechanism must be named in at least one of them.
FIXTURE_SUITES="$ROOT/tests/fixtures/fixtures.json $ROOT/tests/run.sh"

covered() {   # covered <basename> -> 0 if some fixture suite exercises it
  local b="$1" s
  for s in $FIXTURE_SUITES; do
    [ -f "$s" ] || continue
    grep -Fq "$b" "$s" && return 0
  done
  return 1
}

# --- 1. THE BANNED SHAPE ------------------------------------------------------
# Note the regex does not match its own definition: after the literal `|` here comes
# `[`, not whitespace-then-`grep`.
# A PIPE is a single `|`. `||` is a logical OR, and `x || grep -q y <<< "$v"` is the CORRECT form.
# The first version matched the second `|` of `||` and flagged correct code -- and a grader that
# flags the fix as the defect gets routed around (RCA 4d). Require the char before `|` to not be `|`.
BANNED='(^|[^|])\|[[:space:]]*grep[[:space:]]+-[A-Za-z]*q'
# SCAN tests/ TOO (2026-07-14). The shape was reproduced INSIDE tests/red-first/run.sh -- in the
# harness that proves the realizability grader works -- and the enforcer could not see it because
# it only scanned scripts/ and hooks/. A test harness that fails open reports green just as loudly
# as a guard that fails open. FIFTH occurrence of this class; logged in the RCA.
SHELL_FILES=()
while IFS= read -r _f; do [ -n "$_f" ] && SHELL_FILES+=("$_f"); done < <(
  find "$ROOT/scripts" "$ROOT/tests" -name '*.sh' -type f 2>/dev/null | LC_ALL=C sort)

# --- 0. IT MUST PARSE (2026-07-14, earned the hard way) -----------------------
# MEASURED: an apostrophe inside a single-quoted jq program (`the domain's own`) terminated the string
# and left check-facts.sh with a bash SYNTAX ERROR. The shell printed "unexpected EOF" and the script
# EXITED 0 -- a vacuous PASS from a grader that never ran a single check. Nothing in the gate could see
# it: the banned-shape scan reads text, and every role obligation is a grep for a header the broken file
# still contained. A mechanism cannot fail closed on its own syntax error -- by the time bash notices,
# there is no script left to run -- so the ONLY place to catch it is here, from outside.
# The red-first must-REFUSE fixtures caught it (a known-bad returned rc=0); had only the must-ACCEPT
# case been run, rc=0 would have read as success. That is why both directions are load-bearing.
for f in "${SHELL_FILES[@]}"; do
  [ -e "$f" ] || continue
  bash -n "$f" 2>/dev/null \
    || say "$(basename "$f") — DOES NOT PARSE (bash -n). A script with a syntax error runs NOTHING and can still exit 0: a vacuous PASS from a gate that never evaluated anything. Fix the syntax; a mechanism cannot refuse from inside a file bash could not read."
done

for f in "${SHELL_FILES[@]}"; do
  [ -e "$f" ] || continue
  # strip full-line comments so the documented scars do not self-trip the check
  hits=$(grep -nE "$BANNED" "$f" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' || true)
  if [ -n "$hits" ]; then
    while IFS= read -r h; do
      [ -n "$h" ] || continue
      say "$(basename "$f"):${h%%:*} — BANNED SHAPE (pipe-into-grep-with-q) under pipefail (fails OPEN: grep exits early, upstream takes SIGPIPE, a successful match becomes a failed pipeline). Use a herestring: grep -Eq \"\$pat\" <<< \"\$var\""
    done <<< "$hits"
  fi
done

# --- 2/3/4. ROLE-DRIVEN OBLIGATIONS (scripts/ + hooks/ -- tests are harnesses, not gates) ------
for f in "$ROOT"/scripts/*.sh "$ROOT"/scripts/lib/*.sh; do
  [ -e "$f" ] || continue
  b="$(basename "$f")"
  SCANNED=$((SCANNED+1))
  role="$(role_of "$f")"

  # THE TIGHTENING: an undeclared file fails. Nothing is classified by guesswork.
  if [ -z "$role" ]; then
    say "$b — NO \`# SO-ROLE:\` DECLARATION. Every shell file must declare its role ($VALID_ROLES) on its second line. Classification is declared, never inferred: a mechanism added without a role would otherwise pass the gate simply because nobody remembered to list it."
    continue
  fi
  case " $VALID_ROLES " in
    *" $role "*) ;;
    *) say "$b — unknown role '$role' (must be one of: $VALID_ROLES)"; continue ;;
  esac

  case "$role" in
    guard)
      grep -Fq 'FAILURE DIRECTION' "$f" \
        || say "$b [guard] — no FAILURE DIRECTION header. State what it does when its check errors, its dependency is missing, or its input is malformed. A direction nobody wrote down is a direction nobody audits."
      grep -Fq 'FAIL-CLOSED INPUT VALIDATION' "$f" \
        || say "$b [guard] — no fail-closed input validation. On malformed input it exits non-zero-but-not-2, which Claude Code treats as a NON-BLOCKING error: THE TOOL PROCEEDS. Measured 2026-07-14: 25/25 payload-guard combinations failed OPEN this way."
      grep -Fq 'exit 2' "$f" \
        || say "$b [guard] — never exits 2; it cannot BLOCK. Any non-2 exit lets the tool proceed."
      covered "$b" \
        || say "$b [guard] — no fixture exercises it. A guard that has never refused a known-bad input is an unproven no-op."
      ;;
    mechanism)
      grep -Fq 'FAILURE DIRECTION' "$f" \
        || say "$b [mechanism] — no FAILURE DIRECTION header. A mechanism whose exit code the gate reads is a guard on every future build: if it fails open it certifies a fabricated corpus as CLEAN, and downstream agents CONFORM to a certified corpus rather than questioning it."
      grep -Fq 'FAIL-CLOSED INPUT VALIDATION' "$f" \
        || say "$b [mechanism] — no fail-closed input validation. If the gate reads your exit code, you are a MECHANISM, not a tool: you must refuse when your dependency is missing or your input is unreadable, never bless what you could not read."
      grep -Fq 'exit 2' "$f" \
        || say "$b [mechanism] — never exits 2. It cannot signal 'I could not evaluate this', so an evaluation it never performed is indistinguishable from a pass."
      covered "$b" \
        || say "$b [mechanism] — no fixture feeds it garbage. Measured 2026-07-14: three mechanisms exited 0 on binary input and on a bogus base sha (a vacuous PASS — certifying a file they could not read). A mechanism with no garbage-input fixture is unproven."
      ;;
    lib)
      grep -Fq 'FAILURE DIRECTION' "$f" \
        || say "$b [lib] — no FAILURE DIRECTION header. Its helpers define fail-closed behaviour for every caller."
      ;;
    tool) ;;   # runners and pure functions: they bless nothing, so they gate nothing
  esac
done

[ "$SCANNED" -gt 0 ] || {
  echo "check-shell-safety: ZERO files scanned under '$ROOT'. An empty scan can never be a pass. Failing CLOSED." >&2
  exit 2
}

if [ "$FAILS" -eq 0 ]; then
  echo "PASS: shell safety — no banned pipe-into-grep-with-q shape; every guard fails CLOSED and declares its direction."
  exit 0
fi
echo "---"
echo "$FAILS shell-safety violation(s)."
exit 1
