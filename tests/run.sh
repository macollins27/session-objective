#!/usr/bin/env bash
# session-objective fixture runner.
#
# Three states, never two: pass / fail / NOTHING-RAN-WARN. An empty suite can never
# go green, because a suite that ran zero fixtures looks exactly like a suite that
# passed.
#
#   tests/run.sh              run every fixture against the real hooks; all must pass
#   tests/run.sh --red-first  run every fixture against an INVERTED stub and require
#                             each one to FAIL. A fixture that still passes when the
#                             guard is replaced by allow-all (or deny-all) is vacuous:
#                             it was never observing the rule. This is the mechanical
#                             form of "observed red before the rule is trusted".
#   tests/run.sh --gate       --red-first, then the real run, then check-shell-safety
#
# Bound, stated plainly: --red-first proves no fixture is vacuous. It replaces the
# whole guard, so it proves the fixture depends on the guard existing, not that it
# depends on one specific clause inside it.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TESTS_DIR/.." && pwd)"
FIXTURES="$TESTS_DIR/fixtures/fixtures.json"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required. brew install jq" >&2; exit 3; }
[ -f "$FIXTURES" ] || { echo "ERROR: no fixture file at $FIXTURES" >&2; exit 3; }

MODE="real"
case "${1:-}" in
  --red-first) MODE="red" ;;
  --gate) MODE="gate" ;;
  "") ;;
  *) echo "usage: run.sh [--red-first|--gate]" >&2; exit 3 ;;
esac

PASS=0; FAIL=0; RAN=0; SKIPPED=0
FAILED=()
SKIPS=()

# A fixture may declare a binary it cannot run without (the Codex patch applier).
# A skipped fixture is NEVER silently a pass: it is counted, named, and --gate refuses
# to go green unless the missing binary is declared in SO_ALLOW_MISSING.
missing_requirement() { # <fixture-json> -> prints the missing binary, or nothing
  local fx="$1" c
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    command -v "$c" >/dev/null 2>&1 || { printf '%s' "$c"; return 0; }
  done <<< "$(jq -r '(.requires // [])[]' <<< "$fx")"
  return 0
}

# ---------------------------------------------------------------------------
# Inverted stubs for the red-first pass.
# ---------------------------------------------------------------------------
make_stub() { # <stub-dir> <script-basename> <direction>
  local dir="$1" name="$2" dir_="$3"
  mkdir -p "$dir"
  case "$dir_" in
    allow) cat > "$dir/$name" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null 2>&1 || true
exit 0
EOF
      ;;
    deny) cat > "$dir/$name" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null 2>&1 || true
printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"inverted stub"}}'
printf 'inverted stub\n' >&2
exit 2
EOF
      ;;
  esac
  chmod +x "$dir/$name"
}

