#!/usr/bin/env bash
# tests/test_deep_research_e2e.sh — v0.27.0 DRY_RUN end-to-end
# init + metric.md staging + flat experiments + score + teardown
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

TMPHOME=$(mktemp -d); trap 'rm -rf "$TMPHOME"' EXIT
export CLONE_WARS_HOME="$TMPHOME"
echo "codex" > "$TMPHOME/providers-available.txt"

# Phase 0/1 sim: init
slug=$("$PLUGIN_ROOT/bin/deep-research-init.sh" "MNIST accuracy")
[[ -n "$slug" ]] || { echo "FAIL: empty slug" >&2; exit 1; }
pass "init returned slug"

source "$PLUGIN_ROOT/lib/state.sh"
REPO_HASH=$(cw_repo_hash)
state_dir="$TMPHOME/state/$REPO_HASH/$slug"
art_dir="$state_dir/_deep-research"
assert_file_exists "$art_dir/topic.txt"
[[ ! -f "$art_dir/budget.txt" ]] \
  || { echo "FAIL: v0.27.0 must not write budget.txt" >&2; exit 1; }
pass "v0.27.0 state shape (no budget.txt)"

# Phase 1 sim: hand-write metric.md
cat > "$art_dir/metric.md" <<'EOF'
# Research goal

**Primary metric:** accuracy
**Direction:** maximize
**Target (good):** >= 0.99

**Notes:** MNIST test set
EOF
pass "metric.md staged"

# Phase 2 sim: hand-write time-budget.txt + session-start.txt + stagnation-cursor.txt
echo "none" > "$art_dir/time-budget.txt"
date -u +%Y-%m-%dT%H:%M:%SZ > "$art_dir/session-start.txt"
echo "0" > "$art_dir/stagnation-cursor.txt"
pass "phase 2 state files staged"

# Phase 3 sim: fake-spawn 2 troopers
for cmdr in rex keeli; do
  mkdir -p "$state_dir/$cmdr-codex"
  cat > "$state_dir/$cmdr-codex/outbox.jsonl" <<EOF
{"event":"ready","ts":"2026-05-12T00:00:00Z","commander":"$cmdr","model":"codex"}
EOF
  cat > "$state_dir/$cmdr-codex/pane.json" <<EOF
{"pane_id":"%9999","pid":99999,"spawned_at":"2026-05-12T00:00:00Z"}
EOF
done

# Dispatch 3 experiments under DRY_RUN
export CW_DEEP_RESEARCH_DRY_RUN=1

"$PLUGIN_ROOT/bin/deep-research-experiment-send.sh" \
  "$slug" rex exp-001 "Modern LeNet" "Baseline CNN 80k params"
rm "$art_dir/experiment-rex.txt"
"$PLUGIN_ROOT/bin/deep-research-experiment-send.sh" \
  "$slug" keeli exp-002 "Depthwise CNN" "MobileNet-style"
rm "$art_dir/experiment-keeli.txt"
"$PLUGIN_ROOT/bin/deep-research-experiment-send.sh" \
  "$slug" rex exp-003 "Modern LeNet + aug" "Add random crop + rotation"
rm "$art_dir/experiment-rex.txt"

assert_file_exists "$art_dir/experiments/exp-001-rex/prompt.md"
assert_file_exists "$art_dir/experiments/exp-002-keeli/prompt.md"
assert_file_exists "$art_dir/experiments/exp-003-rex/prompt.md"
pass "3 experiments dispatched in flat experiments/ shape"

# Hand-write 3 result.json files
write_result() {
  local exp="$1" cmdr="$2" metric="$3" label="$4"
  local d="$art_dir/experiments/$exp-$cmdr"
  echo "log" > "$d/stdout.log"
  echo "log" > "$d/stderr.log"
  cat > "$d/result.json" <<EOF
{"branch_id":"$exp","approach_label":"$label","metric_name":"accuracy",
 "metric_value":$metric,"status":"ok","runtime_s":30,
 "log_paths":["./stdout.log","./stderr.log"],"notes":"e2e"}
EOF
}
write_result exp-001 rex 0.9894 "Modern LeNet"
write_result exp-002 keeli 0.7916 "Depthwise CNN"
write_result exp-003 rex 0.9903 "Modern LeNet + aug"

"$PLUGIN_ROOT/bin/deep-research-score.sh" "$slug"
assert_file_exists "$art_dir/scoreboard.md"
[[ ! -d "$art_dir/round-1" ]] \
  || { echo "FAIL: v0.27.0 must not create round-N subdirs" >&2; exit 1; }
pass "scoreboard.md at flat path; no round-N subdirs"

top_row=$(grep '^|' "$art_dir/scoreboard.md" | head -3 | tail -1)
[[ "$top_row" == *"exp-003"* ]] \
  || { echo "FAIL: top row not exp-003; got: $top_row" >&2; exit 1; }
pass "top of scoreboard = exp-003 (best metric)"

archive=$("$PLUGIN_ROOT/bin/deep-research-teardown.sh" "$slug")
[[ -d "$archive" ]] || { echo "FAIL: archive dir missing" >&2; exit 1; }
pass "archive dir exists"

assert_file_exists "$archive/_deep-research/scoreboard.md"
assert_file_exists "$archive/_deep-research/experiments/exp-001-rex/result.json"
assert_file_exists "$archive/_deep-research/experiments/exp-002-keeli/result.json"
assert_file_exists "$archive/_deep-research/experiments/exp-003-rex/result.json"
assert_file_exists "$archive/_deep-research/metric.md"
assert_file_exists "$archive/_deep-research/time-budget.txt"
pass "archive preserves all experiments + phase-2 state files"

echo "test_deep_research_e2e: 9 assertions green"
