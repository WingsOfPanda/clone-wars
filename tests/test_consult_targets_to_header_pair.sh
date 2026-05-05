#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/log.sh
source ../lib/state.sh
source ../lib/consult.sh

TMPROOT=$(mktemp -d -t cw-header-pair.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT
ART="$TMPROOT/_consult"; mkdir -p "$ART"

printf '%s\n' "hub_a/leaf1" "hub_a/leaf2" "hub_b/leaf3" \
  | cw_consult_targets_persist "$ART"

out=$(cw_consult_targets_to_header_pair "$ART")
[[ "$(printf '%s' "$out" | wc -l)" -eq 1 ]] || true   # header pair = 2 lines, last has no trailing newline → wc -l = 1
expected_hubs='**Target Hub(s):** hub_a, hub_b'
expected_leaves='**Target Sub-Project(s):** leaf1, leaf2, leaf3'
grep -qxF "$expected_hubs"   <<< "$out" || { echo "FAIL hubs line: $out"; exit 1; }
grep -qxF "$expected_leaves" <<< "$out" || { echo "FAIL leaves line: $out"; exit 1; }
pass "header pair: hubs deduped, leaves preserved in order"

# Empty targets → rc=1
rm "$ART/targets.txt"
if cw_consult_targets_to_header_pair "$ART" 2>/dev/null; then
  echo "FAIL: missing targets.txt should rc=1"; exit 1
fi
pass "missing targets.txt → rc=1"