run_one() { # <fixture-json> <inverted?>
  local fx="$1" inverted="$2"
  local id script expect want_rc
  id="$(jq -r '.id' <<< "$fx")"
  script="$(jq -r '.script' <<< "$fx")"
  expect="$(jq -r '.expect' <<< "$fx")"

  local tmp home cwd file key sid aid transcript
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/so-fx.XXXXXX")"
  home="$tmp/home"; cwd="$tmp/cwd"; mkdir -p "$home" "$cwd"

  sid="$(jq -r '.session_id // "sess-1"' <<< "$fx")"
  aid="$(jq -r '.agent_id // ""' <<< "$fx")"
  key="$sid"; [ -n "$aid" ] && key="$sid/$aid"
  file="$home/sessions/$key/objective.md"
  transcript="$tmp/transcript.jsonl"

  # Placeholders are substituted in the seeded FILES too, not only in the payload —
  # without this a fixture whose objective names @CWD@ writes the literal token, the
  # proof command points at a path that cannot exist, and the fixture passes for the
  # wrong reason.
  sub() { sed -e "s#@HOME@#$home#g" -e "s#@FILE@#$file#g" -e "s#@CWD@#$cwd#g" -e "s#@TRANSCRIPT@#$transcript#g"; }
  if jq -e 'has("file")' >/dev/null <<< "$fx"; then
    mkdir -p "$(dirname "$file")"
    jq -r '.file[]' <<< "$fx" | sub > "$file"
  fi
  if jq -e 'has("parent_file")' >/dev/null <<< "$fx"; then
    mkdir -p "$home/sessions/$sid"
    jq -r '.parent_file[]' <<< "$fx" | sub > "$home/sessions/$sid/objective.md"
  fi
  if jq -e 'has("transcript")' >/dev/null <<< "$fx"; then
    jq -r '.transcript[]' <<< "$fx" > "$transcript"
  fi
  if jq -e 'has("seed_files")' >/dev/null <<< "$fx"; then
    while IFS= read -r rel; do [ -n "$rel" ] || continue; : > "$cwd/$rel"; done <<< "$(jq -r '.seed_files[]' <<< "$fx")"
  fi

  jq -e 'has("payload")' >/dev/null <<< "$fx" || { rm -rf "$tmp"; printf 'fail\tfixture has no payload'; return 0; }
  local payload
  payload="$(jq -c '.payload' <<< "$fx" \
    | sed -e "s#@HOME@#$home#g" -e "s#@FILE@#$file#g" -e "s#@CWD@#$cwd#g" -e "s#@TRANSCRIPT@#$transcript#g")"

  local bin="$ROOT/scripts"
  if [ "$inverted" = "1" ]; then
    local sd="$tmp/stub"
    mkdir -p "$sd/lib"; cp "$ROOT/scripts/lib/objective-lib.sh" "$sd/lib/"
    cp "$ROOT/scripts"/*.sh "$sd/" 2>/dev/null || true
    # A fixture that expects the hook to PERMIT something is inverted with a deny
    # stub; one that expects a refusal is inverted with an allow-all stub. Using the
    # allow stub for both would make every permit-fixture pass trivially — which is
    # the vacuous-check defect this pass exists to find.
    local dir_="allow"
    case "$expect" in allow|ok) dir_="deny" ;; esac
    make_stub "$sd" "$script" "$dir_"
    bin="$sd"
  fi

  # F14 — a fixture may pre-seed the session's state files (the stop-denial counter).
  if jq -e 'has("state_files")' >/dev/null <<< "$fx"; then
    mkdir -p "$(dirname "$file")"
    while IFS=$'\t' read -r name val; do
      [ -n "$name" ] || continue
      printf '%s' "$val" > "$(dirname "$file")/$name"
    done <<< "$(jq -r '.state_files | to_entries[] | "\(.key)\t\(.value)"' <<< "$fx")"
  fi

  # F13 — a fixture may hide a command (jq) by running against a PATH that contains
  # symlinks to everything the hook needs EXCEPT the hidden ones. A shim that exists
  # but fails would still satisfy `command -v`, so hiding has to be real.
  local pathovr=""
  if jq -e 'has("hide")' >/dev/null <<< "$fx"; then
    local bindir="$tmp/bin"; mkdir -p "$bindir"
    local hidden; hidden="$(jq -r '.hide | join(" ")' <<< "$fx")"
    for c in bash sh env cat dirname basename date mktemp grep sed awk tr wc find readlink rm mkdir mv cp head tail sleep kill timeout jq python3 test true false; do
      case " $hidden " in *" $c "*) continue ;; esac
      local src; src="$(command -v "$c" 2>/dev/null || true)"
      [ -n "$src" ] && ln -sf "$src" "$bindir/$c"
    done
    pathovr="$bindir"
  fi

  local out err rc
  out="$(mktemp "$tmp/out.XXXX")"; err="$(mktemp "$tmp/err.XXXX")"
  local envargs=()
  while IFS= read -r kv; do [ -n "$kv" ] || continue; envargs+=("$kv"); done \
    <<< "$(jq -r '(.env // {}) | to_entries[] | "\(.key)=\(.value)"' <<< "$fx")"
  local args=()
  while IFS= read -r a; do [ -n "$a" ] || continue; args+=("$a"); done \
    <<< "$(jq -r '(.args // [])[]' <<< "$fx" | sed -e "s#@HOME@#$home#g" -e "s#@FILE@#$file#g")"

  if [ -n "$pathovr" ]; then envargs+=("PATH=$pathovr"); fi
  printf '%s' "$payload" | env SESSION_OBJECTIVE_HOME="$home" "${envargs[@]+"${envargs[@]}"}" \
    bash "$bin/$script" "${args[@]+"${args[@]}"}" >"$out" 2>"$err"
  rc=$?

  local body verdict="pass" why=""
  body="$(cat "$out" "$err" 2>/dev/null)"

  case "$expect" in
    deny)
      if [ "$rc" != "0" ]; then verdict="fail"; why="expected exit 0 with a deny payload, got rc=$rc"
      elif ! jq -e 'select(.hookSpecificOutput.permissionDecision == "deny")' >/dev/null 2>&1 < "$out"; then
        verdict="fail"; why="no hookSpecificOutput.permissionDecision=deny on stdout"
      fi ;;
    allow)
      if [ "$rc" != "0" ]; then verdict="fail"; why="expected exit 0 (allow), got rc=$rc"
      elif jq -e 'select(.hookSpecificOutput.permissionDecision == "deny")' >/dev/null 2>&1 < "$out"; then
        verdict="fail"; why="unexpected deny payload on stdout"
      fi ;;
    block)  [ "$rc" = "2" ] || { verdict="fail"; why="expected exit 2 (block), got rc=$rc"; } ;;
    ok)     [ "$rc" = "0" ] || { verdict="fail"; why="expected exit 0, got rc=$rc"; } ;;
    fatal)  [ "$rc" = "2" ] || { verdict="fail"; why="expected exit 2 (cannot evaluate), got rc=$rc"; } ;;
    fail_1) [ "$rc" = "1" ] || { verdict="fail"; why="expected exit 1, got rc=$rc"; } ;;
    *) verdict="fail"; why="unknown expect '$expect'" ;;
  esac

  if [ "$verdict" = "pass" ] && jq -e 'has("expect_contains")' >/dev/null <<< "$fx"; then
    while IFS= read -r needle; do
      [ -n "$needle" ] || continue
      needle="$(printf '%s' "$needle" | sed -e "s#@HOME@#$home#g" -e "s#@FILE@#$file#g" -e "s#@CWD@#$cwd#g")"
      grep -qF -- "$needle" <<< "$body" || { verdict="fail"; why="output does not contain: $needle"; break; }
    done <<< "$(jq -r '.expect_contains[]' <<< "$fx")"
  fi
  if [ "$verdict" = "pass" ] && jq -e 'has("expect_absent")' >/dev/null <<< "$fx"; then
    while IFS= read -r needle; do
      [ -n "$needle" ] || continue
      grep -qF -- "$needle" <<< "$body" && { verdict="fail"; why="output unexpectedly contains: $needle"; break; }
    done <<< "$(jq -r '.expect_absent[]' <<< "$fx")"
  fi
  # D2 — a size claim needs a size assertion, not a substring one.
  if [ "$verdict" = "pass" ] && jq -e 'has("expect_max_chars")' >/dev/null <<< "$fx"; then
    local cap n
    cap="$(jq -r '.expect_max_chars' <<< "$fx")"
    n="$(wc -c < "$out" | tr -d ' ')"
    [ "$n" -le "$cap" ] || { verdict="fail"; why="output is $n characters, over the $cap cap"; }
  fi
  if [ "$verdict" = "pass" ] && jq -e 'has("expect_file_contains")' >/dev/null <<< "$fx"; then
    while IFS= read -r needle; do
      [ -n "$needle" ] || continue
      grep -qF -- "$needle" "$file" 2>/dev/null || { verdict="fail"; why="objective file does not contain: $needle"; break; }
    done <<< "$(jq -r '.expect_file_contains[]' <<< "$fx")"
  fi
  if [ "$verdict" = "pass" ] && jq -e 'has("expect_file_absent")' >/dev/null <<< "$fx"; then
    while IFS= read -r needle; do
      [ -n "$needle" ] || continue
      grep -qF -- "$needle" "$file" 2>/dev/null && { verdict="fail"; why="objective file unexpectedly contains: $needle"; break; }
    done <<< "$(jq -r '.expect_file_absent[]' <<< "$fx")"
  fi

  rm -rf "$tmp"
  if [ "$verdict" = "pass" ]; then printf 'pass'; else printf 'fail\t%s' "$why"; fi
}

N="$(jq '.fixtures | length' "$FIXTURES")"
if [ "$N" = "0" ] || [ -z "$N" ]; then
  echo "WARN: the fixture file lists zero fixtures. Nothing ran. An empty suite is not a pass." >&2
  exit 3
fi

do_pass() { # <inverted?> <label>
  local inverted="$1" label="$2" i fx id res
  printf '\n=== %s (%s fixtures) ===\n' "$label" "$N"
  for ((i = 0; i < N; i++)); do
    fx="$(jq -c ".fixtures[$i]" "$FIXTURES")"
    id="$(jq -r '.id' <<< "$fx")"
    need="$(missing_requirement "$fx")"
    if [ -n "$need" ]; then
      SKIPPED=$((SKIPPED + 1)); SKIPS+=("$id (needs $need)")
      printf '  SKIP  %s — needs %s, which is not on PATH\n' "$id" "$need"
      continue
    fi
    res="$(run_one "$fx" "$inverted")"
    RAN=$((RAN + 1))
    if [ "$inverted" = "0" ]; then
      if [ "${res%%$'\t'*}" = "pass" ]; then PASS=$((PASS + 1)); printf '  PASS  %s\n' "$id"
      else FAIL=$((FAIL + 1)); FAILED+=("$id: ${res#*$'\t'}"); printf '  FAIL  %s  — %s\n' "$id" "${res#*$'\t'}"; fi
    else
      # Inverted: the fixture MUST fail. A fixture that passes against a stubbed-out
      # guard never observed the guard at all.
      if [ "${res%%$'\t'*}" = "fail" ]; then PASS=$((PASS + 1)); printf '  RED   %s  (fails without the guard, as it must)\n' "$id"
      else FAIL=$((FAIL + 1)); FAILED+=("$id: VACUOUS — passes with the guard replaced by a stub"); printf '  VACUOUS %s — passes with the guard stubbed out; it proves nothing\n' "$id"; fi
    fi
  done
}

case "$MODE" in
  red)  do_pass 1 "RED-FIRST: every fixture must fail with its guard stubbed out" ;;
  real) do_pass 0 "REAL: every fixture must pass against the real hooks" ;;
  gate)
    do_pass 1 "RED-FIRST: every fixture must fail with its guard stubbed out"
    do_pass 0 "REAL: every fixture must pass against the real hooks"
    printf '\n=== install-codex.sh red-first ===\n'
    if bash "$ROOT/tests/test-install-codex.sh"; then RAN=$((RAN + 1)); PASS=$((PASS + 1)); else RAN=$((RAN + 1)); FAIL=$((FAIL + 1)); FAILED+=("test-install-codex.sh (install-codex.sh)"); fi
    printf '\n=== shell safety census ===\n'
    if ! "$ROOT/scripts/check-shell-safety.sh" "$ROOT"; then FAIL=$((FAIL + 1)); FAILED+=("check-shell-safety.sh"); fi
    ;;
esac

printf '\n========================================\n'
printf '  %d passed, %d failed, %d skipped  (%d fixture runs)\n' "$PASS" "$FAIL" "$SKIPPED" "$RAN"
printf '========================================\n'
if [ "$SKIPPED" -gt 0 ]; then
  printf 'SKIPPED (a skipped fixture proves nothing):\n'
  for sk in "${SKIPS[@]}"; do printf '  - %s\n' "$sk"; done
  for sk in "${SKIPS[@]}"; do
    b="${sk##*needs }"; b="${b%)}"
    case " ${SO_ALLOW_MISSING:-} " in
      *" $b "*) ;;
      *) printf 'Set SO_ALLOW_MISSING="%s" to accept these skips, or install it.\n' "$b"
         [ "$MODE" = "gate" ] && { FAIL=$((FAIL + 1)); FAILED+=("skipped: $sk"); } ;;
    esac
  done
fi
if [ "$RAN" = "0" ]; then echo "WARN: nothing ran." >&2; exit 3; fi
if [ "$FAIL" -gt 0 ]; then
  printf 'Failures:\n'; for f in "${FAILED[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
exit 0
