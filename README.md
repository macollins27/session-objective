# session-objective

**Every session has one objective file, split four ways. The operator's own messages. An OBJECTIVE
written from them by a call that has never seen the session. A WORKFLOW of four checkpoints written
with it. The agent's PROGRESS. The agent may not touch the first three, may not change a file in
the project until it has recorded a passing proof that it looked at what it is changing, and may
not end a turn while the objective is ACTIVE.**

A Claude Code and Codex plugin: five hooks, one file per session, no configuration. You type in
plain language and correct naturally; you never edit the file. You may glance at it.

Version 3.0 exists because version 2 was ignored. Measured over 57 objective files: the objective
was translated well and then not acted on, 23 of 57 sessions ended with STATUS still ACTIVE after
the three-denial budget ran out, and 11 files carried an empty CURRENT REALITY. The one part that
held was the one part a machine checks — 187 of 206 proof lines are non-trivial, because the stop
gate re-runs them. So 3.0 replaces advice with checkpoints: exit conditions the hooks refuse to let
the agent pass without proof, and locks that make their order physical.

---

## Why it is split

Version 1 had the in-session agent write the objective. That agent's context is full of doctrine,
project rules, tool output and its own reasoning, and all of it leaked in: measured in a real
session, the objective grew past 1,500 words and carried lines like *"corpus recall before grep"*
and *"reviewer budget"*, which the operator never said. The fix is not a better instruction to that
agent. It is to take the pen away from it.

```
# OPERATOR LEDGER (hook-written, append-only, agent may not edit)
- <ts>  <verbatim operator message>

# OBJECTIVE (interpreter-written from the ledger only; revision N, bound to ledger entry K; model M)
OUTCOME        what the whole set of his messages asks for, ≤ 120 words
KIND           task | conversation — is he asking for a thing, or for your thoughts?
MUST           his requirements, each citing the entry it came from   (#2)
MUST NOT       his constraints and rejected interpretations, each citing an entry
DONE WHEN      D1..Dn, observable end states in plain language
OPEN QUESTION  exactly one plain question, or "none"

# WORKFLOW (interpreter-written with the objective; the fixed skeleton, filled for this task)
C1 UNDERSTAND — what must have been OBSERVED before anything changes, ≤ 40 words
C2 BUILD — what must EXIST or have CHANGED, ≤ 40 words
C3 PROVE — every DONE WHEN item has a proof that reproduces        (fixed text)
C4 VERIFY — a fresh-context verifier ran after the last change and returned PASS   (fixed text)

# PROGRESS (agent-written)
CHECKPOINTS      C1 PROOF: <command> => exit <code>, then C2. Append-only, run when recorded.
PROOFS           one line per D-item
IN FLIGHT        background task ids, or "none"
STATUS           ACTIVE | WAITING: <what> | NEEDS-DECISION: <question> | COMPLETE
```

`CURRENT REALITY` and `FRONTIER` are gone, and with them the demand that the agent rewrite a
narrative every turn: they were written by the same drifting context they were meant to correct.
PROGRESS is written when a checkpoint is reached, when something is launched in the background, and
when the status changes. `KIND: conversation` gets a one-line WORKFLOW, `none (conversation)`, and
no lock.

`$SESSION_OBJECTIVE_HOME/sessions/<session_id>/objective.md`, default home `~/.session-objective`.
One file per session, outside the project, never in the repository. A subagent gets its own file at
`<session_id>/<agent_id>`, because a subagent's events carry the parent's `session_id` — measured,
not assumed (`docs/payload-evidence/`). Caps: OBJECTIVE and WORKFLOW together ≤ 280 words, PROGRESS ≤ 300.

## Who writes what

| layer | writer | everything else |
|---|---|---|
| LEDGER | the `UserPromptSubmit` hook, from genuine operator prompts only | denied |
| OBJECTIVE | the interpreter, from the ledger only | denied |
| WORKFLOW | the interpreter, with the objective | denied |
| PROGRESS | the agent, via `Write`, `Edit` or `apply_patch` on exactly this session's path | validated |

Any write whose **result** changes a byte of LEDGER, OBJECTIVE or WORKFLOW is denied — the content the
runtime would actually leave on disk is what gets judged, not the request that asked for it.

