#!/usr/bin/env bash
# tests/test_v0_33_0_static_wiring.sh
# Version-stamped invariant lock for v0.33.0. Skips with PASS when the
# plugin version != 0.33.0 so future versions don't re-fire this lock.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"

PV=$(grep -E '^  "version":' "$PLUGIN_ROOT/.claude-plugin/plugin.json" \
  | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')

if [[ "$PV" != "0.33.0" ]]; then
  pass "skip — plugin version $PV ≠ 0.33.0"
  exit 0
fi

# --- Invariant 1: plugin.json reports 0.33.0 ---
assert_eq "$PV" "0.33.0" "invariant 1: plugin.json version"
pass "1. plugin.json reads 0.33.0"

# --- Invariant 2: cw_deep_research_validate_result_json_v033 defined ---
grep -q 'cw_deep_research_validate_result_json_v033()' "$PLUGIN_ROOT/lib/deep-research.sh" \
  || { echo "FAIL: invariant 2: v033 validator missing from lib/deep-research.sh" >&2; exit 1; }
pass "2. cw_deep_research_validate_result_json_v033 defined in lib/deep-research.sh"

# --- Invariant 3: score.sh calls the v033 validator ---
grep -q 'cw_deep_research_validate_result_json_v033' "$PLUGIN_ROOT/bin/deep-research-score.sh" \
  || { echo "FAIL: invariant 3: score.sh doesn't call v033 validator" >&2; exit 1; }
pass "3. bin/deep-research-score.sh calls cw_deep_research_validate_result_json_v033"

# --- Invariant 4: score.sh writes result-validation.txt ---
grep -q 'result-validation.txt' "$PLUGIN_ROOT/bin/deep-research-score.sh" \
  || { echo "FAIL: invariant 4: score.sh doesn't write result-validation.txt" >&2; exit 1; }
pass "4. bin/deep-research-score.sh writes result-validation.txt"

# --- Invariant 5: check_completion reads metric.md's primary_metric ---
grep -qE '\*\*Primary metric:' "$PLUGIN_ROOT/lib/deep-research.sh" \
  || { echo "FAIL: invariant 5a: lib/deep-research.sh missing Primary metric parse" >&2; exit 1; }
grep -q 'primary_metric' "$PLUGIN_ROOT/lib/deep-research.sh" \
  || { echo "FAIL: invariant 5b: lib/deep-research.sh missing primary_metric var" >&2; exit 1; }
pass "5. check_completion reads metric.md primary_metric"

# --- Invariant 6: bin/deep-research-consensus.sh exists + executable ---
assert_file_exists "$PLUGIN_ROOT/bin/deep-research-consensus.sh" \
  "invariant 6: consensus script exists"
[[ -x "$PLUGIN_ROOT/bin/deep-research-consensus.sh" ]] \
  || { echo "FAIL: invariant 6: consensus script not executable" >&2; exit 1; }
pass "6. bin/deep-research-consensus.sh exists + executable"

# --- Invariant 7: bin/send.sh references state.txt + mid-experiment warning ---
grep -q 'state.txt' "$PLUGIN_ROOT/bin/send.sh" \
  || { echo "FAIL: invariant 7a: bin/send.sh missing state.txt probe" >&2; exit 1; }
grep -q 'mid-experiment' "$PLUGIN_ROOT/bin/send.sh" \
  || { echo "FAIL: invariant 7b: bin/send.sh missing mid-experiment warning literal" >&2; exit 1; }
pass "7. bin/send.sh has state.txt probe + mid-experiment warning"

# --- Invariant 8: experiment.md documents self_reported_* fields ---
for f in self_reported_count self_reported_ratio self_reported_notes; do
  grep -q "$f" "$PLUGIN_ROOT/config/prompt-templates/deep-research/experiment.md" \
    || { echo "FAIL: invariant 8: experiment.md missing $f" >&2; exit 1; }
done
pass "8. experiment.md documents self_reported_count/ratio/notes"

# --- Invariant 9: experiment.md mentions result-validation.txt ---
grep -q 'result-validation.txt' "$PLUGIN_ROOT/config/prompt-templates/deep-research/experiment.md" \
  || { echo "FAIL: invariant 9: experiment.md missing result-validation.txt reference" >&2; exit 1; }
pass "9. experiment.md mentions result-validation.txt"

# --- Invariant 10: CLAUDE.md has v0.33.0 status row + release-gate row ---
grep -q '^- \[x\] v0.33.0' "$PLUGIN_ROOT/CLAUDE.md" \
  || { echo "FAIL: invariant 10a: CLAUDE.md missing v0.33.0 done row" >&2; exit 1; }
grep -q '^- \[ \] v0.33.0 strict-dogfood' "$PLUGIN_ROOT/CLAUDE.md" \
  || { echo "FAIL: invariant 10b: CLAUDE.md missing v0.33.0 release-gate row" >&2; exit 1; }
pass "10. CLAUDE.md has v0.33.0 status + release-gate rows"

echo "test_v0_33_0_static_wiring: 10 invariants locked"
