#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
DRILL="$PLUGIN_ROOT/bin/consult-drilldown.sh"

# This test asserts the collision-counter LOGIC by inspecting bin source —
# end-to-end test would require trooper spawn. Static-wiring style:
grep -qE 'while \[\[ -e "\$OUT_PATH" \]\]; do' "$DRILL" \
  || { echo "FAIL: collision-counter while loop missing"; exit 1; }
grep -qE 'OUT_PATH=.*-\$\{?n\}?\.md' "$DRILL" \
  || grep -qE 'OUT_PATH="\$\{base\}-\$\{?n\}?\.md"' "$DRILL" \
  || { echo "FAIL: -N suffix substitution missing"; exit 1; }
grep -qE '\(\( n > 99 \)\)' "$DRILL" \
  || { echo "FAIL: 99 cap missing"; exit 1; }
pass "collision counter wired in bin/consult-drilldown.sh"
