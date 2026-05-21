#!/usr/bin/env bash
# tests/test_trooper_ask_emits_event.sh — 3 cases for bin/trooper-ask.sh.
set -uo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Set up a minimal state-root layout matching what cw_outbox_path expects.
export CLONE_WARS_HOME="$TMP/.clone-wars"
mkdir -p "$CLONE_WARS_HOME/state"

# Pick a topic + commander; the outbox path resolves through cw_repo_hash
# which uses git rev-parse on the cwd. Run from the plugin root for stable
# hashing.
cd "$PLUGIN_ROOT"
TOPIC="test-trooper-ask-topic"
CMDR="cody"

# Pre-create the trooper dir so the append works (the protocol assumes
# spawn.sh has already done this in real runs).
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
OUTBOX=$(cw_outbox_path "$CMDR" codex "$TOPIC")
mkdir -p "$(dirname "$OUTBOX")"
: > "$OUTBOX"

# --- Case 1: with claim → outbox has 5 fields
bash "$PLUGIN_ROOT/bin/trooper-ask.sh" "$TOPIC" "$CMDR" "why-asking-text" path "/abs/foo"
assert_eq "$?" "0" "case1a: trooper-ask exit 0"
line=$(tail -n1 "$OUTBOX")
assert_contains "$line" '"event":"question"' "case1b: event=question"
assert_contains "$line" '"text":"why-asking-text"' "case1c: text field"
assert_contains "$line" '"claim":{"kind":"path","value":"/abs/foo"}' "case1d: claim object"
assert_contains "$line" '"ts":"' "case1e: ts field"

# --- Case 2: without claim → outbox lacks claim key
bash "$PLUGIN_ROOT/bin/trooper-ask.sh" "$TOPIC" "$CMDR" "opinion-question"
line=$(tail -n1 "$OUTBOX")
assert_contains "$line" '"event":"question"' "case2a: event=question"
assert_contains "$line" '"text":"opinion-question"' "case2b: text field"
if printf '%s' "$line" | grep -q '"claim":'; then
  printf 'FAIL case2c: claim key present in claimless event\n' >&2
  exit 1
fi
pass "case2c: no claim key"

# --- Case 3: invalid kind → rc=2, no outbox append
before=$(wc -l < "$OUTBOX")
bash "$PLUGIN_ROOT/bin/trooper-ask.sh" "$TOPIC" "$CMDR" "txt" path-xxx "/abs/foo" 2>/dev/null
assert_eq "$?" "2" "case3a: invalid kind → rc=2"
after=$(wc -l < "$OUTBOX")
assert_eq "$before" "$after" "case3b: outbox line count unchanged"

echo "test_trooper_ask_emits_event: 3 cases passed"
