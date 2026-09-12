---
description: Print this session's objective file, or record the operator's answer to a NEEDS-DECISION question
argument-hint: [decide "<answer>"]
allowed-tools: Bash
---

The objective file for this session is named in the `SESSION OBJECTIVE` block in your
context (the line beginning `file:`). Use that exact path below as `<FILE>`.

Arguments given: `$ARGUMENTS`

- If the arguments are empty, run:
  `${CLAUDE_PLUGIN_ROOT}/scripts/objective-show.sh <FILE>`
  and show the operator the output as-is. Do not summarise it and do not comment on it.

- If the arguments begin with `decide`, take everything after the word `decide`
  (stripping one pair of surrounding quotes) as the operator's answer and run:
  `${CLAUDE_PLUGIN_ROOT}/scripts/objective-decide.sh <FILE> "<answer>"`
  That appends the answer to the append-only ledger exactly as typing it would, and
  resets STATUS to ACTIVE. Then rewrite the OBJECTIVE layer bound to the new entry and
  carry on with the work; the answer is a decision, not a new task.

There is no set, revise, or complete command. The operator's words are the only input
and the mechanism does the rest.