The shell is held to the same boundary in two passes, because a literal match is not enough: a
command is refused if its text names `objective.md`, `.session-objective` or this session's
`sessions/<id>` anywhere, **and** every token in it that looks like a path is resolved against the
payload's own cwd and refused if it lands at or under the objective home. Where a path *lands*
decides it, not how it reads, so a relative path, a `../` hop or a differently-spelled route are all
refused. Two costs, both stated rather than hidden: a command that merely *mentions* `objective.md`
in a comment is refused in any repository (one reframe), and a path assembled purely from shell
variables — `printf x >> "$D/$F"` — contains no resolvable token and no static check can see where
it points. That residual is why the LEDGER and OBJECTIVE layers are **also** compared byte-for-byte
on every sanctioned write: a tamper that gets past the shell guard still cannot be carried forward
by any write the agent makes.

## The interpreter

It runs inside the `UserPromptSubmit` hook, after the ledger append. Its entire world is the fixed
prompt in [`prompts/interpreter.md`](prompts/interpreter.md), the ledger verbatim, and the previous
OBJECTIVE so that a revision is a revision. No doctrine, no CLAUDE.md, no rules, no memory, no
transcript, no tool output.

```
claude -p --system-prompt "$(cat prompts/interpreter.md)" \
  --setting-sources "" --no-session-persistence --output-format json \
  --restricted --disable-slash-commands \
  --strict-mcp-config --mcp-config '{"mcpServers":{}}' -- "<the ledger>" < /dev/null
```

from an empty temp directory, with `SESSION_OBJECTIVE=off` so it cannot recurse into this plugin.
Every flag was verified by measurement rather than read off a page: a probe placing a loud
`CLAUDE.md` **and** a project hook in that directory confirmed neither reached the model, and
`--mcp-config '{}'` — which the documentation suggests — is rejected; the shape is
`{"mcpServers":{}}`.

Its answer is a claim until something checks it. `scripts/objective-validate.sh` requires every
heading, in order; the word caps; `DONE WHEN` numbered `D1, D2, D3`; at most one `OPEN QUESTION`;
no `MUST`/`MUST NOT` line dropped without a `SUPERSEDED by #K:` line carrying it; and the WORKFLOW:
exactly four lines, in order, with the fixed names, `C1` and `C2` between 3 and 40 words, `C3` and
`C4` compared **byte for byte** against their fixed text. Those two are not the model's to reword,
because what satisfies them is decided by a mechanism — the D-item re-run and the transcript — and
a reworded line would be a promise nothing checks. If the workflow is refused twice, the hook
substitutes the generic skeleton (*the current state of everything the outcome touches has been
observed* / *the outcome exists as the objective describes it*) rather than losing the revision: a
weak checkpoint still orders the work; no objective at all orders nothing. A refusal is
retried once with the violation in front of the model. If it still drops the operator's own lines,
the hook puts them back itself — byte for byte, untagged, with the repair recorded on its own line
underneath — so his words are not lost because a model would not repeat them.

**When it fails** — timeout, non-zero exit, malformed answer — the OBJECTIVE is left exactly as it
was, one visible line says so, and the agent keeps working. The session is never wedged. The next
message retries, and the Stop gate refuses COMPLETE while the binding lags the ledger.

Measured latency over the acceptance runs: **p50 7.6 s** (5.4 – 9.1 s), once per operator message.

## The gates

| STATUS | Stop hook |
|---|---|
| `ACTIVE`, `KIND: conversation` | **Allowed.** He asked for an answer, not for a thing; the reply is the deliverable. |
| `ACTIVE`, `KIND: task` | Denied, naming the **current checkpoint** — the first of C1, C2 without a proof on disk, else C3 if a D-item has no proof, else C4 — with its exit condition and how to record it. Bounded at 3 denials per operator message, then allowed with a visible line. |
| `ACTIVE`, `KIND: task`, turn made **no tool calls** since your last message | Denied regardless of the budget. The apology-that-ends-the-turn never passes. |
| `WAITING: <what is in flight>` | Allowed only when the transcript shows a background launch since your last message that has not reported back. |
| `NEEDS-DECISION: <question>` | Allowed only if the question appears verbatim in the final message. |
| `COMPLETE` | Allowed only when the `C1` and `C2` checkpoint proofs reproduce, every `D-item` in `DONE WHEN` has a `PROOFS` line that reproduces, the transcript shows a fresh-context verifier answering `PASS` after the last product write, and the objective is bound to every ledger entry. |

