#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

grep -q 'cw_execute_design_build_verify_prompt' ../bin/execute-design-verify-send.sh \
  || { echo "FAIL: missing verify-prompt builder" >&2; exit 1; }
grep -q 'verify-cody-' ../bin/execute-design-verify-send.sh \
  || { echo "FAIL: missing per-round filename" >&2; exit 1; }
grep -q 'verify-report-' ../bin/execute-design-verify-send.sh \
  || { echo "FAIL: missing report filename" >&2; exit 1; }
grep -q 'test-output-' ../bin/execute-design-verify-send.sh \
  || { echo "FAIL: missing test-output filename" >&2; exit 1; }
pass "verify-send static wiring"

RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
TOPIC=ver-send-fixture
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
mkdir -p "$TD/_execute" "$TD/cody-codex"
echo "design body" > "$TD/_execute/design.md"
touch "$TD/cody-codex/outbox.jsonl"
printf '{"pane_id":"%%77","spawned_at":"x"}\n' > "$TD/cody-codex/pane.json"

# Round must be a positive integer.
err=$(../bin/execute-design-verify-send.sh "$TOPIC" 0 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: round=0 accepted" >&2; exit 1; }
err=$(../bin/execute-design-verify-send.sh "$TOPIC" abc 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: round=abc accepted" >&2; exit 1; }
pass "verify-send rejects bad round"

# Idempotency for the same round.
echo "OFFSET=0" > "$TD/_execute/verify-cody-1.txt"
err=$(../bin/execute-design-verify-send.sh "$TOPIC" 1 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && echo "$err" | grep -q 'already exists' \
  || { echo "FAIL: same-round idempotency: rc=$rc out=$err" >&2; exit 1; }
pass "verify-send same-round idempotency"
