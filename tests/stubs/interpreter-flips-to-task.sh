#!/usr/bin/env bash
# A stand-in for `claude`. It answers `conversation` while the ledger holds one entry and
# `task` once a second arrives, carrying the first message's content into the task's MUST
# lines — the behaviour the real prompt asks for, made deterministic so a fixture can
# prove the flip without a model call.
IN="$*"
if grep -q '^#2' <<< "$IN"; then
cat <<'EOF'
OUTCOME
Build the token counter that was discussed.
KIND: task

MUST
- use the approach discussed in the conversation (#1)
- build the thing (#2)

MUST NOT

DONE WHEN
D1 the counter exists and runs

OPEN QUESTION
none
EOF
else
cat <<'EOF'
OUTCOME
Give a view on how to count tokens.
KIND: conversation

MUST
- answer the question about counting tokens (#1)

MUST NOT

DONE WHEN
D1 the person has an answer

OPEN QUESTION
none
EOF
fi
