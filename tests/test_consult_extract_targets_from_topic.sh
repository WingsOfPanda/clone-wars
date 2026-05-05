#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/consult-hub.sh"

LEAVES="ars_fleet/ARS-TaskServe,ars_fleet/ARS-LVMGateway,ars_fleet/ARS-Gateway,ars_lab/ARS-Foo"

# (a) Single leaf in topic
out=$(cw_consult_extract_targets_from_topic "refactor auth in ARS-TaskServe" "$LEAVES")
inferred=$(grep '^INFERRED=' <<< "$out" | cut -d= -f2)
ka=$(grep '^KEYWORD_ALL=' <<< "$out" | cut -d= -f2)
[[ "$inferred" == "ars_fleet/ARS-TaskServe" ]] || { echo "FAIL (a) inferred: $inferred"; exit 1; }
[[ "$ka" == "0" ]] || { echo "FAIL (a) ka: $ka"; exit 1; }
pass "(a) single leaf: ARS-TaskServe -> ars_fleet/ARS-TaskServe, KEYWORD_ALL=0"

# (b) Multiple leaves
out=$(cw_consult_extract_targets_from_topic "refactor auth across ARS-TaskServe and ARS-Gateway" "$LEAVES")
inferred=$(grep '^INFERRED=' <<< "$out" | cut -d= -f2)
[[ ",$inferred," == *,ars_fleet/ARS-TaskServe,* ]] || { echo "FAIL (b) TaskServe missing"; exit 1; }
[[ ",$inferred," == *,ars_fleet/ARS-Gateway,* ]]   || { echo "FAIL (b) Gateway missing"; exit 1; }
pass "(b) multiple leaves inferred"

# (c) "across all" -> KEYWORD_ALL=1
out=$(cw_consult_extract_targets_from_topic "audit across all sub-projects for stale deps" "$LEAVES")
ka=$(grep '^KEYWORD_ALL=' <<< "$out" | cut -d= -f2)
[[ "$ka" == "1" ]] || { echo "FAIL (c): expected KEYWORD_ALL=1, got $ka"; exit 1; }
pass "(c) 'across all' -> KEYWORD_ALL=1"

# (d) Hub name only -> all leaves under that hub
out=$(cw_consult_extract_targets_from_topic "refactor everything in ars_fleet" "$LEAVES")
inferred=$(grep '^INFERRED=' <<< "$out" | cut -d= -f2)
for leaf in ars_fleet/ARS-TaskServe ars_fleet/ARS-LVMGateway ars_fleet/ARS-Gateway; do
  [[ ",$inferred," == *,$leaf,* ]] || { echo "FAIL (d) leaf $leaf missing in $inferred"; exit 1; }
done
[[ ",$inferred," != *,ars_lab/* ]] || { echo "FAIL (d) wrong-hub leaf included"; exit 1; }
pass "(d) hub name -> all leaves under that hub"

# (e) Zero matches -> rc=1
if cw_consult_extract_targets_from_topic "document the new feature pipeline" "$LEAVES" 2>/dev/null; then
  echo "FAIL (e): expected rc=1"; exit 1
fi
pass "(e) zero matches -> rc=1"

# (f) Substring ambiguity (Gateway -> ARS-Gateway + ARS-LVMGateway both)
out=$(cw_consult_extract_targets_from_topic "improve the Gateway field handling" "$LEAVES" || true)
inferred=$(grep '^INFERRED=' <<< "$out" | cut -d= -f2 || true)
# Word-boundary should match neither (Gateway alone isn't a leaf name) OR both --
# implementation choice. Either is acceptable, but if both, test passes; if neither, rc=1.
# We accept both outcomes as long as we don't get exactly one (which would mask the ambiguity).
if [[ -n "$inferred" ]]; then
  count=$(tr ',' '\n' <<< "$inferred" | wc -l | tr -d ' ')
  [[ "$count" -ge 2 || "$count" -eq 0 ]] || { echo "FAIL (f) ambiguous match should surface 0 or >=2, got $count"; exit 1; }
fi
pass "(f) substring 'Gateway' surfaces ambiguity (neither or both)"
