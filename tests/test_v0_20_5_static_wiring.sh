#!/usr/bin/env bash
# tests/test_v0_20_5_static_wiring.sh
# Locks v0.20.5 commander swap: opencode → wolffe (replaces bly).
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"

# 1. lib/consult.sh canonical mapping is opencode → wolffe.
CONSULT="$PLUGIN_ROOT/lib/consult.sh"
grep -qE 'opencode\)[[:space:]]+echo[[:space:]]+wolffe' "$CONSULT" \
  || { echo "FAIL: cw_consult_provider_to_commander missing 'opencode → wolffe' branch" >&2; exit 1; }
! grep -qE 'opencode\)[[:space:]]+echo[[:space:]]+bly' "$CONSULT" \
  || { echo "FAIL: cw_consult_provider_to_commander still maps opencode → bly" >&2; exit 1; }
pass "cw_consult_provider_to_commander: opencode → wolffe (not bly)"

# 2. commands/consult.md canonical N=3 examples reference wolffe, not bly.
CONSULT_MD="$PLUGIN_ROOT/commands/consult.md"
! grep -qE 'opencode/bly\b' "$CONSULT_MD" \
  || { echo "FAIL: consult.md still has 'opencode/bly' canonical pairing" >&2; exit 1; }
grep -qE 'opencode/wolffe\b' "$CONSULT_MD" \
  || { echo "FAIL: consult.md missing 'opencode/wolffe' canonical pairing" >&2; exit 1; }
pass "consult.md canonical N=3 example uses opencode/wolffe"

# 3. wolffe color is purple (Wolfpack blue-grey/violet) per lib/colors.sh.
COLORS="$PLUGIN_ROOT/lib/colors.sh"
grep -qE 'wolffe\)[[:space:]]+printf[[:space:]]+'"'"'colour104 colour174' "$COLORS" \
  || { echo "FAIL: wolffe color not 'colour104 colour174' (purple/Wolfpack periwinkle)" >&2; exit 1; }
pass "wolffe color = colour104 colour174 (Wolfpack blue-grey/violet)"

# 4. bly remains in the legacy commander pool + colors (canonical-mapping-only swap).
grep -qE '^[[:space:]]*-[[:space:]]+bly\b' "$PLUGIN_ROOT/config/commanders.yaml" \
  || { echo "FAIL: bly removed from commanders.yaml pool (this PR was canonical-mapping-only)" >&2; exit 1; }
grep -qE '^[[:space:]]*bly\)[[:space:]]+printf' "$COLORS" \
  || { echo "FAIL: bly color row removed from lib/colors.sh (this PR was canonical-mapping-only)" >&2; exit 1; }
pass "bly retained as legacy commander (canonical-mapping-only swap; archived state still labels)"

# 5. plugin.json version bumped (semver-shape regex).
PJ="$PLUGIN_ROOT/.claude-plugin/plugin.json"
grep -qE '"version": "0\.20\.5"' "$PJ" \
  || { echo "FAIL: plugin.json version is not exactly 0.20.5" >&2; exit 1; }
pass "plugin.json version bumped to 0.20.5"

pass "v0.20.5 static wiring complete (5 invariants locked)"
