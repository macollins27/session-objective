#!/usr/bin/env bash
# A stand-in for `claude` that answers with a well-formed OBJECTIVE and NO WORKFLOW, on
# every attempt. It exists so the generic-skeleton fallback can be proved without a model
# call: that path only runs when the validator refuses the workflow twice running.
cat <<'ANSWER'
OUTCOME
Ship the thing.
KIND: task

MUST
- build it (#1)

MUST NOT

DONE WHEN
D1 the thing exists and runs

OPEN QUESTION
none
ANSWER
