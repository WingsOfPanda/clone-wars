#!/usr/bin/env bash
# tests/test_v0_28_2_static_wiring.sh — v0.28.2 invariant lock.
# Locks the three v0.28.2 directive/lib additions:
#   1. Phase 2 "Time limit" has UNCONDITIONAL fire-guard
#   2. lib/deep-research.sh exposes status_brief + list_commanders helpers
#   3. resume handler Step 3 done-route calls cw_deep_research_render_status_brief
#   4. Phase 4.a step 1 writes troopers.txt (fixes v0.28.0 empty-Status bug)
#   5. plugin.json + marketplace.json on 0.28.x line
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

# v0.28.3+ skip-and-pass guard (mirrors v0.27 lock pattern)
plug_ver=$(awk -F'"' '/"version"/{print $4}' "$PLUGIN_ROOT/.claude-plugin/plugin.json")
case "$plug_ver" in
  0.28.[2-9]|0.28.[1-9][0-9]*) ;;
  0.28.*) pass "v0.28.2 lock skipped — plugin on $plug_ver (pre-v0.28.2)"; exit 0 ;;
  *)      pass "v0.28.2 lock skipped — plugin on $plug_ver (later release)"; exit 0 ;;
esac

# Invariant 1: plugin.json + marketplace.json on 0.28.x line at 0.28.2+
grep -qE '"version"[[:space:]]*:[[:space:]]*"0\.28\.[2-9]"' "$PLUGIN_ROOT/.claude-plugin/plugin.json" \
  || { echo "FAIL: plugin.json version not 0.28.2+" >&2; exit 1; }
count=$(grep -cE '"version"[[:space:]]*:[[:space:]]*"0\.28\.[2-9]"' "$PLUGIN_ROOT/.claude-plugin/marketplace.json")
[[ "$count" == "2" ]] \
  || { echo "FAIL: marketplace.json expected 2 v0.28.2+ fields, got $count" >&2; exit 1; }
pass "1. plugin.json + marketplace.json on 0.28.2+"

# Invariant 2: directive Phase 2 has UNCONDITIONAL guard for time-budget AskUserQuestion
DIRECTIVE="$PLUGIN_ROOT/commands/deep-research.md"
grep -q "Time limit AskUserQuestion (UNCONDITIONAL" "$DIRECTIVE" \
  || { echo "FAIL: directive missing 'UNCONDITIONAL' guard on time-budget AskUserQuestion" >&2; exit 1; }
grep -q "regardless of autonomous-mode hints" "$DIRECTIVE" \
  || { echo "FAIL: directive missing autonomous-mode override language" >&2; exit 1; }
pass "2. directive Phase 2 has UNCONDITIONAL time-budget guard"

# Invariant 3: lib/deep-research.sh exposes status_brief + list_commanders
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"
for fn in cw_deep_research_render_status_brief cw_deep_research_list_commanders; do
  declare -F "$fn" >/dev/null \
    || { echo "FAIL: $fn not exposed from lib/deep-research.sh" >&2; exit 1; }
done
pass "3. lib/deep-research.sh exposes status_brief + list_commanders"

# Invariant 4: resume handler done-route calls cw_deep_research_render_status_brief
RESUME="$PLUGIN_ROOT/commands/deep-research-resume.md"
grep -q "cw_deep_research_render_status_brief" "$RESUME" \
  || { echo "FAIL: resume handler missing status_brief call" >&2; exit 1; }
pass "4. resume handler done-route calls status_brief"

# Invariant 5: Phase 4.a step 1 writes troopers.txt
grep -q 'printf .* > "\$ART_DIR/troopers.txt"' "$DIRECTIVE" \
  || { echo "FAIL: directive Phase 4.a does not write troopers.txt" >&2; exit 1; }
pass "5. directive Phase 4.a writes troopers.txt (fixes v0.28.0 empty-Status bug)"

echo "test_v0_28_2_static_wiring: 5 invariants locked"
