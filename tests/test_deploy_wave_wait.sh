#!/usr/bin/env bash
# tests/test_deploy_wave_wait.sh
# Unit test for bin/deploy-wave-wait.sh — synthesize a fake outbox with
# a terminal event, verify the wait helper writes _deploy/wave-<cmdr>.txt
# with the correct TS= value + creates the .done sentinel.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
SANDBOX=$(mktemp -d)
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
export CLONE_WARS_HOME="$SANDBOX/.clone-wars"
mkdir -p "$CLONE_WARS_HOME"
trap 'rm -rf "$SANDBOX"' EXIT

source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deploy.sh"

# --- Test A: outbox emits {done} → TS=ok
TOPIC="dpl-wv-a-$$"
COMMANDER="rex"
PROVIDER="codex"
TOPIC_DIR="$CLONE_WARS_HOME/state/$(cw_repo_hash)/$TOPIC"
ART_DIR="$TOPIC_DIR/_deploy"
TROOPER_DIR="$TOPIC_DIR/$COMMANDER-$PROVIDER"
mkdir -p "$ART_DIR" "$TROOPER_DIR"

OUTBOX="$TROOPER_DIR/outbox.jsonl"
printf '{"event":"ready","ts":"2026-05-09T00:00:00Z"}\n' > "$OUTBOX"
printf '{"event":"done","summary":"all good","ts":"2026-05-09T00:00:01Z"}\n' >> "$OUTBOX"

CW_DEPLOY_WAVE_TIMEOUT_OVERRIDE=5 \
  "$PLUGIN_ROOT/bin/deploy-wave-wait.sh" "$TOPIC" "$COMMANDER" "$PROVIDER"

STATE="$ART_DIR/wave-$COMMANDER.txt"
DONE="$ART_DIR/wave-$COMMANDER.done"
assert_file_exists "$STATE" "wave-rex.txt written"
assert_file_exists "$DONE" "wave-rex.done sentinel written"
ts=$(grep '^TS=' "$STATE" | tail -1 | cut -d= -f2)
assert_eq "$ts" "ok" "TS=ok on done event"

rm -rf "$TOPIC_DIR"

# --- Test B: outbox emits {error} → TS=failed
TOPIC="dpl-wv-b-$$"
TOPIC_DIR="$CLONE_WARS_HOME/state/$(cw_repo_hash)/$TOPIC"
ART_DIR="$TOPIC_DIR/_deploy"
TROOPER_DIR="$TOPIC_DIR/$COMMANDER-$PROVIDER"
mkdir -p "$ART_DIR" "$TROOPER_DIR"
OUTBOX="$TROOPER_DIR/outbox.jsonl"
printf '{"event":"ready","ts":"2026-05-09T00:00:00Z"}\n' > "$OUTBOX"
printf '{"event":"error","reason":"plan failed","ts":"2026-05-09T00:00:01Z"}\n' >> "$OUTBOX"

CW_DEPLOY_WAVE_TIMEOUT_OVERRIDE=5 \
  "$PLUGIN_ROOT/bin/deploy-wave-wait.sh" "$TOPIC" "$COMMANDER" "$PROVIDER"

STATE="$ART_DIR/wave-$COMMANDER.txt"
assert_file_exists "$STATE" "Test B: wave-rex.txt written"
ts=$(grep '^TS=' "$STATE" | tail -1 | cut -d= -f2)
assert_eq "$ts" "failed" "TS=failed on error event"
reason=$(grep '^REASON=' "$STATE" | tail -1 | cut -d= -f2-)
[[ -n "$reason" ]] || { echo "FAIL: REASON= should be set on failed" >&2; exit 1; }

pass "deploy-wave-wait: TS=ok on done, TS=failed on error"