A proof is `PROOF: <command> => exit <code>` (re-run in the session cwd, 60 s bound, never
elevated, destructive commands refused) or `PROOF: reply contains "<phrase>"` (≥ 12 characters,
checked verbatim against the final message). A proof that cannot fail is refused: `true`, `:`,
`exit 0`, a bare `echo`/`printf`, a substitution wrapped in one (`echo $(false)` exits 0 every
time), a single bare word with no argument and no path (`date`, `pwd`, `ls`), and the utilities that
report the machine rather than the work whatever arguments they carry (`date`, `pwd`, `whoami`,
`hostname`, `id`, `uname`, `uptime`, `sleep`). So is a proof resting on the absence of a file
nothing says ever existed.

**What no check here can decide: whether a proof is about its D-item at all.** `test -f build.log`
is a real command with a real exit code, and nothing mechanical can tell that the D-item it is
attached to was about something else. That judgement belongs to a fresh reader of the finished
work, and this plugin does not pretend otherwise.

## The checkpoints, and the lock

```
C1 UNDERSTAND   what must have been OBSERVED about the current state before anything changes
C2 BUILD        what must EXIST or have CHANGED
C3 PROVE        every DONE WHEN item has a proof that reproduces
C4 VERIFY       a fresh-context verifier ran after the last change and returned PASS
```

**The edit lock.** While the objective is a task and no `C1` proof is on disk, every `Write`,
`Edit`, `MultiEdit`, `NotebookEdit` and `apply_patch` landing under the session cwd is denied, with
C1's exit condition and the one line that records it. The scratchpad, `/tmp` and the objective file
itself are outside cwd and are never locked: the lock stops the agent changing what it has not
looked at, not thinking on paper.

*Its bound, stated rather than hidden:* **Bash is not covered.** An agent that wanted to evade the
lock could write a file with `cat >`. The lock forces order on an agent that drifts; it is not a
defence against one that evades, and the byte-for-byte layer comparison is what covers tampering.

**A proof is never on disk unless it passed.** When a write records a `Cn PROOF` line the file does
not already carry, the gate runs that command right then — same bounds, same trivial, destructive
and unwitnessed-absence classifiers as the stop gate — and denies the write with the command's own
output if it does not reproduce. Recorded proofs are **append-only**: an existing `Cn PROOF` line
may not be changed or removed, and `C2` may not be recorded before `C1` is on disk. `C3` and `C4`
carry no proof lines of their own; they are satisfied by the D-item re-run and by the transcript.

**C4, from the transcript.** After the last `Write`/`Edit`/`MultiEdit`/`NotebookEdit`/`apply_patch`
whose target lands under cwd, there must be a later `Agent`/`Task`/`Workflow` call, or a shell call
carrying `claude -p` or `codex exec`, whose result contains the whole word `PASS`. If the transcript
holds no product write at all, the verifier must come after the operator's last message. Both
runtime formats are read. An unreadable or unrecognisable transcript makes this one check — and the
zero-tool-call check — fail **open**, with a visible line: a parser bug must never wedge a session.
Everything else stays fail-closed, `WAITING` included.

## Just talking

Not every message is a job. Sometimes he wants an answer, an opinion, or to think out loud about
work he might ask for later — and under the task rules every one of those turns was refused for
making no tool calls, with the only way out being to write a `PROGRESS` `COMPLETE` carrying a
reply-contains proof. Correct by the rules, and completely wrong for a conversation.

So the interpreter decides, from his words alone, which kind of thing this is, and says so on one
line under `OUTCOME`:

```
KIND: conversation    he asked for an answer, an explanation, an opinion, a discussion.
                      Nothing has to exist or change when it is over.
KIND: task            something must exist or change: a file, a setting, work done.
```

