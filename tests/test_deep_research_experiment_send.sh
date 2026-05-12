#!/usr/bin/env bash
# tests/test_deep_research_experiment_send.sh — prompt rendering + state file
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

TMPHOME=$(mktemp -d)
trap 'rm -rf "$TMPHOME"' EXIT
export CLONE_WARS_HOME="$TMPHOME"
echo "codex" > "$TMPHOME/providers-available.txt"

# Init a topic
slug=$("$PLUGIN_ROOT/bin/deep-research-init.sh" "optimize accuracy")
repo_hash=$(bash -c "PLUGIN_ROOT=$PLUGIN_ROOT; source $PLUGIN_ROOT/lib/state.sh; cw_repo_hash")
state_dir="$TMPHOME/state/$repo_hash/$slug"

# Stage round 1 branches.txt + trooper outbox (simulates spawn)
mkdir -p "$state_dir/_deep-research/round-1"
cat > "$state_dir/_deep-research/round-1/branches.txt" <<'EOF'
b1	rex	AIDE tree search	Depth-3 tree search with UCB1 selection
EOF

mkdir -p "$state_dir/rex-codex"
touch "$state_dir/rex-codex/outbox.jsonl"

# Run send in DRY_RUN
export CW_DEEP_RESEARCH_DRY_RUN=1
"$PLUGIN_ROOT/bin/deep-research-experiment-send.sh" "$slug" 1 rex b1 \
  || { echo "FAIL: DRY_RUN send rc=0" >&2; exit 1; }
pass "DRY_RUN send rc=0"

# Branch dir created
[[ -d "$state_dir/_deep-research/round-1-rex-b1/code" ]] \
  || { echo "FAIL: branch dir missing" >&2; exit 1; }
pass "branch dir round-1-rex-b1/code/ created"

# Prompt rendered with all placeholders
prompt_file="$state_dir/_deep-research/round-1-rex-b1/prompt.md"
[[ -f "$prompt_file" ]] || { echo "FAIL: prompt.md missing" >&2; exit 1; }
pass "prompt.md rendered"

grep -q "Approach label:  AIDE tree search" "$prompt_file" \
  || { echo "FAIL: label not substituted" >&2; cat "$prompt_file" | head -20 >&2; exit 1; }
pass "APPROACH_LABEL substituted"

grep -q "Approach brief:  Depth-3 tree search" "$prompt_file" \
  || { echo "FAIL: brief not substituted" >&2; exit 1; }
pass "APPROACH_BRIEF substituted"

grep -q "Branch ID:       b1" "$prompt_file" \
  || { echo "FAIL: branch_id not substituted" >&2; exit 1; }
pass "BRANCH_ID substituted"

grep -q "Metric: accuracy" "$prompt_file" \
  || { echo "FAIL: metric not substituted" >&2; exit 1; }
pass "METRIC substituted"

grep -q "Topic: optimize accuracy" "$prompt_file" \
  || { echo "FAIL: topic not substituted" >&2; exit 1; }
pass "TOPIC substituted"

# allow-net=false → NET_GUIDANCE has prohibition
grep -q "Do NOT fetch external resources" "$prompt_file" \
  || { echo "FAIL: net prohibition missing" >&2; exit 1; }
pass "NET_GUIDANCE prohibits fetch (default)"

# Per-branch timeout substituted
grep -q "Per-branch wall-clock budget: 300s" "$prompt_file" \
  || { echo "FAIL: timeout not substituted" >&2; exit 1; }
pass "TIME_BUDGET_S=300 substituted"

# State file at consult-shape path
state_file="$state_dir/_deep-research/experiment-rex.txt"
[[ -f "$state_file" ]] \
  || { echo "FAIL: state file missing at $state_file" >&2; exit 1; }
pass "state file at experiment-rex.txt (cw_consult_wait compatible)"

grep -q "^OFFSET=" "$state_file" \
  || { echo "FAIL: state file missing OFFSET" >&2; exit 1; }
pass "state file has OFFSET="

# Re-run with --allow-net → NET_GUIDANCE flips
slug2=$("$PLUGIN_ROOT/bin/deep-research-init.sh" --allow-net "topic with net")
state_dir2="$TMPHOME/state/$repo_hash/$slug2"
mkdir -p "$state_dir2/_deep-research/round-1"
cat > "$state_dir2/_deep-research/round-1/branches.txt" <<'EOF'
b1	rex	AIDE	depth-3 search
EOF
mkdir -p "$state_dir2/rex-codex"
touch "$state_dir2/rex-codex/outbox.jsonl"

"$PLUGIN_ROOT/bin/deep-research-experiment-send.sh" "$slug2" 1 rex b1
prompt_file2="$state_dir2/_deep-research/round-1-rex-b1/prompt.md"
grep -q "Net access is permitted" "$prompt_file2" \
  || { echo "FAIL: allow-net guidance not flipped" >&2; exit 1; }
pass "--allow-net flips NET_GUIDANCE"

# Refuses re-send when state file already exists
if "$PLUGIN_ROOT/bin/deep-research-experiment-send.sh" "$slug" 1 rex b1 2>/dev/null; then
  echo "FAIL: should refuse when state file exists" >&2; exit 1
fi
pass "refuses re-send with existing state file"

# Bad branch_id rejected
if "$PLUGIN_ROOT/bin/deep-research-experiment-send.sh" "$slug" 1 rex "INVALID" 2>/dev/null; then
  echo "FAIL: should reject uppercase branch_id" >&2; exit 1
fi
pass "rejects invalid branch_id format"

# Missing branches.txt row rejected
if "$PLUGIN_ROOT/bin/deep-research-experiment-send.sh" "$slug" 1 rex nonexistent 2>/dev/null; then
  echo "FAIL: should reject branch not in branches.txt" >&2; exit 1
fi
pass "rejects branch not in branches.txt"

echo "test_deep_research_experiment_send: 14 assertions green"
