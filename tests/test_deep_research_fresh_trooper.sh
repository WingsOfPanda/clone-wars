#!/usr/bin/env bash
# v0.34.0 D1 — bin/deep-research-fresh-trooper.sh
# Locks: exists/executable + arg parsing + state preservation contract.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Case 1: exists + executable
assert_file_exists "$PLUGIN_ROOT/bin/deep-research-fresh-trooper.sh" \
  "case 1: bin/deep-research-fresh-trooper.sh missing"
[[ -x "$PLUGIN_ROOT/bin/deep-research-fresh-trooper.sh" ]] \
  || { echo "FAIL: case 1 script not executable"; exit 1; }
pass "1. script exists + executable"

# Case 2: bad topic → rc=2
rc=0
"$PLUGIN_ROOT/bin/deep-research-fresh-trooper.sh" 'BAD TOPIC!' rex 2>/dev/null || rc=$?
[[ "$rc" == 2 ]] \
  || { echo "FAIL: case 2 bad topic should rc=2 (got $rc)"; exit 1; }
pass "2. invalid topic → rc=2"

# Case 3: missing state.txt → rc=1
export CLONE_WARS_HOME="$TMP"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
TOPIC=deep-research-v034fresh
TOPIC_DIR="$(cw_topic_state_dir "$TOPIC")"
mkdir -p "$TOPIC_DIR/_deep-research/troopers"
rc=0
"$PLUGIN_ROOT/bin/deep-research-fresh-trooper.sh" "$TOPIC" rex 2>/dev/null || rc=$?
[[ "$rc" == 1 ]] \
  || { echo "FAIL: case 3 missing state.txt should rc=1 (got $rc)"; exit 1; }
pass "3. missing state.txt → rc=1"

# Case 4: phase=working → rc=1 (refuse mid-experiment reset)
mkdir -p "$TOPIC_DIR/_deep-research/troopers/rex/experiments/exp-001"
cat > "$TOPIC_DIR/_deep-research/troopers/rex/state.txt" <<EOF
phase=working
current_exp_id=exp-001
exp_counter=1
last_event_ts=
last_event=dispatched
probe_sent_ts=
EOF
rc=0
"$PLUGIN_ROOT/bin/deep-research-fresh-trooper.sh" "$TOPIC" rex 2>/dev/null || rc=$?
[[ "$rc" == 1 ]] \
  || { echo "FAIL: case 4 phase=working should rc=1 (got $rc)"; exit 1; }
grep -q 'phase=working' "$TOPIC_DIR/_deep-research/troopers/rex/state.txt" \
  || { echo "FAIL: case 4 state.txt mutated under refusal"; exit 1; }
pass "4. phase=working refused without mutating state.txt"

echo "test_deep_research_fresh_trooper: 4 cases passed"