On `conversation` the Stop gate stands down: a reply with no tool calls ends the turn, because the
reply **is** the deliverable, and no `PROGRESS` write is required. The injected instruction says so
in as many words, and adds the part that matters — answer him properly, decide, do not hand the
decision back. `COMPLETE`, `NEEDS-DECISION` and `WAITING` still mean what they mean if the agent
writes one.

A conversation becomes a task the moment he asks for the thing, and this is where keeping the whole
ledger pays: everything he said while talking it through is already in the interpreter's input, so
it lands in the new task's `MUST` and `MUST NOT` lines, each cited to the message it came from. A
task never quietly becomes a conversation. A `KIND` line the gate cannot read is treated as `task`,
which is the stricter of the two — a gate that stands down on a line it could not parse is a gate
that stands down whenever the format drifts.

## Install

```bash
claude plugin marketplace add macollins27/session-objective
claude plugin install session-objective@session-objective
```

For one session, without installing: `claude --plugin-dir /path/to/session-objective`.

**Codex**: `scripts/install-codex.sh`. Codex does not run a plugin's own `hooks.json` — every Codex
hook runs from `~/.codex/hooks.json` — and its sandbox refuses writes outside the project, while
the objective file lives outside it on purpose. The installer wires both, idempotently, and backs
up what it touches; then approve the hooks once in the interactive Codex UI.

Requires `jq`. Every hook exits 2 with the install command if it is missing.

### The fleet switch

```bash
SESSION_OBJECTIVE=off claude -p "..."
```

Every hook stands down with one visible line, interpreter included. An un-endable turn breaks
automation, so headless and fleet sessions set this.

## The operator surface

```
/objective     print this session's file
```

That is all of it. No set, revise, decide or complete command: an agent-invocable way to add a
ledger entry is an agent-invocable way to put words in your mouth. Your typed messages are the only
input, so when you answer an OPEN QUESTION you answer it by typing it, and that message becomes the
next entry and rewrites the objective on its own.

---

## Measured in real use

Every rule below was earned by watching this thing run, not by imagining how it might fail.

**2026-09-13, version 3.0 — the objective was read and ignored.** Across 57 objective files and
100+ agents: **23 of 57** sessions ended with STATUS still ACTIVE — the stop gate refused three
times, the budget ran out, and the agent was let go, so the apology exit was delayed rather than
prevented. **60** transcripts carry stop refusals and the work still did not move. **11** files
have an empty CURRENT REALITY, and sampled ACTIVE-ended files have a blank PROGRESS layer
altogether: per-turn rewriting produced nothing the agent would not have produced anyway, because
it is written by the same drifting context it is meant to correct. The one part that held is the
one part a machine checks — **187 of 206** proof lines are non-trivial, because the stop gate
re-runs them. Text that describes what an agent should do is advice; on this machine only
mechanisms that refuse have ever changed agent behaviour. Hence checkpoints, the edit lock, proofs
run at the moment they are recorded, and a verifier read out of the transcript rather than claimed.

**2026-09-13, version 2.0 — pollution control.** A throwaway repo carrying a project `CLAUDE.md`
and a memory file that both said *"Always run corpus recall before any grep. Reviewer budget is two
spawns"*, and demanded rollback sections and zebra-striped tables. Across a three-message session
those phrases appear **nowhere** in the OBJECTIVE — and the control proves the session really was
polluted: the same phrases appear in the agent's own context twice each, and the `CLAUDE.md` header
once. That gap is the whole product.

**2026-09-13, version 1.x, four defects fixed.**
- *A harness notification is not the operator.* Background task-notifications arrive through
  `UserPromptSubmit` exactly as a typed message does; two were appended to the ledger as entries 5
  and 6, one a 4.6 KB verifier report. They are now turned away, run no interpreter, and clear
  `WAITING`.
- *The injection exceeded the hook output limit.* A 10.8 KB injection was persisted to a file
  instead of injected, so the objective was absent on the turn that needed it most. 2.0 never
  injects the ledger at all — it is the interpreter's input, not the agent's — and renders one line
  saying how many entries there are.
