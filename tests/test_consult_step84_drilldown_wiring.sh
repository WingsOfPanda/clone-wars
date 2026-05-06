#!/usr/bin/env bash
# tests/test_consult_step84_drilldown_wiring.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

DIR=../commands/consult.md
grep -q '^### Step 8.4'                  "$DIR" || { echo "FAIL: Step 8.4 header missing" >&2; exit 1; }
grep -q 'drill deeper before tearing'    "$DIR" || { echo "FAIL: Step 8.4 prompt missing" >&2; exit 1; }
grep -q '_consult/drilldowns'            "$DIR" || { echo "FAIL: Step 8.4 must use _consult/drilldowns/ path" >&2; exit 1; }
grep -q 'bin/consult-drilldown.sh'       "$DIR" || { echo "FAIL: Step 8.4 must invoke consult-drilldown.sh" >&2; exit 1; }

# Step 8.4 must come BEFORE Step 9 (teardown happens after drill).
LINE_84=$(grep -n '^### Step 8.4' "$DIR" | head -1 | cut -d: -f1)
LINE_9=$(grep -n '^### Step 9' "$DIR" | head -1 | cut -d: -f1)
[[ -n "$LINE_84" && -n "$LINE_9" && "$LINE_84" -lt "$LINE_9" ]] || \
  { echo "FAIL: Step 8.4 must precede Step 9 (got 8.4=$LINE_84 9=$LINE_9)" >&2; exit 1; }
pass "Step 8.4 drilldown wiring complete + ordered before teardown"
