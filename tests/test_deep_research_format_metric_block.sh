#!/usr/bin/env bash
# tests/test_deep_research_format_metric_block.sh — render metric.md from K=V stdin
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"

# Full case — all fields present
got=$(cw_deep_research_format_metric_block <<'EOF'
primary_metric=accuracy
direction=maximize
target=>= 0.99
acceptable=>= 0.97
hard_constraints=params < 100k
notes=MNIST test set
EOF
)

assert_contains "$got" "# Research goal" "header present"
assert_contains "$got" "**Primary metric:** accuracy" "primary_metric"
assert_contains "$got" "**Direction:** maximize" "direction"
assert_contains "$got" "**target:** >= 0.99" "target"
assert_contains "$got" "**acceptable (legacy):** >= 0.97" "acceptable (legacy)"
assert_contains "$got" "**Hard constraints:** params < 100k" "hard_constraints"
assert_contains "$got" "**Notes:** MNIST test set" "notes"
pass "full K=V set rendered"

# Minimal case — only primary_metric + direction
got=$(cw_deep_research_format_metric_block <<'EOF'
primary_metric=latency
direction=minimize
EOF
)

assert_contains "$got" "**Primary metric:** latency" "min primary_metric"
assert_contains "$got" "**Direction:** minimize" "min direction"
[[ "$got" != *"**target:**"* ]] \
  || { echo "FAIL: target shown for minimal case" >&2; exit 1; }
pass "minimal K=V omits unset optional fields"

# Missing primary_metric rejected
err=$(cw_deep_research_format_metric_block <<<'direction=maximize' 2>&1) && {
  echo "FAIL: should reject missing primary_metric" >&2; exit 1
}
assert_contains "$err" "primary_metric" "error mentions missing field"
pass "missing primary_metric rejected"

# Missing direction rejected
err=$(cw_deep_research_format_metric_block <<<'primary_metric=accuracy' 2>&1) && {
  echo "FAIL: should reject missing direction" >&2; exit 1
}
assert_contains "$err" "direction" "error mentions missing direction"
pass "missing direction rejected"

# Invalid direction rejected
err=$(cw_deep_research_format_metric_block 2>&1 <<'EOF'
primary_metric=accuracy
direction=optimize
EOF
) && { echo "FAIL: 'optimize' should be rejected" >&2; exit 1; }
assert_contains "$err" "direction must be" "error mentions valid values"
pass "invalid direction rejected"

echo "test_deep_research_format_metric_block: 5 assertions green"
