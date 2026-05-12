#!/usr/bin/env bash
# tests/test_deep_research_e2e.sh — DRY_RUN end-to-end: init + branches.txt + 2 mock branches + score + teardown
# Tmux-dependent steps (real spawn/wait) NOT exercised — bin scripts wired
# correctly + scoreboard contract + archive shape are exercised.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

TMPHOME=$(mktemp -d)
trap 'rm -rf "$TMPHOME"' EXIT
export CLONE_WARS_HOME="$TMPHOME"
echo "codex" > "$TMPHOME/providers-available.txt"

# Phase 1: init
slug=$("$PLUGIN_ROOT/bin/deep-research-init.sh" "optimize accuracy under 100k params")
[[ -n "$slug" ]] || { echo "FAIL: init returned empty" >&2; exit 1; }
pass "init returned slug"

repo_hash=$(bash -c "PLUGIN_ROOT=$PLUGIN_ROOT; source $PLUGIN_ROOT/lib/state.sh; cw_repo_hash")
state_dir="$TMPHOME/state/$repo_hash/$slug"
[[ -d "$state_dir/_deep-research" ]] || { echo "FAIL: state dir not created" >&2; exit 1; }
pass "state dir created"

# Phase 2: stage round-1 branches.txt (simulating Yoda's hypothesize)
mkdir -p "$state_dir/_deep-research/round-1"
cat > "$state_dir/_deep-research/round-1/branches.txt" <<'EOF'
b1	rex	AIDE	depth-3 tree search
b2	keeli	MCTS	monte carlo
EOF
pass "branches.txt staged"

# Phase 3: hand-write 2 result.json files (simulating trooper outputs)
for branch in "rex-b1:0.91:ok" "keeli-b2:0.78:ok"; do
  IFS=: read -r dir mv status <<<"$branch"
  bd="$state_dir/_deep-research/round-1-$dir"
  mkdir -p "$bd/code"
  echo "log" > "$bd/stdout.log"
  echo "log" > "$bd/stderr.log"
  cat > "$bd/result.json" <<JSON
{"branch_id":"$dir","approach_label":"$dir","metric_name":"accuracy",
 "metric_value":$mv,"status":"$status","runtime_s":100,
 "log_paths":["./stdout.log","./stderr.log"],"notes":"e2e"}
JSON
done
pass "2 result.json files written"

# Phase 4: score
"$PLUGIN_ROOT/bin/deep-research-score.sh" "$slug" 1 \
  || { echo "FAIL: score.sh rc!=0" >&2; exit 1; }
[[ -f "$state_dir/_deep-research/round-1/scoreboard.md" ]] \
  || { echo "FAIL: scoreboard missing" >&2; exit 1; }
pass "scoreboard generated"

grep -q "rex-b1" "$state_dir/_deep-research/round-1/scoreboard.md" \
  || { echo "FAIL: rex-b1 missing from scoreboard" >&2; exit 1; }
pass "rex-b1 in scoreboard"

# Phase 5: experiment-send (DRY_RUN; mocks pane outbox)
mkdir -p "$state_dir/rex-codex"
touch "$state_dir/rex-codex/outbox.jsonl"
export CW_DEEP_RESEARCH_DRY_RUN=1
"$PLUGIN_ROOT/bin/deep-research-experiment-send.sh" "$slug" 1 rex b1 \
  || { echo "FAIL: experiment-send DRY_RUN rc!=0" >&2; exit 1; }
[[ -f "$state_dir/_deep-research/round-1-rex-b1/prompt.md" ]] \
  || { echo "FAIL: prompt.md missing" >&2; exit 1; }
pass "experiment-send DRY_RUN rendered prompt"

[[ -f "$state_dir/_deep-research/experiment-rex.txt" ]] \
  || { echo "FAIL: state file at experiment-rex.txt missing" >&2; exit 1; }
pass "experiment state file at consult-shape path (for cw_consult_wait)"

# Phase 6: teardown
archive=$("$PLUGIN_ROOT/bin/deep-research-teardown.sh" "$slug")
[[ -d "$archive" ]] || { echo "FAIL: archive dir not created" >&2; exit 1; }
pass "archive dir exists"

[[ ! -d "$state_dir" ]] || { echo "FAIL: state dir not moved" >&2; exit 1; }
pass "state dir moved to archive"

[[ -f "$archive/_deep-research/round-1/scoreboard.md" ]] \
  || { echo "FAIL: scoreboard lost in archive" >&2; exit 1; }
pass "scoreboard preserved in archive"

[[ -f "$archive/_deep-research/round-1-rex-b1/result.json" ]] \
  || { echo "FAIL: branch result.json lost" >&2; exit 1; }
pass "branch result.json preserved in archive"

echo "test_deep_research_e2e: 11 assertions green"
