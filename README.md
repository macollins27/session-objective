# session-objective

**Every session has one objective file. The agent must rewrite it before it may act, may never
silently drop anything the operator said, and may not end a turn while the objective is ACTIVE.**

A Claude Code plugin: five hooks, one file per session, no configuration. You type in plain
language and correct naturally; you never edit the file. You may glance at it.

---

## The file

```
$SESSION_OBJECTIVE_HOME/sessions/<session_id>/objective.md      # default home: ~/.session-objective
```

One file per session id, outside the project, never in the repository. Up to 50 sessions run in
parallel; there is exactly one writer per file, so no locking exists.

Two layers:

```
# OPERATOR LEDGER (hook-written, append-only, agent may not edit)
- 2026-09-12T14:02Z  <verbatim user message 1>
- 2026-09-12T14:09Z  <verbatim user message 2>

# OBJECTIVE (agent-written, rewritten every turn, revision N, bound to ledger entry K)
DESIRED OUTCOME
SUCCESS CONDITIONS      one per line; each ends with  PROOF: <command> => exit <code>
CONSTRAINTS
REJECTED INTERPRETATIONS
FAILED APPROACHES
CURRENT REALITY
FRONTIER                the next concrete action
STATUS                  ACTIVE | NEEDS-DECISION: <one plain question> | COMPLETE
```

The OBJECTIVE layer is capped at 1,800 words. A larger write is refused.

---

## The three rules

### Rule 1 — write before act  (`UserPromptSubmit` + `PreToolUse`)

On every message you send, the hook appends it to the ledger verbatim, then injects the whole file
with one instruction: rewrite the OBJECTIVE layer to reflect every ledger entry, then work. Until
the OBJECTIVE layer's bound ledger entry equals the latest ledger entry, `PreToolUse` denies every
tool call except a `Write` whose target is exactly this session's objective path.

On the first message of a session the file is created from an empty template and the instruction
adds: ask at most one question, and only if the desired outcome is genuinely ambiguous; otherwise
write it and go.

### Rule 2 — nothing said disappears  (`PreToolUse` on the objective write)

The hook diffs the previous OBJECTIVE layer against the proposed one. A line under `CONSTRAINTS` or
`REJECTED INTERPRETATIONS` may vanish only if the new text carries

```
SUPERSEDED <date> by ledger entry <K>: <old line>
```

Any other removal is denied with the missing line named. The ledger itself is immutable: any
`Write`, `Edit` or `Bash` that touches it is denied.

### Rule 3 — ACTIVE cannot end a turn  (`Stop`)

| STATUS | What the hook does |
|---|---|
| `ACTIVE` | Deny, with the `FRONTIER` text as the instruction. Bounded at 3 denials per session, then allow with the visible line `objective still ACTIVE; stop-hook budget exhausted`. |
| `ACTIVE`, and the turn made **no tool calls** since your last message | Denied regardless of the budget. That is the apology-that-ends-the-turn failure, and it never passes. |
| `NEEDS-DECISION: <question>` | Allowed only if the question is non-empty **and** the final assistant message actually contains it. |
| `COMPLETE` | Allowed only if every `SUCCESS CONDITION` carries a `PROOF` and the hook, re-running each command in the session cwd, reproduces the recorded exit code. Any mismatch is denied, naming the condition. |

The `COMPLETE` branch is the defense against the agent grading itself: a recorded exit code the
machine will not reproduce is not a completion.

`stop_hook_active` is honoured exactly as `~/.claude/hooks/lead-persistence-gate.py` honours it —
the hook never blocks a continuation it caused itself, which is what bounds the whole mechanism.

---

## Continuity

`SessionStart` re-injects the session's file on `startup`, `resume` and `compact`. A `--resume`d
session keeps its id and therefore its file. A new session in the same folder starts empty. On
`/clear` the id survives but the intent does not, so the file is archived as
`objective.<timestamp>.md` and the session starts empty.

---

## The operator surface

```
/objective                    print this session's file
/objective decide "<answer>"  append your answer to the ledger, exactly as typing it would
```

There is no set, revise or complete command. Your words are the only input and the mechanism does
the rest.

---

## Install

```bash
claude plugin marketplace add macollins27/session-objective
claude plugin install session-objective@session-objective
```

For one session, without installing:

```bash
claude --plugin-dir /path/to/session-objective
```

Requires `jq`. Every hook exits 2 with the install command if it is missing. On Codex, evaluating
an `*** Update File:` patch also requires the `codex` binary on PATH, which by definition it is.

### The fleet switch

```bash
SESSION_OBJECTIVE=off claude -p "..."
```

Every hook stands down with one visible line. An un-endable turn breaks automation, so headless and
fleet sessions set this.

---

