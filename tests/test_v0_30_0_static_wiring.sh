#!/usr/bin/env bash
# tests/test_v0_30_0_static_wiring.sh — v0.30.0 invariant lock
# Never edit — adjust at v0.31.0 by creating a new static-wiring test.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

# v0.31.0+ guard: skip if plugin moves on.
plug_ver=$(awk -F'"' '/"version"/{print $4}' "$PLUGIN_ROOT/.claude-plugin/plugin.json")
case "$plug_ver" in
  0.30.*) ;;
  *)
    pass "v0.30.0 lock skipped — plugin on $plug_ver"
    exit 0
    ;;
esac

# Invariant 1: plugin.json on 0.30.x
grep -qE '"version"[[:space:]]*:[[:space:]]*"0\.30\.[0-9]+"' "$PLUGIN_ROOT/.claude-plugin/plugin.json" \
  || { echo "FAIL: plugin.json not on 0.30.x" >&2; exit 1; }
pass "1. plugin.json version on 0.30.x"

# Invariant 2: marketplace.json has 2 v0.30.x fields
count=$(grep -cE '"version"[[:space:]]*:[[:space:]]*"0\.30\.[0-9]+"' "$PLUGIN_ROOT/.claude-plugin/marketplace.json")
[[ "$count" == "2" ]] \
  || { echo "FAIL: marketplace.json expected 2 v0.30.x fields, got $count" >&2; exit 1; }
pass "2. marketplace.json has 2 v0.30.x version fields"

# Invariant 3: Item 1 — Step 10 references adjudicated.md
grep -q 'adjudicated\.md' "$PLUGIN_ROOT/commands/consult.md" \
  || { echo "FAIL: consult.md doesn't reference adjudicated.md (item 1)" >&2; exit 1; }
pass "3. consult.md Step 10 references adjudicated.md (item 1 corpus swap)"

# Invariant 4: Item 3 — bin/deploy-init.sh contains exit 7 literal
grep -qE 'exit[[:space:]]+7' "$PLUGIN_ROOT/bin/deploy-init.sh" \
  || { echo "FAIL: bin/deploy-init.sh missing 'exit 7' literal (item 3)" >&2; exit 1; }
pass "4. bin/deploy-init.sh has exit 7 literal (item 3 dirty-tree rc)"

# Invariant 5: Item 3 — lib/deploy.sh contains return 7
grep -qE 'return[[:space:]]+7' "$PLUGIN_ROOT/lib/deploy.sh" \
  || { echo "FAIL: lib/deploy.sh missing 'return 7' (item 3)" >&2; exit 1; }
pass "5. lib/deploy.sh has return 7 (item 3 dirty-tree branch_create rc)"

# Invariant 6: Item 2 — bin scripts present and executable
for s in deploy-sibling-baseline deploy-sibling-verify; do
  [[ -x "$PLUGIN_ROOT/bin/$s.sh" ]] \
    || { echo "FAIL: bin/$s.sh missing or not executable" >&2; exit 1; }
done
pass "6. item 2 bin scripts present + executable"

# Invariant 7: Item 2 — lib/deploy-sibling.sh exposes all 4 helpers
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/deploy-sibling.sh"
for fn in cw_deploy_enumerate_siblings cw_deploy_capture_sibling_baseline \
          cw_deploy_diff_sibling_against_baseline cw_deploy_revert_and_replay; do
  declare -F "$fn" >/dev/null \
    || { echo "FAIL: $fn not defined (item 2)" >&2; exit 1; }
done
pass "7. item 2 lib helpers all defined"

# Invariant 8: Item 4 — lib/deploy-scope.sh exposes parser + matcher
source "$PLUGIN_ROOT/lib/deploy-scope.sh"
for fn in cw_deploy_extract_components_paths cw_deploy_match_diff_against_components; do
  declare -F "$fn" >/dev/null \
    || { echo "FAIL: $fn not defined (item 4)" >&2; exit 1; }
done
pass "8. item 4 lib helpers defined"

# Invariant 9: Step 0 has rc=7 intercept block (item 3)
DIRECTIVE="$PLUGIN_ROOT/commands/deploy.md"
STEP0=$(awk '/^### Step 0/,/^### Step 1/' "$DIRECTIVE")
grep -qE 'INIT_RC.*7|rc=7|exit[[:space:]]+7' <<<"$STEP0" \
  || { echo "FAIL: deploy.md Step 0 missing rc=7 intercept" >&2; exit 1; }
pass "9. deploy.md Step 0 references rc=7 intercept"

# Invariant 10: Step 0 references sibling-baseline.sh (item 2)
grep -q 'deploy-sibling-baseline\.sh' <<<"$STEP0" \
  || { echo "FAIL: deploy.md Step 0 missing sibling-baseline.sh call" >&2; exit 1; }
pass "10. deploy.md Step 0 calls deploy-sibling-baseline.sh"

# Invariant 11: Step 4 references all v0.30.0 state files (items 2+3+4)
for f in pre-deploy-stash sibling-rogue scope-out-of-scope; do
  grep -q "$f" "$DIRECTIVE" \
    || { echo "FAIL: deploy.md doesn't reference $f.txt" >&2; exit 1; }
done
pass "11. deploy.md references all v0.30.0 state files"

# Invariant 12: CLAUDE.md has v0.30.0 status row + release-gate row
grep -q "v0\.30\.0:" "$PLUGIN_ROOT/CLAUDE.md" \
  || { echo "FAIL: CLAUDE.md missing v0.30.0 status row" >&2; exit 1; }
grep -q "v0\.30\.0 strict-dogfood" "$PLUGIN_ROOT/CLAUDE.md" \
  || { echo "FAIL: CLAUDE.md missing v0.30.0 release-gate row" >&2; exit 1; }
pass "12. CLAUDE.md has v0.30.0 status + release-gate rows"

echo "test_v0_30_0_static_wiring: 12 invariants locked"
