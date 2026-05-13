#!/usr/bin/env bash
# tests/test_deep_research_metric_extended_fields.sh — v0.28.0 metric.md schema
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"

# All fields including new ones
OUT=$(cw_deep_research_format_metric_block <<'EOF'
primary_metric=accuracy
direction=maximize
min_acceptable=>= 0.90
target=>= 0.99
K_corroboration=2
plateau_window=5
plateau_threshold=0.01
hard_constraints=params < 100k
notes=MNIST test
EOF
)
assert_contains "$OUT" "**Primary metric:**" "header still present"
assert_contains "$OUT" "accuracy" "metric name"
assert_contains "$OUT" "min_acceptable" "min_acceptable field"
assert_contains "$OUT" ">= 0.90" "min_acceptable value"
assert_contains "$OUT" "K_corroboration" "K_corroboration field"
assert_contains "$OUT" "2" "K_corroboration value"
assert_contains "$OUT" "plateau_window" "plateau_window field"
assert_contains "$OUT" "plateau_threshold" "plateau_threshold field"
pass "all v0.28.0 fields rendered"

# Missing new fields renders with defaults
OUT=$(cw_deep_research_format_metric_block <<'EOF'
primary_metric=accuracy
direction=maximize
target=>= 0.99
hard_constraints=params < 100k
EOF
)
assert_contains "$OUT" "min_acceptable" "min_acceptable shown even when missing"
assert_contains "$OUT" "K_corroboration" "K_corroboration shown with default"
pass "missing fields handled gracefully"
