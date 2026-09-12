---
description: Print this session's objective file
allowed-tools: Read
---

Show the operator this session's objective file, verbatim. Do not summarise it, do not
comment on it, and do not change it.

The path is named in the `SESSION OBJECTIVE` block in your context, on the line
beginning `file:`. Use the **Read** tool on exactly that path and print what comes back.
A Read of this session's own objective file is always permitted, even while the
write-before-act lock is engaged — that is one of the two calls Rule 1 allows.

Do not reach for the shell. Every Bash command that names the objective home is denied,
and there is no script to run: this plugin ships nothing that can write to the ledger on
your behalf, and nothing that reads it either. Where no Read tool exists, reproduce the
`SESSION OBJECTIVE` block already in your context, verbatim, and say that is what you
are showing.

There is no set, revise, decide or complete command. The operator's typed messages are
the only input to the OPERATOR LEDGER — the hook appends every one of them verbatim —
so when he answers a NEEDS-DECISION question he answers it by typing it, and that
message becomes the next ledger entry on its own.
