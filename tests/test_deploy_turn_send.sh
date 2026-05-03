#!/usr/bin/env bash
# tests/test_deploy_turn_send.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

# Static wiring: sources lib, builds round-1 prompt, writes OFFSET, calls send.sh.
grep -q 'source.*lib/deploy.sh' ../bin/deploy-turn-send.sh \
  || { echo "FAIL: missing lib source" >&2; exit 1; }
grep -q 'cw_deploy_assert_topic' ../bin/deploy-turn-send.sh \
  || { echo "FAIL: missing topic assert" >&2; exit 1; }
grep -q 'cw_deploy_build_turn_prompt_round1' ../bin/deploy-turn-send.sh \
  || { echo "FAIL: missing round-1 prompt builder" >&2; exit 1; }
grep -q 'cw_deploy_build_turn_prompt_fix' ../bin/deploy-turn-send.sh \
  || { echo "FAIL: missing fix prompt builder" >&2; exit 1; }
grep -q 'wc -c' ../bin/deploy-turn-send.sh \
  || { echo "FAIL: missing wc -c offset capture" >&2; exit 1; }
grep -q 'OFFSET=' ../bin/deploy-turn-send.sh \
  || { echo "FAIL: missing OFFSET= write" >&2; exit 1; }
grep -q 'turn-cody-' ../bin/deploy-turn-send.sh \
  || { echo "FAIL: missing turn-cody-N state file ref" >&2; exit 1; }
pass "deploy-turn-send static wiring"

# Build a fake topic dir + cody trooper outbox.
RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
TOPIC=turn-send-fixture
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
mkdir -p "$TD/_deploy" "$TD/cody-codex"
echo "fake design body" > "$TD/_deploy/design.md"
touch "$TD/cody-codex/outbox.jsonl"
printf '{"pane_id":"%%99","spawned_at":"x"}\n' > "$TD/cody-codex/pane.json"
printf '{"state":"idle","updated":"x","last_event":"ready"}\n' > "$TD/cody-codex/status.json"

# Bad arg counts rejected.
err=$(../bin/deploy-turn-send.sh 2>&1) && rc=0 || rc=$?
[[ "$rc" -eq 2 ]] || { echo "FAIL: zero args should rc=2 (got $rc)" >&2; exit 1; }
pass "deploy-turn-send rc=2 on zero args"

err=$(../bin/deploy-turn-send.sh "$TOPIC" 2>&1) && rc=0 || rc=$?
[[ "$rc" -eq 2 ]] || { echo "FAIL: missing round arg should rc=2 (got $rc)" >&2; exit 1; }
pass "deploy-turn-send rc=2 on missing round"

err=$(../bin/deploy-turn-send.sh "$TOPIC" "abc" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: non-numeric round should rc!=0" >&2; exit 1; }
echo "$err" | grep -qi 'round\|numeric' \
  || { echo "FAIL: non-numeric round error message unclear: $err" >&2; exit 1; }
pass "deploy-turn-send rejects non-numeric round"

# Bad topic rejected.
err=$(../bin/deploy-turn-send.sh "../bad" 1 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: bad topic should rc!=0" >&2; exit 1; }
pass "deploy-turn-send rejects bad topic"

# Round-1 idempotency-fail-loud: pre-populate state file.
echo "OFFSET=0" > "$TD/_deploy/turn-cody-1.txt"
err=$(../bin/deploy-turn-send.sh "$TOPIC" 1 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && echo "$err" | grep -q 'already exists' \
  || { echo "FAIL: should refuse with existing state file. rc=$rc out=$err" >&2; exit 1; }
pass "deploy-turn-send fails loud on existing state file"
rm -f "$TD/_deploy/turn-cody-1.txt"

# Round >=2 missing fix-prompt rejected.
err=$(../bin/deploy-turn-send.sh "$TOPIC" 2 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && echo "$err" | grep -qi 'fix-prompt\|fix bundle\|not found' \
  || { echo "FAIL: round>=2 should require fix-prompt-N.md. rc=$rc out=$err" >&2; exit 1; }
pass "deploy-turn-send round>=2 requires fix-prompt-N.md"

# Trooper-not-idle rejected.
printf '{"state":"working","updated":"x","last_event":"ack"}\n' > "$TD/cody-codex/status.json"
err=$(../bin/deploy-turn-send.sh "$TOPIC" 1 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && echo "$err" | grep -qi 'not idle\|in flight\|busy' \
  || { echo "FAIL: not-idle status should be refused. rc=$rc out=$err" >&2; exit 1; }
pass "deploy-turn-send refuses when trooper not idle"

echo "ALL: ok"
