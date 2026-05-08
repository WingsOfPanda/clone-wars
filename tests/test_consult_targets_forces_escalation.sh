#!/usr/bin/env bash
# tests/test_consult_targets_forces_escalation.sh
#
# Static asserts that commands/consult.md's Step 2 routing logic treats
# --targets as an escalation signal (forces the escalated path even when
# no signals fire). Validated by reading the directive prose.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

DIR=../commands/consult.md

# Extract Step 2 block (between "### Step 2 —" and "### Step 3 —").
STEP2_BLOCK=$(awk '/^### Step 2 —/,/^### Step 3 —/' "$DIR")

# The Step 2 routing block must list --targets as a fast-path-disqualifier.
echo "$STEP2_BLOCK" | grep -qE '\-\-targets' \
  || { echo "FAIL: Step 2 doesn't mention --targets in routing logic" >&2; echo "Step 2 block:" >&2; echo "$STEP2_BLOCK" >&2; exit 1; }

# Step 2 should mention "escalat" (escalation/escalated) somewhere.
assert_contains "$STEP2_BLOCK" "escalat" "Step 2 mentions escalation"

# Routing rule must explicitly tag --targets as escalation signal (look
# for either "escalation signal" near --targets or the --targets line in
# a routing-rules list).
echo "$STEP2_BLOCK" | grep -qE '\-\-targets.*(escalation|escalated path)|escalation signal' \
  || { echo "FAIL: Step 2 doesn't tag --targets as an escalation signal" >&2; echo "Step 2 block:" >&2; echo "$STEP2_BLOCK" >&2; exit 1; }

pass "commands/consult.md Step 2 treats --targets as escalation signal"
