#!/usr/bin/env bash
# tests/test_deploy_scope_directive.sh — v0.30.0 item 4
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
DIRECTIVE="$PLUGIN_ROOT/commands/deploy.md"
STEP4=$(awk '/^### Step 4/,0' "$DIRECTIVE")

# Invariant 1: Step 4 calls cw_deploy_extract_components_paths
grep -q 'cw_deploy_extract_components_paths' <<<"$STEP4" \
  || { echo "FAIL: Step 4 doesn't call cw_deploy_extract_components_paths" >&2; exit 1; }
pass "1. Step 4 calls cw_deploy_extract_components_paths"

# Invariant 2: Step 4 calls cw_deploy_match_diff_against_components
grep -q 'cw_deploy_match_diff_against_components' <<<"$STEP4" \
  || { echo "FAIL: Step 4 doesn't call cw_deploy_match_diff_against_components" >&2; exit 1; }
pass "2. Step 4 calls cw_deploy_match_diff_against_components"

# Invariant 3: Step 4 references scope-out-of-scope.txt
grep -q 'scope-out-of-scope\.txt' <<<"$STEP4" \
  || { echo "FAIL: Step 4 doesn't reference scope-out-of-scope.txt" >&2; exit 1; }
pass "3. Step 4 references scope-out-of-scope.txt"

# Invariant 4: AskUserQuestion offers Accept and amend
grep -qE 'Accept and amend|amend design retroactively' <<<"$STEP4" \
  || { echo "FAIL: Step 4 missing 'Accept and amend' option" >&2; exit 1; }
pass "4. Step 4 offers Accept and amend design retroactively"

# Invariant 5: AskUserQuestion offers Force-keep without amending
grep -qE 'Force-keep without amending|Force-keep' <<<"$STEP4" \
  || { echo "FAIL: Step 4 missing 'Force-keep without amending' option" >&2; exit 1; }
pass "5. Step 4 offers Force-keep without amending"

# Invariant 6: scope-overrides.txt referenced
grep -q 'scope-overrides\.txt' "$DIRECTIVE" \
  || { echo "FAIL: directive doesn't reference scope-overrides.txt" >&2; exit 1; }
pass "6. directive references scope-overrides.txt"

echo "test_deploy_scope_directive: 6 invariants locked"