## The subagent file key — the payload question, settled

Inside a subagent, `PreToolUse` and `PostToolUse` carry the **parent's** `session_id` and
`transcript_path`, plus the subagent's own `agent_id` and `agent_type`. `Stop` does not fire inside
a subagent at all; `SubagentStop` fires instead, again with the parent's `session_id` plus
`agent_id`. Captured live on Claude Code 2.1.269, 2026-09-12; the raw payloads are in
[`docs/payload-evidence/`](docs/payload-evidence/).

Parent and child would therefore share one file and write over each other, which breaks the
one-writer rule. So whenever `agent_id` is present the key is `<session_id>/<agent_id>`:

```
~/.session-objective/sessions/<session_id>/objective.md              # the session
~/.session-objective/sessions/<session_id>/<agent_id>/objective.md   # each subagent
```

`SubagentStart` seeds the child's file from the parent's OBJECTIVE layer with an empty ledger, and
injects it. A subagent gets **injection only**: no write-before-act lock (its binding equals its
empty ledger from the start) and no stop gate, because a subagent ends by reporting.

---

## Failure scenarios

Each is a fixture or a rule stated here; none is skipped.

| | Scenario | What happens |
|---|---|---|
| F1 | Rubber-stamp rewrite | The bound ledger entry must **advance**; a write whose binding does not advance is denied. An identical body under an advanced binding is allowed on purpose — semantic quality is not mechanically decidable. |
| F2 | Fake `NEEDS-DECISION` to escape the gate | The question must appear in the final assistant message, and your next message resets STATUS to ACTIVE (the ledger hook rewrites the status line when it appends), so nothing can park in NEEDS-DECISION. |
| F3 | Trivial `PROOF` (`true`, `:`, `exit 0`, a bare `echo`, empty) | Denylisted, at the write and again at the stop, denied with the condition named. |
| F4 | Destructive `PROOF` re-run by the Stop hook | The hook refuses to re-run anything matching the destructive denylist (`rm`, `git push`, `git reset`, `docker`, `curl -X`, `sudo`, `>`-redirects, …) and denies COMPLETE naming it. Proofs run with a 60-second bound, in the session cwd, never elevated. |
| F5 | Deadlock: writing the objective through a Bash heredoc while Bash is locked | The injected instruction names the exact tool and path; Bash stays denied and the deny text repeats the tool and the path. |
| F6 | Plan mode | The harness itself blocks `Write`, so a lock would wedge the session: when `permission_mode` is `plan` the hooks **inject only**. |
| F7 | Huge pasted messages | The ledger keeps the full text; the injection renders the last 3 entries in full and older entries truncated to 200 characters with a pointer to the file, capping the whole injection near 3,000 words. |
| F8 | `/clear` — same session id, stale objective | Archived as `objective.<timestamp>.md`; the session starts empty. `compact` and `resume` re-inject unchanged. |
| F9 | Ledger tampering via relative paths, symlinks, `sed -i`, `tee`, `python -c` | Every file-tool target is resolved to its real path before comparison, and every Bash command is scanned for the objective home; any match that is not the sanctioned `Write` is denied. |
| F10 | Subagents | Injection only — no lock, no stop gate. Seeded from the parent's OBJECTIVE layer. |
| F11 | Headless / fleet sessions | `SESSION_OBJECTIVE=off` disables every hook with one visible line. |
| F12 | Transcript unreadable or its format changed | The zero-tool-call check alone fails **open**, with a visible line — a parser bug must never wedge a session. Every other rule stays fail-closed. |
| F13 | Missing `jq` | Exit 2 with the install command on stderr, on every hook. |
| F14 | Stop-gate budget | 3 denials per session, then allow with the visible line, so a genuinely stuck agent can never loop forever. |
| F15 | `goalpost` installed alongside | Both inject. The two are independent; there is no integration and neither reads the other's state. |
| F16 | Stop fired while the objective file is missing (hook installed mid-session) | Allow, with a visible line. Your next message creates the file. |
| F17 | Codex has no `Write` tool, so Rule 1's one exception could never be satisfied | The guard reads the target path out of the `apply_patch` patch text and runs the same Rule 2, cap, F1 and PROOF checks on the content the patch would leave on disk. See [Codex](#codex). |

---

## Guard invariants

Every hook declares a `FAILURE DIRECTION` header; validates that stdin parses as a JSON object and
exits 2 when it does not; requires `jq`. `PreToolUse` denies with the
`hookSpecificOutput.permissionDecision: "deny"` shape; `Stop` denies with exit 2 and stderr. Exit 2
is the only code Claude Code treats as BLOCK — any other non-zero is a non-blocking error and the
tool proceeds — so a guard that cannot evaluate its input exits 2, never 1.

