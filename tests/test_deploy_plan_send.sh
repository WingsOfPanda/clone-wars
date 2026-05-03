#!/usr/bin/env bash
# tests/test_deploy_plan_send.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

# Static wiring: sources lib, builds plan prompt, captures OFFSET, calls send.sh.
grep -q 'source.*lib/deploy.sh' ../bin/deploy-plan-send.sh \
  || { echo "FAIL: missing lib source" >&2; exit 1; }
grep -q 'cw_deploy_assert_topic' ../bin/deploy-plan-send.sh \
  || { echo "FAIL: missing topic assert" >&2; exit 1; }
grep -q 'cw_deploy_build_plan_prompt' ../bin/deploy-plan-send.sh \
  || { echo "FAIL: missing plan-prompt builder" >&2; exit 1; }
grep -q 'wc -c' ../bin/deploy-plan-send.sh \
  || { echo "FAIL: missing wc -c offset capture" >&2; exit 1; }
grep -q 'OFFSET=' ../bin/deploy-plan-send.sh \
  || { echo "FAIL: missing OFFSET= write" >&2; exit 1; }
pass "plan-send static wiring"

# Build a fake topic dir + cody trooper outbox, exercise idempotency.
RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
TOPIC=plan-send-fixture
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
mkdir -p "$TD/_deploy" "$TD/cody-codex"
echo "fake design body" > "$TD/_deploy/design.md"
touch "$TD/cody-codex/outbox.jsonl"
printf '{"pane_id":"%%99","spawned_at":"x"}\n' > "$TD/cody-codex/pane.json"

# Pre-populate plan-cody.txt and assert second call refuses.
echo "OFFSET=0" > "$TD/_deploy/plan-cody.txt"
err=$(../bin/deploy-plan-send.sh "$TOPIC" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && echo "$err" | grep -q 'already exists' \
  || { echo "FAIL: should refuse with existing state file. rc=$rc out=$err" >&2; exit 1; }
pass "plan-send fails loud on existing state file"

# Bad topic rejected.
err=$(../bin/deploy-plan-send.sh "../bad" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: bad topic accepted" >&2; exit 1; }
pass "plan-send rejects bad topic"
