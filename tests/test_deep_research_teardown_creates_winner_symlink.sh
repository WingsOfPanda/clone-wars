#!/usr/bin/env bash
# tests/test_deep_research_teardown_creates_winner_symlink.sh
# v0.43.0 Lane B: teardown creates _deep-research/winner -> top-1 code dir.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
cd "$SANDBOX"
export CLONE_WARS_HOME="$SANDBOX/.clone-wars"

TOPIC=deep-research-winner-test
TD="$(cw_topic_state_dir "$TOPIC")"
ART="$TD/_deep-research"
mkdir -p "$ART/troopers/rex/experiments/exp-002/code"
mkdir -p "$ART/troopers/keeli/experiments/exp-001/code"
echo "rex-winning-code" > "$ART/troopers/rex/experiments/exp-002/code/train.py"
echo "rex" > "$ART/troopers.txt"
echo "keeli" >> "$ART/troopers.txt"

# Scoreboard: rex/exp-002 is top-1 ok row
cat > "$ART/scoreboard.md" <<'SB'
# Scoreboard

| Rank | Experiment | Commander | Metric | Status | Runtime | Approach | metric_name |
|---|---|---|---|---|---|---|---|
| 1 | exp-002 | rex | 0.95 | ok | 100s | best | test_metric |
| 2 | exp-001 | keeli | 0.88 | ok | 80s | runner-up | test_metric |
SB

ARCHIVE=$("$PLUGIN_ROOT/bin/deep-research-teardown.sh" "$TOPIC")

WINNER="$ARCHIVE/_deep-research/winner"
[[ -L "$WINNER" ]] || { echo "FAIL: winner symlink not created at $WINNER" >&2; exit 1; }
TARGET=$(readlink "$WINNER")
assert_eq "$TARGET" "troopers/rex/experiments/exp-002/code" "winner -> top-1 code dir (relative)"
[[ -f "$WINNER/train.py" ]] || { echo "FAIL: symlink does not resolve to code dir" >&2; exit 1; }
pass "1. teardown creates winner symlink to top-1 ok-row code dir"

echo "test_deep_research_teardown_creates_winner_symlink: 1 case passed"
