#!/usr/bin/env bash
# tests/test_medic_directive_v018_static_wiring.sh
#
# Static-wiring asserts on commands/medic.md: confirms the v0.18.0
# directive contains Steps A-G (interactive trooper selection),
# references providers-active.txt + providers-available.txt + Write
# tool + AskUserQuestion, and documents the stale-entry filter.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

DIR=../commands/medic.md
BODY=$(cat "$DIR")

# Step labels A-G must all appear.
for s in A B C D E F G; do
  grep -qE "^#### Step $s —" "$DIR" \
    || { echo "FAIL: missing '#### Step $s —' heading" >&2; exit 1; }
done

# Required references inside the new selection block.
assert_contains "$BODY" "providers-active.txt"  "directive references providers-active.txt"
assert_contains "$BODY" "providers-available.txt" "directive references providers-available.txt"
assert_contains "$BODY" "AskUserQuestion"        "directive uses AskUserQuestion"
assert_contains "$BODY" "Write tool"             "directive uses Write tool for atomic write"

# Stale-entry handling must be explicitly documented.
assert_contains "$BODY" "no longer detected"     "directive documents stale-entry filter"

# Empty-set guard must be explicit (Step F).
assert_contains "$BODY" "must select at least one provider" "directive documents empty-set guard"

# Auto-handle for N=0 and N=1 must be explicit (Step C).
assert_contains "$BODY" "auto-selected" "directive auto-handles N=1"

# Customize fallback path must exist for N=4.
assert_contains "$BODY" "Customize" "directive offers Customize fallback"

# v0.18.1: N=3 menu must use 2-step nested pattern (AskUserQuestion caps
# at 4 options, so a flat 5-option menu is unimplementable). Lock in the
# Step D.1 / D.2 structure.
assert_contains "$BODY" "Step D.1" "N=3 uses Step D.1 high-level question"
assert_contains "$BODY" "Step D.2" "N=3 has Step D.2 pair-drill question"
assert_contains "$BODY" "Pick a pair" "Step D.1 offers Pick a pair drill option"
# Negative: directive must NOT claim a flat 5-option menu for N=3.
! grep -qE 'For \*\*N=3\*\*.*5 options' "$DIR" \
  || { echo "FAIL: directive still claims flat 5-option menu for N=3" >&2; exit 1; }

pass "commands/medic.md v0.18.1 static wiring complete"
