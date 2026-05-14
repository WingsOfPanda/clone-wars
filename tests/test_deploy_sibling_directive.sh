#!/usr/bin/env bash
# tests/test_deploy_sibling_directive.sh — v0.30.0 item 2e
# Locks Step 0's sibling baseline call + Step 4's verify call + AskUserQuestion
# intercept (Revert+replay / Keep / Send-as-bug).
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
DIRECTIVE="$PLUGIN_ROOT/commands/deploy.md"

STEP0=$(awk '/^### Step 0/,/^### Step 1/' "$DIRECTIVE")
STEP4=$(awk '/^### Step 4/,0' "$DIRECTIVE")

# Invariant 1: Step 0 references deploy-sibling-baseline.sh
grep -q 'deploy-sibling-baseline\.sh' <<<"$STEP0" \
  || { echo "FAIL: Step 0 doesn't call bin/deploy-sibling-baseline.sh" >&2; exit 1; }
pass "1. Step 0 calls deploy-sibling-baseline.sh"

# Invariant 2: Step 4 references deploy-sibling-verify.sh
grep -q 'deploy-sibling-verify\.sh' <<<"$STEP4" \
  || { echo "FAIL: Step 4 doesn't call bin/deploy-sibling-verify.sh" >&2; exit 1; }
pass "2. Step 4 calls deploy-sibling-verify.sh"

# Invariant 3: Step 4 references sibling-rogue.txt
grep -q 'sibling-rogue\.txt' <<<"$STEP4" \
  || { echo "FAIL: Step 4 doesn't reference _deploy/sibling-rogue.txt" >&2; exit 1; }
pass "3. Step 4 references sibling-rogue.txt"

# Invariant 4: AskUserQuestion offers Revert + replay
grep -qE 'Revert.+replay|revert.+replay' <<<"$STEP4" \
  || { echo "FAIL: Step 4 missing 'Revert + replay on feat branch' option" >&2; exit 1; }
pass "4. Step 4 offers Revert + replay on feat branch"

# Invariant 5: AskUserQuestion offers Keep on main
grep -qE 'Keep on main|accept.*data' <<<"$STEP4" \
  || { echo "FAIL: Step 4 missing 'Keep on main' option" >&2; exit 1; }
pass "5. Step 4 offers Keep on main"

# Invariant 6: AskUserQuestion offers Send back to trooper
grep -qE 'Send.+trooper|fix-loop bug' <<<"$STEP4" \
  || { echo "FAIL: Step 4 missing 'Send back to trooper' option" >&2; exit 1; }
pass "6. Step 4 offers Send back to trooper as fix-loop bug"

# Invariant 7: directive references sibling-baseline.txt + sibling-rogue-accepted.txt
grep -q 'sibling-baseline\.txt' "$DIRECTIVE" \
  || { echo "FAIL: directive doesn't reference sibling-baseline.txt" >&2; exit 1; }
grep -q 'sibling-rogue-accepted\.txt' "$DIRECTIVE" \
  || { echo "FAIL: directive doesn't reference sibling-rogue-accepted.txt" >&2; exit 1; }
pass "7. directive references sibling-baseline.txt + sibling-rogue-accepted.txt"

echo "test_deploy_sibling_directive: 7 invariants locked"
