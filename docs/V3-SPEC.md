# session-objective 3.0 — checkpoints, not instructions

Status: approved by the operator 2026-09-13. This document is the authority for the 3.0 build.
Anything on disk (2.1.0 code, fixtures, README, older specs) is a parts bin, never a reason to
deviate from this document. Where this document is silent, the 2.x behaviour stands.

## 1. Why 3.0 exists (measured 2026-09-13, 57 objective files, 100+ agents)

- 23 of 57 sessions ended with STATUS still ACTIVE: the stop gate refused three times, the
  budget ran out, and the agent was let go. The apology exit was delayed, not prevented.
- 60 transcripts carry stop refusals; the work still did not move.
- 11 files have an empty CURRENT REALITY; sampled ACTIVE-ended files have a blank PROGRESS
  layer. Per-turn PROGRESS rewriting produced nothing the agent would not have produced anyway,
  because it is written by the same drifting context it is meant to correct.
- The operator's observation, rank-1: the OBJECTIVE is translated well and then ignored. It is
  prose, and on this machine only mechanisms that refuse have ever changed agent behaviour.
- The one part that held is the one part a machine checks: 187 of 206 proof lines are
  non-trivial because the stop gate re-runs them.

Conclusion: text that describes what the agent should do is advice. 3.0 replaces advice with
checkpoints: an ordered set of exit conditions the hooks refuse to let the agent pass without
proof, and locks that make the order physical.

## 2. What stays from 2.x (unchanged unless named below)

- One file per session under `$SESSION_OBJECTIVE_HOME/sessions/<session_id>[/<agent_id>]/objective.md`.
- OPERATOR LEDGER: hook-written, verbatim, append-only; notifications never enter it; the agent
  can change no byte of it (write gate, byte identity).
- OBJECTIVE: written only by the fresh empty-context interpreter from the ledger alone; the
  validator; retry once; the `[kept by hook]` fallback; KIND task | conversation; Rule 2 no-drop.
- Proof forms: `PROOF: <command> => exit <code>` (re-run, 60s, destructive denylist, trivial
  classifier, substitutions stripped) and `PROOF: reply contains "<phrase>"` (>= 12 chars).
- Stop gate: WAITING needs a live launch; NEEDS-DECISION needs the question in the final message;
  the zero-tool-call-after-operator-message rule; the 3-denial budget per operator message;
  conversation KIND relaxes ACTIVE and the zero-tool-call rule; `stop_hook_active` honoured.
- SessionStart re-injection; SubagentStart seeding; `SESSION_OBJECTIVE=off`; 8,000-char injection
  cap; fail-closed conventions (`FAILURE DIRECTION` header, `SO-ROLE`, `FAIL-CLOSED INPUT
  VALIDATION`, exit 2 only blocks, `bash -n`, herestrings, red-first fixtures, the census).
- Codex: `apply_patch` parsing, `install-codex.sh`, writable root, the trust step.

## 3. The file, 3.0

```
# OPERATOR LEDGER (hook-written, append-only, agent may not edit)
- <ts>  <verbatim message>

# OBJECTIVE (interpreter-written from the ledger only; revision N, bound to ledger entry K; model M)
OUTCOME
...
KIND: task | conversation
MUST
...
MUST NOT
...
DONE WHEN
D1 ...
OPEN QUESTION
none

# WORKFLOW (interpreter-written with the objective; the fixed skeleton, filled for this task)
C1 UNDERSTAND — <exit condition, at most 40 words, specific to this task>
C2 BUILD — <exit condition>
C3 PROVE — every DONE WHEN item has a proof that reproduces
C4 VERIFY — a fresh-context verifier ran after the last change and returned PASS

# PROGRESS (agent-written)
CHECKPOINTS
C1 PROOF: <command> => exit <code>
C2 PROOF: ...
PROOFS
D1 PROOF: ...
IN FLIGHT
none
STATUS
ACTIVE
```

- For `KIND: conversation` the WORKFLOW body is exactly one line: `none (conversation)`.
- CURRENT REALITY and FRONTIER are removed. Nothing asks the agent to write them. The
  PROGRESS layer is written when a checkpoint is reached, when work is launched in the
  background, and when the status changes. Never "every turn".
