#!/usr/bin/env bash
# tests/test_deploy_turn_wait.sh — parameterized integration test for the wait script.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"
export CW_DEPLOY_TURN_TIMEOUT=2  # short timeout for the timeout-path case

RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')

setup_topic() {
  local topic="$1"
  local td="$CLONE_WARS_HOME/state/$RH/$topic"
  mkdir -p "$td/_deploy" "$td/cody-codex"
  touch "$td/cody-codex/outbox.jsonl"
  printf 'OFFSET=0\n' > "$td/_deploy/turn-cody-1.txt"
  echo "$td"
}

# --- Case 1: done event + verify-report present → TS=ok ---
TD=$(setup_topic ok-fixture)
echo '{"event":"done","summary":"x","ts":"y"}' >> "$TD/cody-codex/outbox.jsonl"
echo "VERDICT: PASS" > "$TD/_deploy/verify-report-1.md"
../bin/deploy-turn-wait.sh ok-fixture 1 >/dev/null
grep -q '^TS=ok$' "$TD/_deploy/turn-cody-1.txt" \
  || { echo "FAIL: case 1 expected TS=ok" >&2; cat "$TD/_deploy/turn-cody-1.txt"; exit 1; }
[[ -f "$TD/_deploy/turn-cody-1.done" ]] \
  || { echo "FAIL: case 1 missing .done sentinel" >&2; exit 1; }
pass "wait writes TS=ok + sentinel on done event with verify-report present"

# --- Case 2: done event but verify-report missing → TS=failed ---
TD=$(setup_topic missing-verify)
echo '{"event":"done","summary":"x","ts":"y"}' >> "$TD/cody-codex/outbox.jsonl"
../bin/deploy-turn-wait.sh missing-verify 1 >/dev/null
grep -q '^TS=failed$' "$TD/_deploy/turn-cody-1.txt" \
  || { echo "FAIL: case 2 expected TS=failed" >&2; cat "$TD/_deploy/turn-cody-1.txt"; exit 1; }
pass "wait writes TS=failed when done but verify-report missing"

# --- Case 3: error event → TS=failed ---
TD=$(setup_topic err-fixture)
echo '{"event":"error","message":"boom","ts":"y"}' >> "$TD/cody-codex/outbox.jsonl"
echo "VERDICT: FAIL" > "$TD/_deploy/verify-report-1.md"
../bin/deploy-turn-wait.sh err-fixture 1 >/dev/null
grep -q '^TS=failed$' "$TD/_deploy/turn-cody-1.txt" \
  || { echo "FAIL: case 3 expected TS=failed" >&2; cat "$TD/_deploy/turn-cody-1.txt"; exit 1; }
pass "wait writes TS=failed on error event"

# --- Case 4: no event before timeout → TS=timeout ---
TD=$(setup_topic timeout-fixture)
# Empty outbox; CW_DEPLOY_TURN_TIMEOUT=2 means short wait.
../bin/deploy-turn-wait.sh timeout-fixture 1 >/dev/null
grep -q '^TS=timeout$' "$TD/_deploy/turn-cody-1.txt" \
  || { echo "FAIL: case 4 expected TS=timeout" >&2; cat "$TD/_deploy/turn-cody-1.txt"; exit 1; }
pass "wait writes TS=timeout when no event lands"

# --- Case 5: bad args ---
err=$(../bin/deploy-turn-wait.sh 2>&1) && rc=0 || rc=$?
[[ "$rc" -eq 2 ]] || { echo "FAIL: zero args should rc=2 (got $rc)" >&2; exit 1; }
pass "wait rc=2 on zero args"

err=$(../bin/deploy-turn-wait.sh some-topic 2>&1) && rc=0 || rc=$?
[[ "$rc" -eq 2 ]] || { echo "FAIL: missing round should rc=2 (got $rc)" >&2; exit 1; }
pass "wait rc=2 on missing round"

# --- Case 6: per-round state file (not the legacy plan-cody.txt) ---
TD=$(setup_topic per-round-fixture)
mv "$TD/_deploy/turn-cody-1.txt" "$TD/_deploy/turn-cody-3.txt"
echo '{"event":"done","summary":"x","ts":"y"}' >> "$TD/cody-codex/outbox.jsonl"
echo "VERDICT: PASS" > "$TD/_deploy/verify-report-3.md"
../bin/deploy-turn-wait.sh per-round-fixture 3 >/dev/null
grep -q '^TS=ok$' "$TD/_deploy/turn-cody-3.txt" \
  || { echo "FAIL: case 6 round=3 state file not updated" >&2; exit 1; }
[[ -f "$TD/_deploy/turn-cody-3.done" ]] \
  || { echo "FAIL: case 6 round=3 sentinel missing" >&2; exit 1; }
pass "wait honors per-round state file (round=3)"

echo "ALL: ok"
