#!/usr/bin/env bash
# tests/test_v0_48_0_static_wiring.sh — v0.48 static-wiring lock.
# Skip-guarded: passes via SKIP until plugin.json version reaches 0.48.0,
# then activates and enforces all 6 invariants.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
PLUGIN_JSON="$PLUGIN_ROOT/.claude-plugin/plugin.json"
MARKETPLACE_JSON="$PLUGIN_ROOT/.claude-plugin/marketplace.json"

CUR_VER=$(awk -F'"' '/"version":/ { print $4; exit }' "$PLUGIN_JSON")
if [[ "$CUR_VER" != "0.48.0" ]]; then
  pass "SKIP — plugin.json version is $CUR_VER (lock active only at 0.48.0)"
  echo "test_v0_48_0_static_wiring: skip-pass"
  exit 0
fi

# Invariant 1: plugin.json AND marketplace.json both at 0.48.0
mp_count=$(grep -c '"version": *"0\.48\.0"' "$MARKETPLACE_JSON")
assert_eq "$mp_count" "2" "INV1: marketplace.json has both version lines at 0.48.0"
pass "INV1. plugin.json + marketplace.json at 0.48.0"

# Invariant 2: cw_deep_research_halt_flag_read defined in lib/deep-research.sh
grep -q '^cw_deep_research_halt_flag_read() {' "$PLUGIN_ROOT/lib/deep-research.sh" \
  || { echo "FAIL INV2: cw_deep_research_halt_flag_read not defined" >&2; exit 1; }
pass "INV2. cw_deep_research_halt_flag_read defined"

# Invariant 3: cw_deep_research_scoreboard_render_row defined in lib/deep-research.sh
grep -q '^cw_deep_research_scoreboard_render_row() {' "$PLUGIN_ROOT/lib/deep-research.sh" \
  || { echo "FAIL INV3: cw_deep_research_scoreboard_render_row not defined" >&2; exit 1; }
pass "INV3. cw_deep_research_scoreboard_render_row defined"

# Invariant 4: bin/deep-research-finalize.sh contains no `tr -d '\n'` against halt.flag
if grep -E "halt\.flag.*\|.*tr -d|tr -d.*halt\.flag" "$PLUGIN_ROOT/bin/deep-research-finalize.sh"; then
  echo "FAIL INV4: finalize.sh still uses tr -d against halt.flag" >&2
  exit 1
fi
pass "INV4. finalize.sh no longer strips newlines from halt.flag"

# Invariant 5: score.sh emits schema_version=2 marker as first scoreboard line
grep -q "schema_version=2" "$PLUGIN_ROOT/bin/deep-research-score.sh" \
  || { echo "FAIL INV5: score.sh missing schema_version=2 marker" >&2; exit 1; }
pass "INV5. score.sh emits schema_version=2"

# Invariant 6: score.sh does NOT contain the raw single-key sort
if grep -E "sort -t\\\$'\\\\t' -k1,1 -rn" "$PLUGIN_ROOT/bin/deep-research-score.sh"; then
  echo "FAIL INV6: score.sh still uses single-key sort" >&2
  exit 1
fi
pass "INV6. score.sh sort is multi-key (no single-key form present)"

echo "test_v0_48_0_static_wiring: 6 invariants passed"
