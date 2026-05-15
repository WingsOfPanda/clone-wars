#!/usr/bin/env bash
# tests/test_v0_32_0_static_wiring.sh
# Version-stamped invariant lock for v0.32.0. Skips with PASS when the
# plugin version != 0.32.0 so future versions don't re-fire this lock.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"

# Skip-guard: only enforce when plugin version is 0.32.0
PV=$(grep -E '^  "version":' "$PLUGIN_ROOT/.claude-plugin/plugin.json" \
  | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')

if [[ "$PV" != "0.32.0" ]]; then
  pass "skip — plugin version $PV ≠ 0.32.0"
  exit 0
fi

# --- Invariant 1: plugin.json reports 0.32.0 ---
assert_eq "$PV" "0.32.0" "invariant 1: plugin.json version"
pass "1. plugin.json reads 0.32.0"

# --- Invariant 2: bin/deep-research-monitor.sh sources lib/deep-research.sh ---
grep -q 'source "$PLUGIN_ROOT/lib/deep-research.sh"' "$PLUGIN_ROOT/bin/deep-research-monitor.sh" \
  || { echo "FAIL: invariant 2: monitor doesn't source lib/deep-research.sh" >&2; exit 1; }
pass "2. monitor sources lib/deep-research.sh"

# --- Invariant 3: monitor calls cw_deep_research_trooper_state_field ---
grep -q 'cw_deep_research_trooper_state_field' "$PLUGIN_ROOT/bin/deep-research-monitor.sh" \
  || { echo "FAIL: invariant 3: monitor missing phase-field call" >&2; exit 1; }
pass "3. monitor calls cw_deep_research_trooper_state_field"

# --- Invariant 4: monitor references CW_DEEP_RESEARCH_RESCAN_EVERY_S ---
grep -q 'CW_DEEP_RESEARCH_RESCAN_EVERY_S' "$PLUGIN_ROOT/bin/deep-research-monitor.sh" \
  || { echo "FAIL: invariant 4: monitor missing rescan env var" >&2; exit 1; }
pass "4. monitor references CW_DEEP_RESEARCH_RESCAN_EVERY_S"

# --- Invariant 5: monitor defaults PROBE_S=900 + STUCK_S=1800 ---
grep -q '${CW_DEEP_RESEARCH_PROBE_S:-900}' "$PLUGIN_ROOT/bin/deep-research-monitor.sh" \
  || { echo "FAIL: invariant 5: PROBE_S default not 900" >&2; exit 1; }
grep -q '${CW_DEEP_RESEARCH_STUCK_S:-1800}' "$PLUGIN_ROOT/bin/deep-research-monitor.sh" \
  || { echo "FAIL: invariant 5: STUCK_S default not 1800" >&2; exit 1; }
pass "5. monitor defaults PROBE_S=900, STUCK_S=1800"

# --- Invariant 6: experiment-send.sh has auto-prefix; legacy fatal-error is gone ---
grep -q 'TOPIC="deep-research-$TOPIC"' "$PLUGIN_ROOT/bin/deep-research-experiment-send.sh" \
  || { echo "FAIL: invariant 6: auto-prefix line missing" >&2; exit 1; }
if grep -qE "log_error \"topic must start with 'deep-research-'" "$PLUGIN_ROOT/bin/deep-research-experiment-send.sh"; then
  echo "FAIL: invariant 6: legacy 'topic must start with' fatal-error string still present" >&2
  exit 1
fi
pass "6. experiment-send.sh auto-prefixes (legacy fatal removed)"

# --- Invariant 7: deep-research-init.sh parses --time-budget AND --metric ---
grep -q '\-\-time-budget' "$PLUGIN_ROOT/bin/deep-research-init.sh" \
  || { echo "FAIL: invariant 7a: --time-budget parser missing" >&2; exit 1; }
grep -q '\-\-metric' "$PLUGIN_ROOT/bin/deep-research-init.sh" \
  || { echo "FAIL: invariant 7b: --metric parser missing" >&2; exit 1; }
pass "7. deep-research-init.sh parses --time-budget and --metric"

# --- Invariant 8: bin/deep-research-abort.sh exists + executable ---
assert_file_exists "$PLUGIN_ROOT/bin/deep-research-abort.sh" "invariant 8: abort script exists"
[[ -x "$PLUGIN_ROOT/bin/deep-research-abort.sh" ]] \
  || { echo "FAIL: invariant 8: abort script not executable" >&2; exit 1; }
pass "8. bin/deep-research-abort.sh exists + executable"

# --- Invariant 9: deep-research.md Phase 1 step 3 has both UNCONDITIONAL and Skip clauses ---
phase1_step3=$(awk '
  /^3\. \*\*Initial framing AskUserQuestion/ { in_block=1 }
  in_block { print }
  in_block && /^4\.[[:space:]]/ { exit }
' "$PLUGIN_ROOT/commands/deep-research.md")
[[ "$phase1_step3" == *"UNCONDITIONAL"* ]] \
  || { echo "FAIL: invariant 9a: Phase 1 step 3 missing 'UNCONDITIONAL'" >&2; exit 1; }
[[ "$phase1_step3" == *"Skip this AskUserQuestion if"* ]] \
  || { echo "FAIL: invariant 9b: Phase 1 step 3 missing 'Skip this AskUserQuestion if' clause" >&2; exit 1; }
pass "9. Phase 1 step 3 has both UNCONDITIONAL and Skip clauses"

# --- Invariant 10: deep-research.md Phase 2 step 2 has both UNCONDITIONAL and Skip clauses ---
phase2_step2=$(awk '
  /^2\. \*\*Time limit AskUserQuestion/ { in_block=1 }
  in_block { print }
  in_block && /^3\.[[:space:]]/ { exit }
' "$PLUGIN_ROOT/commands/deep-research.md")
[[ "$phase2_step2" == *"UNCONDITIONAL"* ]] \
  || { echo "FAIL: invariant 10a: Phase 2 step 2 missing 'UNCONDITIONAL'" >&2; exit 1; }
[[ "$phase2_step2" == *"Skip this AskUserQuestion if"* ]] \
  || { echo "FAIL: invariant 10b: Phase 2 step 2 missing 'Skip this AskUserQuestion if' clause" >&2; exit 1; }
pass "10. Phase 2 step 2 has both UNCONDITIONAL and Skip clauses"

echo "test_v0_32_0_static_wiring: 10 invariants locked"
