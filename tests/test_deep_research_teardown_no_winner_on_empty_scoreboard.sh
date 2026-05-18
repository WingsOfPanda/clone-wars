#!/usr/bin/env bash
# tests/test_deep_research_teardown_no_winner_on_empty_scoreboard.sh
# v0.43.0 Lane B: teardown skips symlink creation silently when scoreboard
# is missing OR has zero ok rows. Still exits rc=0.
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

# Case 1: scoreboard.md missing entirely
TOPIC_A=deep-research-empty-board-a
TD_A="$(cw_topic_state_dir "$TOPIC_A")"
mkdir -p "$TD_A/_deep-research/troopers"
echo "rex" > "$TD_A/_deep-research/troopers.txt"
ARCHIVE_A=$("$PLUGIN_ROOT/bin/deep-research-teardown.sh" "$TOPIC_A")
[[ -d "$ARCHIVE_A" ]] || { echo "FAIL: archive dir missing on no-scoreboard case" >&2; exit 1; }
[[ ! -L "$ARCHIVE_A/_deep-research/winner" ]] \
  || { echo "FAIL: winner symlink created when scoreboard missing" >&2; exit 1; }
pass "1. no scoreboard → no winner symlink, teardown still rc=0"

# Case 2: scoreboard.md present, all rows status=fail
TOPIC_B=deep-research-empty-board-b
TD_B="$(cw_topic_state_dir "$TOPIC_B")"
ART_B="$TD_B/_deep-research"
mkdir -p "$ART_B/troopers/rex/experiments/exp-001/code"
echo "rex" > "$ART_B/troopers.txt"
cat > "$ART_B/scoreboard.md" <<'SB'
# Scoreboard

| Rank | Experiment | Commander | Metric | Status | Runtime | Approach | metric_name |
|---|---|---|---|---|---|---|---|
| 1 | exp-001 | rex | n/a | fail | 5s | crash | test_metric |
SB
ARCHIVE_B=$("$PLUGIN_ROOT/bin/deep-research-teardown.sh" "$TOPIC_B")
[[ ! -L "$ARCHIVE_B/_deep-research/winner" ]] \
  || { echo "FAIL: winner symlink created when all rows fail" >&2; exit 1; }
pass "2. scoreboard with only fail rows → no winner symlink"

echo "test_deep_research_teardown_no_winner_on_empty_scoreboard: 2 cases passed"
