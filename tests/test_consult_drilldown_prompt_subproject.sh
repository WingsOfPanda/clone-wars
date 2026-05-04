#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/log.sh
source ../lib/state.sh
export CLAUDE_PLUGIN_ROOT="$(cd .. && pwd)"; PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT"
source ../lib/consult.sh

# With sub-project axis
out=$(cw_consult_design_doc_drilldown_prompt \
        "Architecture" "/path/to/synthesis.md" "rex" \
        "/path/to/dd-dir" "Add IPC depth." "ARS-TaskServe")
grep -q 'ARS-TaskServe' <<< "$out" || { echo "FAIL: subproject not mentioned"; exit 1; }
grep -q '_scratch/drilldown-architecture-ARS-TaskServe-rex.md' <<< "$out" \
  || { echo "FAIL: subproject path missing"; exit 1; }
pass "subproject axis: prompt scoped + path includes subproject slug"

# Without (backward-compat with v0.5.3+)
out=$(cw_consult_design_doc_drilldown_prompt \
        "Architecture" "/path/to/synthesis.md" "rex" \
        "/path/to/dd-dir" "Add IPC depth.")
grep -q '_scratch/drilldown-architecture-rex.md' <<< "$out" \
  || { echo "FAIL: legacy path missing"; exit 1; }
grep -q 'ARS-' <<< "$out" \
  && { echo "FAIL: legacy mode should not mention any subproject"; exit 1; } || true
pass "no subproject: legacy path unchanged"
