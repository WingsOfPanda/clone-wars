#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

DIRECTIVE="$(cd .. && pwd)/commands/consult.md"

grep -q 'cw_consult_findings_active_subproject' "$DIRECTIVE" \
  || { echo "FAIL: active_subproject not referenced in directive"; exit 1; }
# Must be gated on hub mode (not run in single-repo)
grep -qE 'HUB_MODE.*single-repo|hub mode' "$DIRECTIVE" \
  || { echo "FAIL: active_subproject not gated on hub mode"; exit 1; }
grep -qE 'CONTEXT_SLICE|active sub-project' "$DIRECTIVE" \
  || { echo "FAIL: context-slice / active-subproject narrative missing"; exit 1; }
pass "Step 3/5 active-subproject question handler wired"
