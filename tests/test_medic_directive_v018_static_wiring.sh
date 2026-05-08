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

# v0.18.2: review-polish patches.
# Frontmatter must list AskUserQuestion (Steps D and E require it).
grep -qE '^allowed-tools:.*AskUserQuestion' "$DIR" \
  || { echo "FAIL: frontmatter allowed-tools missing AskUserQuestion" >&2; exit 1; }

# A one-line preamble must distinguish bash-wrapper (1–6) from Claude-side (A–G).
assert_contains "$BODY" "bash wrapper" "directive distinguishes bash wrapper"
assert_contains "$BODY" "Claude-side interactive" "directive labels Claude-side flow"

# Trigger-phrase examples must be present so future-Claude can route users
# to /clone-wars:medic from natural-language requests.
assert_contains "$BODY" "Trigger phrases" "directive lists trigger phrases"
assert_contains "$BODY" "switch consult roster" "directive includes 'switch consult roster' trigger"

# FAIL-verdict carve-out must be documented (Steps A–G run on FAIL too,
# as long as providers-available.txt has ≥1 entry).
grep -qE 'verdict is `?FAIL`?' "$DIR" \
  || { echo "FAIL: directive does not document FAIL-verdict behavior for Steps A–G" >&2; exit 1; }

# Negative: drift-prone line-number cite must be gone.
! grep -qE 'lib/consult\.sh:[0-9]+' "$DIR" \
  || { echo "FAIL: directive still cites lib/consult.sh with a line number (drift-prone)" >&2; exit 1; }

# Negative: pre-v0.0.6 stub-message parenthetical must be gone.
! grep -qE 'spawn\.sh.*stub messages|print[s]? stub messages' "$DIR" \
  || { echo "FAIL: stale 'print stub messages' parenthetical still present in Step 6" >&2; exit 1; }

pass "commands/medic.md v0.18.2 static wiring complete"
