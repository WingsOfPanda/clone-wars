#!/usr/bin/env bash
# tests/test_deep_research_scoreboard_render_row.sh — v0.48 finding #6+#7
# Locks the contract of cw_deep_research_scoreboard_render_row.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/lib/state.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/lib/consult.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/lib/deep-research.sh"

# Case 1: long float metric → %.4f truncation
out=$(cw_deep_research_scoreboard_render_row "0.9657292557741659" "89.66945878043771" "wdl_rate" "ok" "qnet-cnn-transformer")
assert_contains "$out" "0.9657" "long float: metric trimmed to %.4f"
assert_contains "$out" "89.67s" "long float: runtime trimmed to %.2fs"
assert_contains "$out" "wdl_rate" "long float: metric_name preserved"
assert_contains "$out" "ok" "long float: status preserved"
assert_contains "$out" "qnet-cnn-transformer" "long float: approach preserved"
pass "1. long float metric and runtime trimmed to fixed widths"

# Case 2: integer-style runtime (853.0 → 853.00s)
out=$(cw_deep_research_scoreboard_render_row "0.9300" "853.0" "wdl_rate" "ok" "rule-engine-baseline")
assert_contains "$out" "0.9300" "int runtime: metric %.4f preserves trailing zeros"
assert_contains "$out" "853.00s" "int runtime: %.2fs formatting"
pass "2. integer-style runtime padded to %.2fs"

# Case 3: (running) metric — passes through unformatted
out=$(cw_deep_research_scoreboard_render_row "(running)" "" "wdl_rate" "running" "tbd")
assert_contains "$out" "(running)" "running: metric passes through unformatted"
assert_contains "$out" "running" "running: status preserved"
pass "3. (running) metric passes through unformatted"

# Case 4: NaN guard — non-numeric metric should not crash; passes through verbatim
out=$(cw_deep_research_scoreboard_render_row "n/a" "12.5" "wdl_rate" "failed" "compile-error")
assert_contains "$out" "n/a" "nan: metric passes through verbatim"
assert_contains "$out" "12.50s" "nan: runtime still formatted (numeric)"
pass "4. non-numeric metric handled without crash"

echo "test_deep_research_scoreboard_render_row: 4 cases passed"
