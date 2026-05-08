#!/usr/bin/env bash
# tests/test_consult_step84_drilldown_wiring.sh
# Verifies the drill-deeper step (v0.17.0: Step 13) is wired correctly
# and ordered before teardown (v0.17.0: Step 14).
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

DIR=../commands/consult.md
grep -q '^### Step 13 — Drill deeper' "$DIR" || { echo "FAIL: Step 13 (Drill deeper) header missing" >&2; exit 1; }
grep -q 'drill deeper before tearing'    "$DIR" || { echo "FAIL: Step 13 prompt missing" >&2; exit 1; }
grep -q '_consult/drilldowns'            "$DIR" || { echo "FAIL: Step 13 must use _consult/drilldowns/ path" >&2; exit 1; }
grep -q 'bin/consult-drilldown.sh'       "$DIR" || { echo "FAIL: Step 13 must invoke consult-drilldown.sh" >&2; exit 1; }
grep -q '_scratch/drilldown-'            "$DIR" \
  || { echo "FAIL: Step 13 must reference the actual _scratch/drilldown-* output path" >&2; exit 1; }

# Step 13 (drill) must come BEFORE Step 14 (teardown happens after drill).
LINE_13=$(grep -n '^### Step 13 — Drill deeper' "$DIR" | head -1 | cut -d: -f1)
LINE_14=$(grep -n '^### Step 14 — Teardown' "$DIR" | head -1 | cut -d: -f1)
[[ -n "$LINE_13" && -n "$LINE_14" && "$LINE_13" -lt "$LINE_14" ]] || \
  { echo "FAIL: Step 13 must precede Step 14 (got 13=$LINE_13 14=$LINE_14)" >&2; exit 1; }
pass "Step 13 drilldown wiring complete + ordered before Step 14 teardown"
