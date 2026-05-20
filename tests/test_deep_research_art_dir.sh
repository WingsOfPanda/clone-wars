#!/usr/bin/env bash
# tests/test_deep_research_art_dir.sh — v0.46.0 finding #4
# Locks: cw_deep_research_art_dir(topic) prints "<topic_state_dir>/_deep-research".
# Mirrors cw_meditate_art_dir / cw_deploy_art_dir.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
export CLONE_WARS_HOME="$SANDBOX"
HASH=$(cw_repo_hash)

# Case 1: basic topic
out=$(cw_deep_research_art_dir "deep-research-mnist")
expected="$SANDBOX/state/$HASH/deep-research-mnist/_deep-research"
assert_eq "$out" "$expected" "basic topic art-dir"
pass "1. basic topic prints art-dir under topic_state_dir"

# Case 2: topic that already has slashes (cw_topic_state_dir's printf %s keeps them)
out=$(cw_deep_research_art_dir "deep-research-foo-bar")
expected="$SANDBOX/state/$HASH/deep-research-foo-bar/_deep-research"
assert_eq "$out" "$expected" "kebab topic art-dir"
pass "2. kebab-shaped topic prints expected art-dir"

# Case 3: integration with cw_topic_state_dir
ts=$(cw_topic_state_dir "deep-research-x")
art=$(cw_deep_research_art_dir "deep-research-x")
assert_eq "$art" "$ts/_deep-research" "art-dir = topic-state-dir + /_deep-research"
pass "3. art-dir composes from cw_topic_state_dir + /_deep-research suffix"

echo "test_deep_research_art_dir: 3 cases passed"
