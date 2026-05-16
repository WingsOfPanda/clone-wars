#!/usr/bin/env bash
# tests/test_v0_35_0_static_wiring.sh
# Version-stamped invariant lock for v0.35.0. Skips with PASS when the
# plugin version != 0.35.0 so future versions don't re-fire this lock.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"

PV=$(grep -E '^  "version":' "$PLUGIN_ROOT/.claude-plugin/plugin.json" \
  | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')

if [[ "$PV" != "0.35.0" ]]; then
  pass "skip — plugin version $PV ≠ 0.35.0"
  exit 0
fi

# --- Invariant 1: plugin.json reports 0.35.0 ---
assert_eq "$PV" "0.35.0" "invariant 1: plugin.json version"
pass "1. plugin.json reads 0.35.0"

# --- Invariant 2: cw_contract_timeout_multiplier defined ---
grep -q 'cw_contract_timeout_multiplier()' "$PLUGIN_ROOT/lib/contracts.sh" \
  || { echo "FAIL: invariant 2: helper missing from lib/contracts.sh" >&2; exit 1; }
pass "2. cw_contract_timeout_multiplier defined in lib/contracts.sh"

# --- Invariant 3: cw_consult_wait references the multiplier ---
grep -q 'cw_contract_timeout_multiplier' "$PLUGIN_ROOT/lib/consult-wait.sh" \
  || { echo "FAIL: invariant 3: cw_consult_wait doesn't call multiplier helper" >&2; exit 1; }
pass "3. cw_consult_wait calls cw_contract_timeout_multiplier"

# --- Invariant 4: cw_consult_wait references LIVENESS_PROBE_S ---
grep -q 'CW_CONSULT_LIVENESS_PROBE_S' "$PLUGIN_ROOT/lib/consult-wait.sh" \
  || { echo "FAIL: invariant 4: LIVENESS_PROBE_S knob missing" >&2; exit 1; }
pass "4. cw_consult_wait honors CW_CONSULT_LIVENESS_PROBE_S"

# --- Invariant 5: cw_consult_wait references MAX_DEADLINE_FACTOR ---
grep -q 'CW_CONSULT_MAX_DEADLINE_FACTOR' "$PLUGIN_ROOT/lib/consult-wait.sh" \
  || { echo "FAIL: invariant 5: MAX_DEADLINE_FACTOR knob missing" >&2; exit 1; }
pass "5. cw_consult_wait honors CW_CONSULT_MAX_DEADLINE_FACTOR"

# --- Invariant 6: contracts.yaml has timeout_multiplier under opencode only ---
awk '
  /^opencode:/ { in_opencode = 1; next }
  /^[a-z]/     { in_opencode = 0 }
  in_opencode && /^  timeout_multiplier:[[:space:]]*2\.5/ { found = 1 }
  END { exit !found }
' "$PLUGIN_ROOT/config/contracts.yaml" \
  || { echo "FAIL: invariant 6: opencode timeout_multiplier: 2.5 missing" >&2; exit 1; }
for prov in codex gemini claude; do
  awk -v p="$prov" '
    $0 ~ "^"p":" { in_block = 1; next }
    /^[a-z]/     { in_block = 0 }
    in_block && /^  timeout_multiplier:/ { exit 1 }
    END { exit 0 }
  ' "$PLUGIN_ROOT/config/contracts.yaml" \
    || { echo "FAIL: invariant 6: $prov should not ship a multiplier" >&2; exit 1; }
done
pass "6. opencode timeout_multiplier: 2.5 (others implicit 1.0)"

# --- Invariant 7: CLAUDE.md has v0.35.0 status row + release-gate row ---
grep -q '^- \[x\] v0.35.0' "$PLUGIN_ROOT/CLAUDE.md" \
  || { echo "FAIL: invariant 7a: CLAUDE.md missing v0.35.0 done row" >&2; exit 1; }
grep -q '^- \[ \] v0.35.0 strict-dogfood' "$PLUGIN_ROOT/CLAUDE.md" \
  || { echo "FAIL: invariant 7b: CLAUDE.md missing v0.35.0 release-gate row" >&2; exit 1; }
pass "7. CLAUDE.md has v0.35.0 status + release-gate rows"

# --- Invariant 8: stat fallback chain present (Linux + macOS) ---
grep -q "stat -c '%Y'" "$PLUGIN_ROOT/lib/consult-wait.sh" \
  || { echo "FAIL: invariant 8a: GNU stat call missing" >&2; exit 1; }
grep -q "stat -f '%m'" "$PLUGIN_ROOT/lib/consult-wait.sh" \
  || { echo "FAIL: invariant 8b: BSD stat fallback missing" >&2; exit 1; }
pass "8. stat fallback chain handles GNU + BSD"

echo "test_v0_35_0_static_wiring: 8 invariants locked"
