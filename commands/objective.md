---
description: Print this session's objective file
allowed-tools: Read, Bash
---

Show the operator this session's objective file, verbatim. Do not summarise it, do not
comment on it, and do not change it.

The path is named in the `SESSION OBJECTIVE` block in your context, on the line
beginning `file:`. Read that file and print it — a Read of this session's own objective
file is always permitted, even while the write-before-act lock is engaged.

Where no Read tool exists (Codex), run instead:
`${CLAUDE_PLUGIN_ROOT}/scripts/objective-show.sh <the path from the SESSION OBJECTIVE block>`
That script only prints; it is the one shell command the guard permits near the
objective home, and only on its own with no pipe, redirection or chaining.

There is no set, revise, decide or complete command. The operator's typed messages are
the only input to the OPERATOR LEDGER — the hook appends every one of them verbatim —
and the mechanism does the rest. If the operator answers a NEEDS-DECISION question, he
answers it by typing it; that message becomes the next ledger entry on its own.
