# Payload evidence

Raw hook payloads captured live, by a throwaway plugin whose only hook writes stdin to disk.

- `*.json` — Claude Code 2.1.269, 2026-09-12. The four `*.<agent_id>.json` files are the events
  fired **inside** a dispatched subagent; note that each carries the parent's `session_id` and the
  subagent's own `agent_id`, and that no `Stop` event fires inside a subagent — `SubagentStop` does.
  This is what fixes the file key at `<session_id>/<agent_id>` for subagents.
- `codex/` — Codex CLI 0.154.0, same date, from a project-scoped `.codex/hooks.json`.
  `PreToolUse.apply_patch.json` is the whole Codex story: a file write arrives as one `command`
  string holding a patch, with no `file_path` and no `content`.
- `codex/S8-codex-deadlocked-objective.md` — the objective file a real `codex exec` session produced
  while running these exact hooks: the ledger appended, the objective never written, because the
  `Write` tool Rule 1 requires does not exist in Codex.

Home directories are placeholdered as `/Users/<user>` and the capture directory as `/tmp/probe`;
nothing else is altered.
