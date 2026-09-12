# Payload evidence

Raw hook payloads captured live, by a throwaway plugin whose only hook writes stdin to disk.

- `*.json` — Claude Code 2.1.269, 2026-09-12. The four `*.<agent_id>.json` files are the events
  fired **inside** a dispatched subagent; note that each carries the parent's `session_id` and the
  subagent's own `agent_id`, and that no `Stop` event fires inside a subagent — `SubagentStop` does.
  This is what fixes the file key at `<session_id>/<agent_id>` for subagents.
- `codex/` — Codex CLI 0.154.0, same date, from a project-scoped `.codex/hooks.json`.
  `PreToolUse.apply_patch.json` is the whole Codex story: a file write arrives as one `command`
  string holding a patch, with no `file_path` and no `content`.
- `codex/S1b-codex-decisions.md`, `codex/S2-codex-decisions.md`, `codex/S3-codex-decisions.md` —
  every hook decision from three real `codex exec` sessions, recorded at the hook boundary by a
  transparent recorder that tees the payload, runs the real hook and re-emits its exact stdout,
  stderr and exit code. They show, in order: a shell command denied before the objective was
  written, the objective rewrite allowed through `apply_patch`, a zero-tool-call turn blocked at
  Stop, and a patch that dropped a CONSTRAINT denied with the line named.
- `codex/S8-codex-deadlocked-objective.md` — the before-picture, kept deliberately: the objective
  file a Codex session produced while Rule 1's only exception still named a `Write` tool Codex does
  not have. The ledger was appended and every tool was denied.

Home directories are placeholdered as `/Users/<user>` and the capture directory as `/tmp/probe`;
nothing else is altered.
