#!/usr/bin/env bash
# tests/test_outbox_path_in.sh — v0.47.0 finding #5-partial
# Locks: cw_outbox_path_in(topic_dir, commander, model) returns
# "<topic_dir>/<commander>-<model>/outbox.jsonl". Sibling of cw_outbox_path
# that takes the dir directly (no state-root reconstruction).
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"

# Case 1: basic path
out=$(cw_outbox_path_in "/tmp/topic" rex codex)
assert_eq "$out" "/tmp/topic/rex-codex/outbox.jsonl" "basic path"
pass "1. basic path"

# Case 2: gemini model (hyphen-free)
out=$(cw_outbox_path_in "/tmp/topic" wolffe gemini)
assert_eq "$out" "/tmp/topic/wolffe-gemini/outbox.jsonl" "gemini variant"
pass "2. different model variant"

# Case 3: parity with cw_outbox_path for canonical inputs
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
export CLONE_WARS_HOME="$SANDBOX"
TOPIC="deep-research-foo"
canonical_topic_dir=$(cw_topic_state_dir "$TOPIC")
canonical_outbox=$(cw_outbox_path rex codex "$TOPIC")
explicit_outbox=$(cw_outbox_path_in "$canonical_topic_dir" rex codex)
assert_eq "$explicit_outbox" "$canonical_outbox" "parity with cw_outbox_path"
pass "3. parity with cw_outbox_path for canonical inputs"

echo "test_outbox_path_in: 3 cases passed"
