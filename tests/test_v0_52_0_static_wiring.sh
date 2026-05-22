#!/usr/bin/env bash
# tests/test_v0_52_0_static_wiring.sh — v0.52 static-wiring lock.
# Skip-guarded: passes via SKIP until plugin.json version reaches 0.52.0,
# then activates and enforces all 7 invariants.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
PLUGIN_JSON="$PLUGIN_ROOT/.claude-plugin/plugin.json"
MARKETPLACE_JSON="$PLUGIN_ROOT/.claude-plugin/marketplace.json"

CUR_VER=$(awk -F'"' '/"version":/ { print $4; exit }' "$PLUGIN_JSON")
if [[ "$CUR_VER" != "0.52.0" ]]; then
  pass "SKIP — plugin.json version is $CUR_VER (lock active only at 0.52.0)"
  echo "test_v0_52_0_static_wiring: skip-pass"
  exit 0
fi

# Invariant 1: plugin.json + marketplace.json both at 0.52.0
mp_count=$(grep -c '"version": *"0\.52\.0"' "$MARKETPLACE_JSON")
assert_eq "$mp_count" "2" "INV1: marketplace.json has both version lines at 0.52.0"
pass "INV1. plugin.json + marketplace.json at 0.52.0"

# Invariant 2: lib/deep-research.sh defines cw_deep_research_prune_intermediate_checkpoints
grep -qE '^cw_deep_research_prune_intermediate_checkpoints\(\)' \
  "$PLUGIN_ROOT/lib/deep-research.sh" \
  || { echo "FAIL INV2: prune helper not defined" >&2; exit 1; }
pass "INV2. cw_deep_research_prune_intermediate_checkpoints defined"

# Invariant 3: lib/deep-research.sh defines cw_deep_research_link_pane_artifacts
grep -qE '^cw_deep_research_link_pane_artifacts\(\)' \
  "$PLUGIN_ROOT/lib/deep-research.sh" \
  || { echo "FAIL INV3: link_pane_artifacts helper not defined" >&2; exit 1; }
pass "INV3. cw_deep_research_link_pane_artifacts defined"

# Invariant 4: lib/deep-research.sh defines cw_deep_research_compute_size_warnings
grep -qE '^cw_deep_research_compute_size_warnings\(\)' \
  "$PLUGIN_ROOT/lib/deep-research.sh" \
  || { echo "FAIL INV4: compute_size_warnings helper not defined" >&2; exit 1; }
pass "INV4. cw_deep_research_compute_size_warnings defined"

# Invariant 5: render_summary references warnings.txt
grep -qE 'warnings\.txt' "$PLUGIN_ROOT/lib/deep-research.sh" \
  || { echo "FAIL INV5: render_summary doesn't reference warnings.txt" >&2; exit 1; }
pass "INV5. render_summary reads warnings.txt"

# Invariant 6: finalize.sh accepts --keep-intermediate
grep -qE '\-\-keep-intermediate' "$PLUGIN_ROOT/bin/deep-research-finalize.sh" \
  || { echo "FAIL INV6: --keep-intermediate not parsed in finalize.sh" >&2; exit 1; }
pass "INV6. finalize.sh parses --keep-intermediate"

# Invariant 7: experiment-send.sh accepts --timeout AND uses precedence chain
grep -qE '\-\-timeout' "$PLUGIN_ROOT/bin/deep-research-experiment-send.sh" \
  || { echo "FAIL INV7a: --timeout not parsed in experiment-send.sh" >&2; exit 1; }
grep -qE 'TIMEOUT_FLAG:-\$\{CW_DEEP_RESEARCH_EXPERIMENT_TIMEOUT_OVERRIDE' \
  "$PLUGIN_ROOT/bin/deep-research-experiment-send.sh" \
  || { echo "FAIL INV7b: precedence chain TIMEOUT_FLAG->env->default not present" >&2; exit 1; }
pass "INV7. experiment-send.sh has --timeout + precedence chain"

echo "ALL: ok"
