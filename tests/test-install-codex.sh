#!/usr/bin/env bash
# SO-ROLE: tool
# test-install-codex.sh — red-first proof for scripts/install-codex.sh, run by tests/run.sh --gate.
#
# Both directions are load-bearing:
#   must-REFUSE  a garbage ~/.codex/hooks.json  -> exit 2 and NOTHING written (hooks.json and
#                config.toml byte-identical afterwards, no backup files created)
#   must-ACCEPT  a valid home -> five hooks wired pointing at this checkout, writable root added,
#                and a SECOND run changes nothing (idempotent)
# The installer is exercised with HOME pointed at a temp dir, never at the real ~/.codex.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
INST="$ROOT/scripts/install-codex.sh"
fail() { printf 'install-codex TEST FAIL: %s\n' "$*" >&2; exit 1; }

# --- must-REFUSE ---------------------------------------------------------------
H="$(mktemp -d)"; mkdir -p "$H/.codex"
printf 'this is not json' > "$H/.codex/hooks.json"
printf '[sandbox_workspace_write]\nwritable_roots = []\n' > "$H/.codex/config.toml"
before_h="$(cat "$H/.codex/hooks.json")"; before_c="$(cat "$H/.codex/config.toml")"
set +e; HOME="$H" SESSION_OBJECTIVE_HOME="$H/.session-objective" bash "$INST" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" -eq 2 ] || fail "garbage hooks.json must exit 2, got $rc"
[ "$(cat "$H/.codex/hooks.json")" = "$before_h" ] || fail "garbage hooks.json was modified"
[ "$(cat "$H/.codex/config.toml")" = "$before_c" ] || fail "config.toml was modified on a refused run"
[ -z "$(ls "$H/.codex" | grep -E '\.bak\.' || true)" ] || fail "backup files were created on a refused run"

# --- must-ACCEPT + idempotent ---------------------------------------------------
H2="$(mktemp -d)"; mkdir -p "$H2/.codex"
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/bin/true"}]}]}}\n' > "$H2/.codex/hooks.json"
printf '[features]\nmemories = false\n' > "$H2/.codex/config.toml"
HOME="$H2" SESSION_OBJECTIVE_HOME="$H2/.session-objective" bash "$INST" >/dev/null 2>&1 || fail "valid install exited non-zero"
n="$(jq -r --arg r "$ROOT" '[.hooks[][]?.hooks[]?.command | select(startswith($r))] | length' "$H2/.codex/hooks.json")"
[ "$n" = "5" ] || fail "expected 5 hooks pointing at the checkout, found $n"
jq -e '.hooks.Stop | length == 2' "$H2/.codex/hooks.json" >/dev/null || fail "existing Stop hook was not preserved"
grep -Fq "writable_roots = [\"$H2/.session-objective\"]" "$H2/.codex/config.toml" || fail "writable root not added"
grep -Fq 'memories = false' "$H2/.codex/config.toml" || fail "existing config was not preserved"
snap_h="$(jq -S . "$H2/.codex/hooks.json")"; snap_c="$(cat "$H2/.codex/config.toml")"
HOME="$H2" SESSION_OBJECTIVE_HOME="$H2/.session-objective" bash "$INST" >/dev/null 2>&1 || fail "second run exited non-zero"
[ "$(jq -S . "$H2/.codex/hooks.json")" = "$snap_h" ] || fail "second run changed hooks.json (not idempotent)"
[ "$(cat "$H2/.codex/config.toml")" = "$snap_c" ] || fail "second run changed config.toml (not idempotent)"

rm -rf "$H" "$H2"
printf 'PASS: install-codex.sh refuses garbage (exit 2, nothing written) and installs idempotently\n'
