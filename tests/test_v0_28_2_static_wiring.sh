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

# Invariant 5: Phase 4.a step 1 writes troopers.txt (atomic tmp+mv per F10)
grep -q '> "\$ART_DIR/troopers.txt.tmp"' "$DIRECTIVE" \
  || { echo "FAIL: directive Phase 4.a does not use atomic tmp+mv for troopers.txt (F10)" >&2; exit 1; }
grep -q 'mv "\$ART_DIR/troopers.txt.tmp" "\$ART_DIR/troopers.txt"' "$DIRECTIVE" \
  || { echo "FAIL: directive Phase 4.a missing mv after tmp write (F10)" >&2; exit 1; }
pass "5. directive Phase 4.a writes troopers.txt via atomic tmp+mv (F10)"

# Invariant 6: Phase 1 steps 3, 4, 6 all stamped UNCONDITIONAL (F2b)
# Count any header that includes "(UNCONDITIONAL" — step 4's header is
# "K=V follow-ups (UNCONDITIONAL when fields are missing — v0.28.2):"
# (no "AskUserQuestion" word). Expect 4 total: P1 step 3, P1 step 4,
# P1 step 6, P2 step 2.
phase1_count=$(grep -cE '\(UNCONDITIONAL' "$DIRECTIVE")
(( phase1_count >= 4 )) \
  || { echo "FAIL: expected >=4 UNCONDITIONAL stamps (Phase 1 steps 3+4+6 + Phase 2 step 2), got $phase1_count" >&2; exit 1; }
grep -q "Initial framing AskUserQuestion (UNCONDITIONAL" "$DIRECTIVE" \
  || { echo "FAIL: Phase 1 step 3 missing UNCONDITIONAL stamp" >&2; exit 1; }
grep -q "K=V follow-ups (UNCONDITIONAL when fields are missing" "$DIRECTIVE" \
  || { echo "FAIL: Phase 1 step 4 missing UNCONDITIONAL stamp" >&2; exit 1; }
grep -q "Final confirmation AskUserQuestion (UNCONDITIONAL" "$DIRECTIVE" \
  || { echo "FAIL: Phase 1 step 6 missing UNCONDITIONAL stamp" >&2; exit 1; }
pass "6. Phase 1 steps 3+4+6 all stamped UNCONDITIONAL (F2b)"

# Invariant 7: resume handler Step 3 split into 3.a + 3.b (F8 code-shaped dedup)
grep -q "### Step 3.a — Process queued notifications" "$RESUME" \
  || { echo "FAIL: resume handler missing Step 3.a header (F8 split)" >&2; exit 1; }
grep -q "### Step 3.b — Render status brief once" "$RESUME" \
  || { echo "FAIL: resume handler missing Step 3.b header (F8 split)" >&2; exit 1; }
grep -q 'RAN_SCORE' "$RESUME" \
  || { echo "FAIL: resume handler missing RAN_SCORE accumulator (F8)" >&2; exit 1; }
pass "7. resume handler Step 3 split into 3.a/3.b with RAN_SCORE accumulator (F8)"

# Invariant 8: Phase 4.a step 5 renders initial brief (F9)
grep -q "Render initial status brief (v0.28.2)" "$DIRECTIVE" \
  || { echo "FAIL: Phase 4.a step 5 missing initial status brief render (F9)" >&2; exit 1; }
pass "8. Phase 4.a step 5 renders initial status brief (F9)"

# Invariant 9: F1 helper present (_cw_dr_approach_from_prompt)
declare -F _cw_dr_approach_from_prompt >/dev/null \
  || { echo "FAIL: _cw_dr_approach_from_prompt not exposed from lib/deep-research.sh (F1)" >&2; exit 1; }
pass "9. _cw_dr_approach_from_prompt helper present (F1 working-trooper approach lookup)"

echo "test_v0_28_2_static_wiring: 9 invariants locked"
