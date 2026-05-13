#!/usr/bin/env bash
# tests/test_v0_28_0_static_wiring.sh — v0.28.0 invariant lock
# Never edit — adjust at v0.29.0 by creating a new static-wiring test.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

# Invariant 1: plugin.json on 0.28.x
grep -qE '"version"[[:space:]]*:[[:space:]]*"0\.28\.[0-9]+"' "$PLUGIN_ROOT/.claude-plugin/plugin.json" \
  || { echo "FAIL: plugin.json not on 0.28.x" >&2; exit 1; }
pass "1. plugin.json version on 0.28.x"

# Invariant 2: marketplace.json has 2 v0.28.x fields
count=$(grep -cE '"version"[[:space:]]*:[[:space:]]*"0\.28\.[0-9]+"' "$PLUGIN_ROOT/.claude-plugin/marketplace.json")
[[ "$count" == "2" ]] \
  || { echo "FAIL: marketplace.json expected 2 v0.28.x fields, got $count" >&2; exit 1; }
pass "2. marketplace.json has 2 v0.28.x version fields"

# Invariant 3: deep-research bin script set (monitor + finalize added; experiment-wait removed)
required=(deep-research-init deep-research-experiment-send deep-research-score \
          deep-research-teardown deep-research-monitor deep-research-finalize)
for s in "${required[@]}"; do
  [[ -x "$PLUGIN_ROOT/bin/$s.sh" ]] \
    || { echo "FAIL: bin/$s.sh missing or not executable" >&2; exit 1; }
done
[[ ! -f "$PLUGIN_ROOT/bin/deep-research-experiment-wait.sh" ]] \
  || { echo "FAIL: bin/deep-research-experiment-wait.sh should be removed in v0.28.0" >&2; exit 1; }
pass "3. v0.28.0 bin script set (monitor + finalize added, experiment-wait removed)"

# Invariant 4: lib/deep-research.sh exposes new helpers
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/commanders.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"
for fn in \
  cw_deep_research_trooper_state_read \
  cw_deep_research_trooper_state_write \
  cw_deep_research_check_completion \
  cw_deep_research_render_summary \
  cw_deep_research_check_plateau; do
  declare -F "$fn" >/dev/null \
    || { echo "FAIL: $fn not defined" >&2; exit 1; }
done
pass "4. lib/deep-research.sh exposes v0.28.0 helpers"

# Invariant 5: old name check_stagnation removed (renamed to check_plateau in T2)
if declare -F cw_deep_research_check_stagnation >/dev/null; then
  echo "FAIL: cw_deep_research_check_stagnation should be removed (renamed)" >&2; exit 1
fi
pass "5. cw_deep_research_check_stagnation removed (renamed to _check_plateau)"

# Invariant 6: experiment.md template contains heartbeat instruction
TEMPLATE="$PLUGIN_ROOT/config/prompt-templates/deep-research/experiment.md"
grep -q 'heartbeat' "$TEMPLATE" \
  || { echo "FAIL: experiment.md missing heartbeat instruction" >&2; exit 1; }
pass "6. experiment.md template has heartbeat instruction"

# Invariant 7: UserPromptSubmit hook installed + executable
[[ -x "$PLUGIN_ROOT/hooks/user-prompt-submit-active-session.sh" ]] \
  || { echo "FAIL: UserPromptSubmit hook missing or not executable" >&2; exit 1; }
pass "7. UserPromptSubmit hook installed + executable"

# Invariant 8: plugin.json registers UserPromptSubmit hook
grep -q '"UserPromptSubmit"' "$PLUGIN_ROOT/.claude-plugin/plugin.json" \
  || { echo "FAIL: plugin.json doesn't register UserPromptSubmit hook" >&2; exit 1; }
grep -q 'user-prompt-submit-active-session' "$PLUGIN_ROOT/.claude-plugin/plugin.json" \
  || { echo "FAIL: plugin.json doesn't reference hook script" >&2; exit 1; }
pass "8. plugin.json registers UserPromptSubmit hook"

