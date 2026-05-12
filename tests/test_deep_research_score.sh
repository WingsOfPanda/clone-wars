#!/usr/bin/env bash
# tests/test_deep_research_score.sh — round scoreboard generation
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

TMPHOME=$(mktemp -d)
trap 'rm -rf "$TMPHOME"' EXIT
export CLONE_WARS_HOME="$TMPHOME"
echo "codex" > "$TMPHOME/providers-available.txt"

# Init topic
slug=$("$PLUGIN_ROOT/bin/deep-research-init.sh" "optimize accuracy")
repo_hash=$(bash -c "PLUGIN_ROOT=$PLUGIN_ROOT; source $PLUGIN_ROOT/lib/state.sh; cw_repo_hash")
state_dir="$TMPHOME/state/$repo_hash/$slug"

# Stage round 1 branches.txt + 3 branches
mkdir -p "$state_dir/_deep-research/round-1"
cat > "$state_dir/_deep-research/round-1/branches.txt" <<'EOF'
b1	rex	AIDE	depth-3 tree search
b2	keeli	MCTS	monte carlo
b3	colt	Random	baseline
EOF

write_result() {
  local cmdr="$1" bid="$2" mv="$3" status="$4"
  local bd="$state_dir/_deep-research/round-1-$cmdr-$bid"
  mkdir -p "$bd"
  echo "stdout" > "$bd/stdout.log"
  echo "stderr" > "$bd/stderr.log"
  cat > "$bd/result.json" <<JSON
{"branch_id":"$cmdr-$bid","approach_label":"$cmdr-$bid label","metric_name":"accuracy",
 "metric_value":$mv,"status":"$status","runtime_s":100,
 "log_paths":["./stdout.log","./stderr.log"],"notes":""}
JSON
}

write_result rex b1 0.95 ok
write_result keeli b2 0.88 ok
write_result colt b3 null fail

# Score
"$PLUGIN_ROOT/bin/deep-research-score.sh" "$slug" 1 \
  || { echo "FAIL: score.sh rc=0" >&2; exit 1; }
pass "score.sh rc=0"

scoreboard="$state_dir/_deep-research/round-1/scoreboard.md"
[[ -f "$scoreboard" ]] || { echo "FAIL: scoreboard.md not written" >&2; exit 1; }
pass "scoreboard.md written"

# rex-b1 (highest metric) appears before keeli-b2
rex_line=$(grep -n "rex-b1" "$scoreboard" | head -1 | cut -d: -f1)
keeli_line=$(grep -n "keeli-b2" "$scoreboard" | head -1 | cut -d: -f1)
(( rex_line < keeli_line )) \
  || { echo "FAIL: rex-b1 not before keeli-b2 (lines $rex_line vs $keeli_line)" >&2; cat "$scoreboard" >&2; exit 1; }
pass "rex-b1 (0.95) ranked before keeli-b2 (0.88)"

# Failed branch colt-b3 listed
grep -q "colt-b3" "$scoreboard" \
  || { echo "FAIL: failed branch colt-b3 missing from scoreboard" >&2; exit 1; }
pass "failed branch colt-b3 listed in scoreboard"

# Failed branch is after ok branches (sorted to bottom)
colt_line=$(grep -n "colt-b3" "$scoreboard" | head -1 | cut -d: -f1)
(( colt_line > keeli_line )) \
  || { echo "FAIL: colt-b3 (fail) should be after ok rows" >&2; exit 1; }
pass "failed branches grouped at bottom"

# Status fields present in table
grep -q "| ok " "$scoreboard" \
  || { echo "FAIL: 'ok' status not rendered" >&2; exit 1; }
pass "status 'ok' rendered in table"

grep -q "| fail " "$scoreboard" \
  || { echo "FAIL: 'fail' status not rendered" >&2; exit 1; }
pass "status 'fail' rendered in table"

# Atomic write: no .tmp leftovers
[[ ! -f "${scoreboard}.tmp" ]] \
  || { echo "FAIL: .tmp leftover from non-atomic write" >&2; exit 1; }
pass "atomic write (no .tmp leftover)"

# Missing branches.txt → error
if "$PLUGIN_ROOT/bin/deep-research-score.sh" "$slug" 99 2>/dev/null; then
  echo "FAIL: missing round should error" >&2; exit 1
fi
pass "missing round errors"

# Bad topic → error
if "$PLUGIN_ROOT/bin/deep-research-score.sh" "consult-foo" 1 2>/dev/null; then
  echo "FAIL: non-deep-research topic should error" >&2; exit 1
fi
pass "rejects non-deep-research topic"

echo "test_deep_research_score: 10 assertions green"
