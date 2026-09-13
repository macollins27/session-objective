#!/usr/bin/env bash
# A stand-in for `claude` that always drops the operator's MUST line, on every attempt.
# It exists so the kept-by-hook fallback can be proved without a model call: the fallback
# only runs when the model refuses twice, which is not something a live call can be asked
# for on demand.
cat <<'EOF'
OUTCOME
Ship the thing.

MUST
- something entirely different (#2)

MUST NOT

DONE WHEN
D1 the thing exists

OPEN QUESTION
none
EOF