- *The gate forced a false COMPLETE.* Twice the agent had a verifier running in the background,
  needed to end the turn to receive its notification, was denied for `ACTIVE`, and set `COMPLETE`
  to escape with `FRONTIER` still reading "relay the verifier verdict". `WAITING` is the third
  exit, and the hook reads the transcript rather than taking the claim.
- *`Edit` was denied, forcing 11 KB full rewrites.* An edit is now applied to a copy and the result
  is validated like any other write.

**2026-09-13, version 2.0.1, three defects a fresh verifier found.** A Bash command using a
*relative* path from the objective home's parent named none of the guarded strings and was allowed;
the append landed in the append-only ledger. The `[kept by hook]` fallback was dead code — it tagged
the restored line, and the validator, which compares the operator's previous lines exactly, then
refused the repair itself, so the objective was never revised. And `D1 PROOF: date => exit 0`,
attached to a D-item about a file that did not exist, passed both gates and reported COMPLETE.

**2026-09-13, Codex CLI 0.154.0 — one prompt, two entries.** A single typed message fired
`UserPromptSubmit` twice and the ledger recorded it twice. An identical prompt arriving in the same
minute as the entry already at the end of the ledger is the same prompt; it is not appended and the
interpreter is not re-run.

**2026-09-12, the deadlock.** Outside `bypassPermissions` the harness refuses a `Write` to a file it
has not read, and the objective file sits outside the project, so both calls need a permission a
headless session has nobody to grant. Four of four real runs wedged on message one. A `Read` of this
session's own objective is now explicitly allowed by the gate — an explicit `allow`, not merely
standing aside, because standing aside leaves the prompt in place.

**2026-09-12, proof theater.** On an advice-only task the agent invented
`test ! -e <scratchpad>/code-written.flag => exit 0` — a file that never existed and never would —
and the gate accepted COMPLETE. `PROOF: reply contains "<phrase>"` is the honest form for an outcome
whose evidence is the reply, and a negative-existence proof is refused unless the path is named
somewhere that is not the proof line itself — in 3.0, the WORKFLOW or a proof already recorded.

---

## Guard invariants

Every hook declares a `FAILURE DIRECTION` header; validates that stdin parses as a JSON object and
exits 2 when it does not; requires `jq`. `PreToolUse` answers with the
`hookSpecificOutput.permissionDecision` shape; `Stop` denies with exit 2 and stderr. Exit 2 is the
only code Claude Code treats as BLOCK — any other non-zero is a non-blocking error and the tool
proceeds — so a guard that cannot evaluate its input exits 2, never 1.

`scripts/check-shell-safety.sh` enforces this mechanically: every script declares `# SO-ROLE:`,
every guard and mechanism carries its failure direction, its fail-closed input validation, an
`exit 2` and a garbage-input fixture, every `.sh` must pass `bash -n`, and the `| grep -q` shape
that fails open under `pipefail` is banned outright.

## Tests

```bash
tests/run.sh --gate        # red-first, then the real run, then the installer proof and the census
tests/run.sh               # every fixture against the real hooks
tests/run.sh --red-first   # every fixture must FAIL with its guard stubbed out
```

`--red-first` replaces the guard under test with an inverted stub and requires every fixture to
fail: a fixture that still passes without its guard never observed it. Its bound, stated plainly: it
proves no fixture is vacuous, not that a fixture depends on one clause inside a guard. The runner is
three-state — pass / fail / nothing-ran — so an empty suite can never go green, and a fixture skipped
for a missing dependency is named and refuses to go green undeclared.

---

## Related tools, not integrated

- `reanchor` (`~/.claude/skills/reanchor/SKILL.md`) — recovers a session that has already gone
  wrong, by rebuilding the objective from the transcript with a fresh subagent. This plugin is the
  standing version of the same idea, run every turn so the recovery is rarely needed.
- `orientation_sentinel` (`~/.claude/agents/orientation_sentinel.toml`) — judges whether a proposed
  plan advances the operator's durable orientation. It judges alignment; this plugin holds the
  record the judgment would be made against.
- `goalpost` — installed alongside, both inject. They are independent; neither reads the other's
  state.

MIT. Contributions: add the fixture first, watch it go red, then write the guard.
