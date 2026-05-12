#!/usr/bin/env bash
# tests/test_deep_research_init.sh — init script for /clone-wars:deep-research
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

TMPHOME=$(mktemp -d)
trap 'rm -rf "$TMPHOME"' EXIT
export CLONE_WARS_HOME="$TMPHOME"

# providers-available.txt with codex
mkdir -p "$TMPHOME"
cat > "$TMPHOME/providers-available.txt" <<'EOF'
codex
claude
EOF

# Happy path
slug=$("$PLUGIN_ROOT/bin/deep-research-init.sh" "optimize MNIST accuracy under 100k params")
[[ "$slug" == deep-research-* ]] \
  || { echo "FAIL: expected deep-research-* slug, got '$slug'" >&2; exit 1; }
pass "init returns deep-research-* slug"

repo_hash=$(bash -c "PLUGIN_ROOT=$PLUGIN_ROOT; source $PLUGIN_ROOT/lib/state.sh; cw_repo_hash")
state_dir="$TMPHOME/state/$repo_hash/$slug"

[[ -d "$state_dir/_deep-research" ]] \
  || { echo "FAIL: _deep-research dir missing" >&2; exit 1; }
pass "_deep-research dir created"

[[ -f "$state_dir/_deep-research/topic.txt" ]] \
  || { echo "FAIL: topic.txt missing" >&2; exit 1; }
pass "topic.txt written"

[[ "$(cat "$state_dir/_deep-research/metric.txt")" == "accuracy" ]] \
  || { echo "FAIL: wrong metric: '$(cat "$state_dir/_deep-research/metric.txt")'" >&2; exit 1; }
pass "metric.txt has 'accuracy'"

[[ -f "$state_dir/_deep-research/budget.txt" ]] \
  || { echo "FAIL: budget.txt missing" >&2; exit 1; }
pass "budget.txt written"

grep -q "^max-rounds=3$" "$state_dir/_deep-research/budget.txt" \
  || { echo "FAIL: default max-rounds not 3" >&2; exit 1; }
pass "budget.txt default max-rounds=3"

grep -q "^branches-per-round=4$" "$state_dir/_deep-research/budget.txt" \
  || { echo "FAIL: default K not 4" >&2; exit 1; }
pass "budget.txt default branches-per-round=4"

grep -q "^time-budget-s=3600$" "$state_dir/_deep-research/budget.txt" \
  || { echo "FAIL: default 1h not 3600" >&2; exit 1; }
pass "budget.txt default time-budget=3600s"

grep -q "^per-branch-timeout-s=300$" "$state_dir/_deep-research/budget.txt" \
  || { echo "FAIL: per-branch wrong: $(grep per-branch "$state_dir/_deep-research/budget.txt")" >&2; exit 1; }
pass "budget.txt per-branch=300 (3600/12)"

grep -q "^allow-net=false$" "$state_dir/_deep-research/budget.txt" \
  || { echo "FAIL: default allow-net not false" >&2; exit 1; }
pass "budget.txt default allow-net=false"

# Codex absent → init refuses
echo "claude" > "$TMPHOME/providers-available.txt"
if "$PLUGIN_ROOT/bin/deep-research-init.sh" "optimize accuracy" 2>/dev/null; then
  echo "FAIL: should refuse without codex" >&2; exit 1
fi
pass "refuses when codex absent from providers-available.txt"

# Restore for further tests
cat > "$TMPHOME/providers-available.txt" <<'EOF'
codex
claude
EOF

# Custom budget knobs
slug2=$("$PLUGIN_ROOT/bin/deep-research-init.sh" \
  --max-rounds 5 --branches-per-round 2 --time-budget 30m \
  "optimize accuracy second time")
state_dir2="$TMPHOME/state/$repo_hash/$slug2"

grep -q "^max-rounds=5$" "$state_dir2/_deep-research/budget.txt" \
  || { echo "FAIL: --max-rounds=5 not honored" >&2; exit 1; }
pass "--max-rounds=5 honored"

grep -q "^branches-per-round=2$" "$state_dir2/_deep-research/budget.txt" \
  || { echo "FAIL: --branches-per-round=2 not honored" >&2; exit 1; }
pass "--branches-per-round=2 honored"

grep -q "^time-budget-s=1800$" "$state_dir2/_deep-research/budget.txt" \
  || { echo "FAIL: 30m not parsed to 1800s" >&2; exit 1; }
pass "30m duration parsed to 1800s"

# Per-branch = ceil(1800 / (5*2)) = 180
grep -q "^per-branch-timeout-s=180$" "$state_dir2/_deep-research/budget.txt" \
  || { echo "FAIL: per-branch=180 expected" >&2; exit 1; }
pass "per-branch=180 computed correctly"

# --allow-net flips
slug3=$("$PLUGIN_ROOT/bin/deep-research-init.sh" --allow-net "optimize accuracy third")
state_dir3="$TMPHOME/state/$repo_hash/$slug3"
grep -q "^allow-net=true$" "$state_dir3/_deep-research/budget.txt" \
  || { echo "FAIL: --allow-net not honored" >&2; exit 1; }
pass "--allow-net flips guidance to true"

# --seed-from writes seed-from.txt
seed_doc=$(mktemp)
echo "fake landscape" > "$seed_doc"
slug4=$("$PLUGIN_ROOT/bin/deep-research-init.sh" --seed-from "$seed_doc" "optimize accuracy fourth")
state_dir4="$TMPHOME/state/$repo_hash/$slug4"
[[ -f "$state_dir4/_deep-research/seed-from.txt" ]] \
  || { echo "FAIL: seed-from.txt not written" >&2; exit 1; }
[[ "$(cat "$state_dir4/_deep-research/seed-from.txt")" == "$seed_doc" ]] \
  || { echo "FAIL: seed-from path mismatch" >&2; exit 1; }
pass "--seed-from writes seed-from.txt"
rm -f "$seed_doc"

# --seed-from missing path → error
if "$PLUGIN_ROOT/bin/deep-research-init.sh" --seed-from /tmp/non-existent-$$-xx "topic" 2>/dev/null; then
  echo "FAIL: missing seed-from path should error" >&2; exit 1
fi
pass "--seed-from missing path errors"

# No topic → error
if "$PLUGIN_ROOT/bin/deep-research-init.sh" 2>/dev/null; then
  echo "FAIL: no topic should error" >&2; exit 1
fi
pass "no topic errors"

echo "test_deep_research_init: 17 assertions green"
