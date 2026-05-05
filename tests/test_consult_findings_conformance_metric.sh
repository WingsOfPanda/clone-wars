#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
SYNTH="$PLUGIN_ROOT/bin/consult-synthesize.sh"

# Static-wiring: assert findings-conformance.txt write logic exists.
grep -qE 'findings-conformance\.txt' "$SYNTH" \
  || { echo "FAIL: findings-conformance.txt write missing"; exit 1; }
grep -qE 'cw_consult_findings_active_subproject' "$SYNTH" \
  || { echo "FAIL: synthesize must call cw_consult_findings_active_subproject for conformance check"; exit 1; }
grep -qE 'conformant|non-conformant|n/a' "$SYNTH" \
  || { echo "FAIL: conformance value tokens not present"; exit 1; }
pass "findings-conformance metric wired in bin/consult-synthesize.sh"
