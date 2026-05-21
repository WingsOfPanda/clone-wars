#!/usr/bin/env bash
# tests/test_v0_51_0_static_wiring.sh — v0.51 static-wiring lock.
# Skip-guarded: passes via SKIP until plugin.json version reaches 0.51.0,
# then activates and enforces all 5 invariants.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
PLUGIN_JSON="$PLUGIN_ROOT/.claude-plugin/plugin.json"
MARKETPLACE_JSON="$PLUGIN_ROOT/.claude-plugin/marketplace.json"

CUR_VER=$(awk -F'"' '/"version":/ { print $4; exit }' "$PLUGIN_JSON")
if [[ "$CUR_VER" != "0.51.0" ]]; then
  pass "SKIP — plugin.json version is $CUR_VER (lock active only at 0.51.0)"
  echo "test_v0_51_0_static_wiring: skip-pass"
  exit 0
fi

# Invariant 1: plugin.json AND marketplace.json both at 0.51.0
mp_count=$(grep -c '"version": *"0\.51\.0"' "$MARKETPLACE_JSON")
assert_eq "$mp_count" "2" "INV1: marketplace.json has both version lines at 0.51.0"
pass "INV1. plugin.json + marketplace.json at 0.51.0"

# Invariant 2: lib/deep-research.sh defines cw_deep_research_trooper_state_reconcile
grep -qE '^cw_deep_research_trooper_state_reconcile\(\)' "$PLUGIN_ROOT/lib/deep-research.sh" \
  || { echo "FAIL INV2: cw_deep_research_trooper_state_reconcile definition not found" >&2; exit 1; }
pass "INV2. cw_deep_research_trooper_state_reconcile defined"

# Invariant 3: bin/deep-research-finalize.sh calls cw_deep_research_trooper_state_reconcile
grep -q 'cw_deep_research_trooper_state_reconcile' "$PLUGIN_ROOT/bin/deep-research-finalize.sh" \
  || { echo "FAIL INV3: cw_deep_research_trooper_state_reconcile not called from finalize.sh" >&2; exit 1; }
pass "INV3. finalize.sh invokes the reconcile helper"

# Invariant 4: lib/ipc.sh defines cw_spawn_capture_failure_forensics
#              AND bin/spawn.sh::_spawn_bootstrap_fail body invokes it.
grep -qE '^cw_spawn_capture_failure_forensics\(\)' "$PLUGIN_ROOT/lib/ipc.sh" \
  || { echo "FAIL INV4a: cw_spawn_capture_failure_forensics definition not found" >&2; exit 1; }
# awk-scope the search to inside _spawn_bootstrap_fail's body so a stray
# comment elsewhere in spawn.sh doesn't false-positive.
awk '
  /^_spawn_bootstrap_fail\(\)/ { in_fn=1 }
  in_fn && /^}/                { in_fn=0 }
  in_fn                        { print }
' "$PLUGIN_ROOT/bin/spawn.sh" | grep -q 'cw_spawn_capture_failure_forensics' \
  || { echo "FAIL INV4b: cw_spawn_capture_failure_forensics not called inside _spawn_bootstrap_fail" >&2; exit 1; }
pass "INV4. cw_spawn_capture_failure_forensics defined + wired into _spawn_bootstrap_fail"

# Invariant 5: experiment.md schema contains "checkpoint_path"
grep -q '"checkpoint_path"' "$PLUGIN_ROOT/config/prompt-templates/deep-research/experiment.md" \
  || { echo "FAIL INV5: checkpoint_path not in experiment.md schema" >&2; exit 1; }
pass "INV5. experiment.md schema contains checkpoint_path"

echo "test_v0_51_0_static_wiring: 5 invariants passed"
