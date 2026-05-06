#!/usr/bin/env bash
# tests/test_consult_directive_hub_mode.sh — static-wiring assertions
# for the v0.11 hub-mode wiring in commands/consult.md.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

DIRECTIVE="$(cd .. && pwd)/commands/consult.md"

# Step 0.5 wiring: detect_hub call + hub-mode.txt mention
grep -q 'cw_consult_detect_hub' "$DIRECTIVE" \
  || { echo "FAIL: directive must call cw_consult_detect_hub"; exit 1; }
grep -q 'hub-mode.txt' "$DIRECTIVE" \
  || { echo "FAIL: directive must reference hub-mode.txt"; exit 1; }
pass "Step 0.5: detect_hub + hub-mode.txt referenced"

# Step 1.5 / Step 2 prelude: target selection + TARGETS threading
grep -q 'cw_consult_targets_persist\|targets.txt' "$DIRECTIVE" \
  || { echo "FAIL: Step 1.5 must persist targets.txt"; exit 1; }
grep -q 'CW_CONSULT_TARGETS=' "$DIRECTIVE" \
  || { echo "FAIL: Step 2 must thread CW_CONSULT_TARGETS= into research-send"; exit 1; }
pass "Step 1.5/2: target-selection AskUserQuestion + TARGETS threading"

echo "ALL: ok"
