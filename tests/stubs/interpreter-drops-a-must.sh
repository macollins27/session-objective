#!/usr/bin/env bash
# A stand-in for `claude` that always drops the operator's MUST line, on every attempt.
# It exists so the kept-by-hook fallback can be proved without a model call: the fallback
# only runs when the model refuses twice, which is not something a live call can be asked
# for on demand.
cat <<'EOF'
OUTCOME
Ship the thing.
KIND: task

MUST
- something entirely different (#2)

MUST NOT

DONE WHEN
D1 the thing exists

OPEN QUESTION
none
# WORKFLOW
C1 UNDERSTAND — the current state of everything the outcome touches has been observed
C2 BUILD — the outcome exists as the objective describes it
C3 PROVE — every DONE WHEN item has a proof that reproduces
C4 VERIFY — a fresh-context verifier ran after the last change and returned PASS
EOF
