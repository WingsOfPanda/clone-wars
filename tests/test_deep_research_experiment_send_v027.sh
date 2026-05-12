#!/usr/bin/env bash
# tests/test_deep_research_experiment_send_v027.sh — v0.27.0 contract
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
TMPHOME=$(mktemp -d); trap 'rm -rf "$TMPHOME"' EXIT
export CLONE_WARS_HOME="$TMPHOME"
echo "codex" > "$TMPHOME/providers-available.txt"

# Init a topic, then hand-write metric.md (simulating Phase 1 output)
slug=$("$PLUGIN_ROOT/bin/deep-research-init.sh" "MNIST accuracy")
source "$PLUGIN_ROOT/lib/state.sh"
REPO_HASH=$(cw_repo_hash)
state_dir="$TMPHOME/state/$REPO_HASH/$slug"
art_dir="$state_dir/_deep-research"

cat > "$art_dir/metric.md" <<'EOF'
# Research goal

**Primary metric:** accuracy
**Direction:** maximize
**Target (good):** >= 0.99

**Notes:** MNIST test set
EOF

# Fake-spawn rex (write minimal outbox)
mkdir -p "$state_dir/rex-codex"
touch "$state_dir/rex-codex/outbox.jsonl"

# Dispatch experiment exp-007 with DRY_RUN (no tmux nudge)
export CW_DEEP_RESEARCH_DRY_RUN=1
"$PLUGIN_ROOT/bin/deep-research-experiment-send.sh" \
  "$slug" rex exp-007 "Modern LeNet + weight decay" \
  "Same ~80k-param Modern LeNet, add weight decay 1e-4" \
  || { echo "FAIL: send rc!=0" >&2; exit 1; }
pass "DRY_RUN send rc=0"

# Branch dir: flat experiments/exp-NNN-<cmdr>/
branch_dir="$art_dir/experiments/exp-007-rex"
[[ -d "$branch_dir/code" ]] || { echo "FAIL: branch code/ dir missing" >&2; exit 1; }
pass "branch dir experiments/exp-007-rex/code/ created"

prompt_file="$branch_dir/prompt.md"
assert_file_exists "$prompt_file"
pass "prompt.md rendered"

# Verify rendered prompt content
prompt_body=$(<"$prompt_file")
assert_contains "$prompt_body" "Experiment ID:   exp-007" "EXP_ID interpolated"
assert_contains "$prompt_body" "Approach label:  Modern LeNet + weight decay" "APPROACH_LABEL interpolated"
assert_contains "$prompt_body" "Approach brief:  Same ~80k-param Modern LeNet" "APPROACH_BRIEF interpolated"
assert_contains "$prompt_body" "Topic: MNIST accuracy" "TOPIC interpolated"
assert_contains "$prompt_body" "**Primary metric:** accuracy" "metric.md body interpolated"
assert_contains "$prompt_body" "**Target (good):** >= 0.99" "metric.md target interpolated"
assert_contains "$prompt_body" "Net access: permitted" "allow-net default permitted (UX #5)"
[[ "$prompt_body" != *"cd"*"d into your branch dir"* ]] \
  || { echo "FAIL: BUG #3 not fixed; misleading cd claim still in prompt" >&2; exit 1; }
pass "BUG #3 fixed — no 'cd into your branch dir' claim"
[[ "$prompt_body" != *"{{"* ]] \
  || { echo "FAIL: unrendered {{...}} placeholder remains" >&2; exit 1; }
pass "all {{...}} placeholders interpolated"

# State file at consult-shape path
state_file="$art_dir/experiment-rex.txt"
assert_file_exists "$state_file"
grep -q "^OFFSET=" "$state_file" || { echo "FAIL: state file missing OFFSET=" >&2; exit 1; }
pass "state file at experiment-rex.txt (cw_consult_wait compatible)"

# Refuses re-send when state file already exists
if "$PLUGIN_ROOT/bin/deep-research-experiment-send.sh" \
     "$slug" rex exp-008 "another" "x" 2>/dev/null; then
  echo "FAIL: should refuse re-send while state file exists" >&2; exit 1
fi
pass "refuses re-send with existing state file"

# Rotate trooper (after a teardown the state file would be removed)
rm "$state_file"
"$PLUGIN_ROOT/bin/deep-research-experiment-send.sh" \
  "$slug" rex exp-008 "another" "x" \
  || { echo "FAIL: second send after state-file removal rc!=0" >&2; exit 1; }
[[ -d "$art_dir/experiments/exp-008-rex" ]] \
  || { echo "FAIL: exp-008 dir not created" >&2; exit 1; }
pass "after state-file rotation, exp-008 dispatches cleanly"

# Bad exp-id rejected
if "$PLUGIN_ROOT/bin/deep-research-experiment-send.sh" \
     "$slug" rex "INVALID" "x" "y" 2>/dev/null; then
  echo "FAIL: uppercase exp-id should be rejected" >&2; exit 1
fi
pass "uppercase exp-id rejected"

# Missing metric.md rejected
rm "$art_dir/metric.md"
if "$PLUGIN_ROOT/bin/deep-research-experiment-send.sh" \
     "$slug" rex exp-009 "x" "y" 2>/dev/null; then
  echo "FAIL: missing metric.md should be rejected" >&2; exit 1
fi
pass "missing metric.md rejected"

echo "test_deep_research_experiment_send_v027: 12 assertions green"
