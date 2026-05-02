#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

grep -q 'source.*lib/execute_design.sh' ../bin/execute-design-implement-send.sh \
  || { echo "FAIL: missing lib source" >&2; exit 1; }
grep -q 'cw_execute_design_build_implement_prompt' ../bin/execute-design-implement-send.sh \
  || { echo "FAIL: missing implement-prompt builder" >&2; exit 1; }
grep -q 'OFFSET=' ../bin/execute-design-implement-send.sh \
  || { echo "FAIL: missing OFFSET= write" >&2; exit 1; }
pass "implement-send static wiring"

RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
TOPIC=impl-send-fixture
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
mkdir -p "$TD/_execute" "$TD/cody-codex"
echo "plan body" > "$TD/_execute/plan.md"
touch "$TD/cody-codex/outbox.jsonl"
printf '{"pane_id":"%%88","spawned_at":"x"}\n' > "$TD/cody-codex/pane.json"

# Refuses without plan.md present (plan-phase must have completed).
rm "$TD/_execute/plan.md"
err=$(../bin/execute-design-implement-send.sh "$TOPIC" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && echo "$err" | grep -q 'plan.md' \
  || { echo "FAIL: should refuse without plan.md; rc=$rc out=$err" >&2; exit 1; }
pass "implement-send refuses without plan.md"
echo "plan body" > "$TD/_execute/plan.md"

# Idempotency: pre-populate state file → refuse.
echo "OFFSET=0" > "$TD/_execute/implement-cody.txt"
err=$(../bin/execute-design-implement-send.sh "$TOPIC" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && echo "$err" | grep -q 'already exists' \
  || { echo "FAIL: idempotency: rc=$rc out=$err" >&2; exit 1; }
pass "implement-send idempotency"