# Invariant 9: commands/deep-research-resume.md exists with handler 3.b sections
RESUME="$PLUGIN_ROOT/commands/deep-research-resume.md"
[[ -f "$RESUME" ]] || { echo "FAIL: $RESUME missing" >&2; exit 1; }
for marker in \
  "Step 1 — Read state baseline" \
  "Step 2 — Hard-cap check" \
  "Step 3 — Process queued notifications" \
  "Step 4 — Completion check" \
  "Step 5 — Dispatch round" \
  "Step 6 — Handle user message" \
  "Step 7 — Update session-summary.md"; do
  grep -q "$marker" "$RESUME" \
    || { echo "FAIL: $RESUME missing '$marker'" >&2; exit 1; }
done
pass "9. commands/deep-research-resume.md has all 7 handler steps"

# Invariant 10: directive Phase 4 references 4.a + monitor + per-trooper schema
DIRECTIVE="$PLUGIN_ROOT/commands/deep-research.md"
grep -q '4\.a' "$DIRECTIVE" \
  || { echo "FAIL: directive Phase 4 missing 4.a structure" >&2; exit 1; }
grep -q 'deep-research-monitor.sh' "$DIRECTIVE" \
  || { echo "FAIL: directive doesn't reference monitor script" >&2; exit 1; }
grep -qE 'troopers/<cmdr>|troopers/[^/]*/state\.txt|troopers/[^/]*/experiments' "$DIRECTIVE" \
  || { echo "FAIL: directive doesn't reference per-trooper state schema" >&2; exit 1; }
pass "10. directive Phase 4 references 4.a + monitor + per-trooper state"

# Invariant 11: directive does NOT reference deleted experiment-wait
if grep -q 'deep-research-experiment-wait' "$DIRECTIVE"; then
  echo "FAIL: directive still references deleted experiment-wait" >&2; exit 1
fi
pass "11. directive doesn't reference deleted experiment-wait"

# Invariant 12: CLAUDE.md has v0.28.0 status + release-gate rows
grep -q "v0.28.0:" "$PLUGIN_ROOT/CLAUDE.md" \
  || { echo "FAIL: CLAUDE.md missing v0.28.0 status row" >&2; exit 1; }
grep -q "v0.28.0 strict-dogfood" "$PLUGIN_ROOT/CLAUDE.md" \
  || { echo "FAIL: CLAUDE.md missing v0.28.0 release-gate row" >&2; exit 1; }
pass "12. CLAUDE.md has v0.28.0 status + release-gate rows"

# Invariant 13: metric.md schema supports new fields (test format helper)
OUT=$(cw_deep_research_format_metric_block <<'EOF'
primary_metric=accuracy
direction=maximize
min_acceptable=>= 0.90
target=>= 0.99
K_corroboration=2
EOF
)
for field in min_acceptable target K_corroboration plateau_window plateau_threshold; do
  grep -q "$field" <<<"$OUT" \
    || { echo "FAIL: format helper missing field $field" >&2; exit 1; }
done
pass "13. metric.md format helper emits all v0.28.0 fields"

# Invariant 14: completion check produces all 5 signal fields
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/sb.md" <<'EOF'
# Scoreboard

| Rank | Experiment | Commander | Metric | Status | Runtime | Approach |
|---|---|---|---|---|---|---|
| 1 | exp-001 | rex | 0.99 | ok | 100 | a |
EOF
cat > "$TMP/m.md" <<'EOF'
**Primary metric:** accuracy
**Direction:** maximize
**min_acceptable:** >= 0.90
**target:** >= 0.99
**K_corroboration:** 1
**plateau_window:** 5
**plateau_threshold:** 0.01
EOF
SIG=$(cw_deep_research_check_completion "$TMP/sb.md" "$TMP/m.md")
for field in floor_met target_met K_so_far K_required plateau; do
  grep -q "^$field=" <<<"$SIG" \
    || { echo "FAIL: check_completion missing field $field" >&2; exit 1; }
done
pass "14. check_completion emits all 5 signal fields"

# Invariant 15: monitor + finalize have correct shebangs
for s in deep-research-monitor deep-research-finalize; do
  head -1 "$PLUGIN_ROOT/bin/$s.sh" | grep -q '^#!/usr/bin/env bash' \
    || { echo "FAIL: bin/$s.sh shebang wrong" >&2; exit 1; }
done
pass "15. monitor + finalize have correct shebang"

echo "test_v0_28_0_static_wiring: 15 invariants locked"