`scripts/check-shell-safety.sh` (adopted from `vision-to-plan`) enforces this mechanically: every
script declares `# SO-ROLE:`, every guard carries its failure direction, its fail-closed input
validation and an `exit 2`, every `.sh` must pass `bash -n`, and the `| grep -q` shape that fails
open under `pipefail` is banned outright.

---

## Tests

```bash
tests/run.sh --gate        # red-first, then the real run, then the shell-safety census
tests/run.sh               # every fixture against the real hooks
tests/run.sh --red-first   # every fixture must FAIL with its guard stubbed out
```

Every rule has a must-deny and a must-allow fixture. `--red-first` replaces the guard under test
with an inverted stub (allow-all for a fixture that expects a refusal, deny-all for one that expects
a permission) and requires every fixture to fail: a fixture that still passes without its guard
never observed the guard and proves nothing. Its bound, stated plainly: it proves no fixture is
vacuous, not that a fixture depends on one specific clause inside a guard.

The runner is three-state — pass / fail / nothing-ran — so an empty suite can never go green. The
suite runs in GitHub Actions on every push and weekly. It never runs in a commit or push hook: a
commit is a save and a push is a backup, and neither is gated by tests.

---

## Codex

session-objective runs on Codex CLI as well as Claude Code, and enforces the same three rules
there. Install the plugin from the same marketplace manifest:

```bash
codex plugin marketplace add macollins27/session-objective
codex plugin add session-objective@session-objective
```

Or wire it per project, which is the form the acceptance runs used — a `.codex/hooks.json` in the
project root, in the same CamelCase schema, with `command` pointing at each script under
`scripts/`.

### The one real difference, and how the guard closes it

Codex exposes no `Write` tool. Its only file-writing tool is `apply_patch`, whose `tool_input` is a
single `command` string holding a patch:

```json
{"tool_name": "apply_patch",
 "tool_input": {"command": "*** Begin Patch\n*** Update File: /path/objective.md\n@@\n-old\n+new\n*** End Patch"}}
```

There is no `tool_input.file_path` and no `tool_input.content`. The target path is in the patch
text, on the `*** Add File: `, `*** Update File: `, `*** Delete File: ` and `*** Move to: ` lines,
so Rule 1's guard reads it there. A patch that reaches the objective home is allowed only when it
carries **exactly one** file operation, on **exactly** this session's objective path, and that
operation is an Add or an Update — never a Delete, never a Move, never a second file riding along
in the same call. Bash stays denied, exactly as on Claude Code.

The content the patch would leave on disk is then put through the **same** Rule 2 diff, ledger
byte-identity check, F1 binding-advance check, word cap and trivial-PROOF check as a Claude `Write`.
An `Add File` hunk carries the whole file, so it is read straight out of the `+` lines. An
`Update File` hunk is a partial diff — the real patches measured here rewrite only the OBJECTIVE
layer and never mention the ledger — so it is applied to a **copy** using Codex's own parser
(`codex --codex-run-as-apply-patch`). Reconstructing it by hand would be a second parser that can
disagree with the one Codex will actually run, and a guard that checks content the runtime will not
write is a guard that fails open. If the applier is unavailable or the patch does not apply, the
call is denied; it is never allowed on a guess.

Two other Codex adaptations, both required for the rules to function rather than optional polish:

- **The instruction names the tool the runtime has.** Claude Code stamps `prompt_id` on its events
  and Codex stamps `turn_id`, so the injection and every deny say `Write, with file_path=…` on
  Claude Code and `apply_patch, carrying exactly one file operation, on exactly this path: …` on
  Codex. Telling a Codex session to use `Write` would be an instruction it cannot follow, and the
  lock would never release.
- **The Stop hook reads both transcript formats.** Claude Code writes one event per line with
  `.type` and `.message.content` blocks; Codex writes a rollout with `.payload.type`. Reading only
  one would leave the apology-that-ends-the-turn rule silently unenforced on the other.

Raw payload captures from both runtimes: [`docs/payload-evidence/`](docs/payload-evidence/).

## Related tools, not integrated

- `reanchor` (`~/.claude/skills/reanchor/SKILL.md`) — recovers a session that has already
  gone wrong, by rebuilding the objective from the transcript with a fresh subagent. This plugin is
  the standing version of the same idea: it keeps the objective rewritten every turn so the
  recovery is rarely needed.
- `orientation_sentinel` (`~/.claude/agents/orientation_sentinel.toml`) — a fresh-context sentinel that judges whether a proposed plan advances the
  operator's durable orientation. It judges alignment; this plugin holds the record the judgment
  would be made against.

Neither is called by this plugin and this plugin does not read their state.

---

MIT. Contributions: add the fixture first, watch it go red, then write the guard.
