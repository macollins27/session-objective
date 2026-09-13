# session-objective

**Every session has one objective file, split three ways. The operator's own messages. An
OBJECTIVE written from them by a call that has never seen the session. The agent's PROGRESS. The
agent may not touch the first two, and may not end a turn while the objective is ACTIVE.**

A Claude Code and Codex plugin: five hooks, one file per session, no configuration. You type in
plain language and correct naturally; you never edit the file. You may glance at it.

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
MUST           his requirements, each citing the entry it came from   (#2)
MUST NOT       his constraints and rejected interpretations, each citing an entry
DONE WHEN      D1..Dn, observable end states in plain language
OPEN QUESTION  exactly one plain question, or "none"

# PROGRESS (agent-written)
PROOFS           one line per D-item
CURRENT REALITY  ≤ 80 words
FRONTIER         one line, the next concrete action
IN FLIGHT        background task ids, or "none"
STATUS           ACTIVE | WAITING: <what> | NEEDS-DECISION: <question> | COMPLETE
```

`$SESSION_OBJECTIVE_HOME/sessions/<session_id>/objective.md`, default home `~/.session-objective`.
One file per session, outside the project, never in the repository. A subagent gets its own file at
`<session_id>/<agent_id>`, because a subagent's events carry the parent's `session_id` — measured,
not assumed (`docs/payload-evidence/`). Caps: OBJECTIVE ≤ 200 words, PROGRESS ≤ 300.

## Who writes what

| layer | writer | everything else |
|---|---|---|
| LEDGER | the `UserPromptSubmit` hook, from genuine operator prompts only | denied |
| OBJECTIVE | the interpreter, from the ledger only | denied |
| PROGRESS | the agent, via `Write`, `Edit` or `apply_patch` on exactly this session's path | validated |

Any write whose **result** changes a byte of LEDGER or OBJECTIVE is denied — the content the
runtime would actually leave on disk is what gets judged, not the request that asked for it.

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
and no `MUST`/`MUST NOT` line dropped without a `SUPERSEDED by #K:` line carrying it. A refusal is
retried once with the violation in front of the model. If it still drops the operator's own lines,
the hook puts them back itself, tagged `[kept by hook]` — his words are not lost because a model
would not repeat them.

**When it fails** — timeout, non-zero exit, malformed answer — the OBJECTIVE is left exactly as it
was, one visible line says so, and the agent keeps working. The session is never wedged. The next
message retries, and the Stop gate refuses COMPLETE while the binding lags the ledger.

Measured latency over the acceptance runs: **p50 7.6 s** (5.4 – 9.1 s), once per operator message.

## The gates

| STATUS | Stop hook |
|---|---|
| `ACTIVE` | Denied, with `FRONTIER` as the instruction. Bounded at 3 denials per session, then allowed with a visible line. |
| `ACTIVE`, turn made **no tool calls** since your last message | Denied regardless of the budget. The apology-that-ends-the-turn never passes. |
| `WAITING: <what is in flight>` | Allowed only when the transcript shows a background launch since your last message that has not reported back. |
| `NEEDS-DECISION: <question>` | Allowed only if the question appears verbatim in the final message. |
| `COMPLETE` | Allowed only when every `D-item` in `DONE WHEN` has a `PROOFS` line that reproduces, and the objective is bound to every ledger entry. |

A proof is `PROOF: <command> => exit <code>` (re-run in the session cwd, 60 s bound, never
elevated, destructive commands refused) or `PROOF: reply contains "<phrase>"` (≥ 12 characters,
checked verbatim against the final message). A proof that cannot fail is refused, and so is one
resting on the absence of a file nothing says ever existed.

There is **no write-before-act lock** in 2.0. Interpretation has already happened, inside the hook,
before the agent saw the message. There is nothing left to force.

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
whose evidence is the reply, and a negative-existence proof is refused unless `CURRENT REALITY`
names the path.

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