- C3 and C4 lines are fixed text; the interpreter writes only C1 and C2. C3 has no PROOF line
  of its own: it is satisfied when every D-item proof reproduces. C4 has no PROOF line: it is
  satisfied from the transcript (section 5.4).

## 4. The interpreter, 3.0

- Same call shape, same isolation, same inputs (prompt + ledger + previous OBJECTIVE and
  WORKFLOW). It now emits both `# OBJECTIVE` and `# WORKFLOW` bodies in one call.
- C1 UNDERSTAND exit condition: what must have been OBSERVED about the current state before any
  change is made, stated as a fact a command can show (a file's current content, a test's
  current result, a page's current behaviour, the absence of the thing to be created).
- C2 BUILD exit condition: what must EXIST or have CHANGED, stated as a fact a command can
  show. Never how to do it, never a method, never doctrine.
- The validator (`objective-validate.sh`) additionally requires: the WORKFLOW heading, exactly
  the four lines C1..C4 in order with the fixed names, C3 and C4 byte-identical to the fixed
  text, C1 and C2 each 3..40 words after the dash, or the single `none (conversation)` line
  when KIND is conversation. Total document cap rises from 200 to 280 words.
- Fallback (`[kept by hook]`, interpreter failed twice): the WORKFLOW is the generic skeleton:
  C1 `the current state of everything the outcome touches has been observed`, C2 `the outcome
  exists as the objective describes it`. COMPLETE stays refused while binding K < N, as in 2.x.

## 5. Enforcement — every checkpoint is a refusal, not a sentence

### 5.1 Recording a checkpoint proof (write gate, at write time)
- The agent records `Cn PROOF: ...` by writing the PROGRESS layer (Write/Edit/apply_patch), as in
  2.x. The write gate validates the proposed file and, NEW: when the proposed file carries a
  `Cn PROOF` line that the current file does not, the gate runs that proof once, right then
  (same runner, bounds and classifier as the stop gate). A proof that is trivial, destructive,
  an unwitnessed negative-existence check, or does not reproduce → the write is DENIED with the
  proof's output in the reason. A checkpoint proof is therefore never on disk unless it passed.
- Order is physical: `C2 PROOF` may not appear unless `C1 PROOF` is already on disk (deny).
- A `Cn PROOF` line already on disk may not be changed or removed by the agent (deny: proofs
  are append-only within CHECKPOINTS). D-item proofs keep their 2.x rules.
- Negative-existence proofs (`test ! -e`, `! test -f`, `[ ! -e ]`, `! ls`) are allowed only when
  the tested path appears in the WORKFLOW text or in an earlier recorded proof line.

### 5.2 The edit lock (write gate, PreToolUse)
- While `KIND: task` and no `C1 PROOF` is on disk, every Write / Edit / MultiEdit /
  NotebookEdit / apply_patch whose target resolves under the session `cwd` is DENIED with the
  C1 exit condition and the exact recording instruction. Targets outside cwd (scratchpad, /tmp,
  the objective file itself) are unaffected. Bash is not covered by the lock and the header says
  so: the lock forces order for an agent that drifts, it is not a defence against one that
  evades, and the ledger/objective byte-identity rules of 2.x remain the defence there.
- Conversation KIND: no lock.

### 5.3 The stop gate
- ACTIVE (task): deny, bounded at 3 per operator message as before, but the refusal text is the
  CURRENT checkpoint (the first of C1, C2 without a proof on disk, else C3 if any D-item lacks a
  reproducing proof, else C4) with its exit condition and the one-line recording instruction.
  Never the FRONTIER text (removed).
- COMPLETE (task) is allowed only when: C1 and C2 proofs are on disk and reproduce now; every
  D-item proof reproduces now (2.x); the C4 transcript check passes (5.4); binding K == N.
- Everything else as 2.x.

### 5.4 C4 VERIFY — the fresh verifier, from the transcript
- Definition: in the session transcript, after the LAST product write (the last Write / Edit /
  MultiEdit / NotebookEdit / apply_patch tool_use whose target resolves under cwd), there is a
  later tool_use that is either an `Agent` / `Task` / `Workflow` call, or a shell call whose
  command contains `claude -p` or `codex exec`; and that tool_use's result text contains the
  whole word `PASS`.
- If there was never a product write in the transcript (the outcome was produced by Bash alone
  or outside cwd), the verifier call must exist after the operator's last message.
- Both transcript formats (Claude Code `.type/.message.content`, Codex `.payload.type`), as the
  2.x zero-tool-call check already does. Transcript unreadable or format unknown: this check
  alone fails OPEN with a visible line (the F12 exception), everything else stays fail-closed.
- Conversation KIND: not required.

### 5.5 Injection (UserPromptSubmit, SessionStart)
- Inject OBJECTIVE, WORKFLOW, then one derived line `CURRENT CHECKPOINT: Cn <NAME> — <exit>`,
  then STATUS, then the recording instruction for exactly that checkpoint. No request to keep
  anything "current". Under the 8,000-char cap; WORKFLOW is never truncated (truncate MUST lists
  first, with a visible marker, if it comes to that).

### 5.6 Migration of 2.x files
- On the first operator message a 3.0 hook sees for a file without a `# WORKFLOW` heading: the
  interpreter runs (it always does on a message) and produces the WORKFLOW; the PROGRESS layer is
  rewritten to the 3.0 template keeping every `Dn PROOF` line, IN FLIGHT and STATUS; the old
  CURRENT REALITY and FRONTIER text is archived beside the file as `progress-2x.<ts>.md`.
- The stop gate and write gate, meeting a 2.x file before any message arrives (a resumed
  session), treat it as `C1` current and apply 3.0 rules; they never crash on the old layout.

## 6. Subagents
- Seeded with the parent's OBJECTIVE and WORKFLOW, empty ledger, fresh PROGRESS. The edit lock
  applies to them (a builder records its C1 proof first). Their stop gate still exits 0 (F10); C4
  is a parent-level requirement only.

## 7. Failure scenarios that must have a fixture (red-first, both directions)
F1 write recording a C1 proof that does not reproduce → denied, nothing on disk.
F2 write recording C2 before C1 → denied.
F3 Edit to a file under cwd with no C1 on disk → denied; same Edit after C1 recorded → allowed.
F4 Write to scratchpad / outside cwd with no C1 → allowed.
F5 Conversation KIND: Edit under cwd allowed; Stop allowed on a reply alone.
F6 Stop on ACTIVE names the current checkpoint and its exit condition; C1 text when nothing is
   on disk, C2 after C1, C3 when a D-item lacks proof, C4 when only the verifier is missing.
F7 COMPLETE with C1, C2, D proofs reproducing but no verifier call after the last write → denied.
F8 COMPLETE with a verifier call before the last write → denied; after it, with PASS → allowed.
F9 COMPLETE with a verifier result lacking PASS → denied.
F10 Verifier check on an unreadable transcript → fails open with a visible line; all else closed.
F11 Interpreter output missing WORKFLOW, wrong names, C3/C4 text altered, C1 > 40 words → validator
    rejects; retry; fallback skeleton lands; COMPLETE refused while K < N.
F12 2.x file on resume: stop gate says C1; first message migrates, archives, keeps D proofs.
F13 Agent edits or removes an existing Cn PROOF line → denied.
F14 Negative-existence C1 proof naming a path in the WORKFLOW → allowed; naming a path nowhere →
    denied.
F15 Codex apply_patch recording a checkpoint → same rules, same denials.
F16 Subagent file: lock applies; its Stop exits 0.
F17 The whole 2.x suite still passes except fixtures that asserted CURRENT REALITY / FRONTIER,
    which are rewritten to 3.0, never deleted silently (each rewrite named in the commit body).

## 8. Acceptance (real use, not fixtures)
A1 Replay: for every ledger under `~/.session-objective/sessions` whose file ended ACTIVE (23),
   run the 3.0 interpreter on the ledger alone and validate; report validator pass count and
   paste five produced WORKFLOWs into `docs/acceptance/3.0-replay.md` for a human to read.
A2 Live: a real Claude Code session in a scratch repo with the 3.0 plugin installed, a small task
   requiring one file change. The transcript must show, in order: the first Edit denied by the
   lock; C1 recorded; the Edit allowed; a stop refused naming C3 or C4; a fresh verifier Agent
   call; COMPLETE allowed. Cite the transcript path and the line numbers of each event.
A3 Gate green (`bash tests/run.sh --gate`) at the exact commit; installed copy at that commit.

## 9. Versions
All four manifests → 3.0.0. README: replace the file layout, the "what the agent writes" section,
and the measured-in-real-use section with the 3.0 story and the numbers in section 1.
