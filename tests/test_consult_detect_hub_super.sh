#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/log.sh
source ../lib/consult.sh

TMPROOT=$(mktemp -d -t cw-detect-super.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

git init -q "$TMPROOT"
mkdir -p "$TMPROOT/hub_a/leaf1" "$TMPROOT/hub_a/leaf2" "$TMPROOT/hub_b/leaf3"
git init -q "$TMPROOT/hub_a"
git init -q "$TMPROOT/hub_a/leaf1"
git init -q "$TMPROOT/hub_a/leaf2"
git init -q "$TMPROOT/hub_b"
git init -q "$TMPROOT/hub_b/leaf3"

out=$(cw_consult_detect_hub "$TMPROOT") || rc=$?; rc=${rc:-0}
[[ "$rc" -eq 0 ]] || { echo "FAIL: rc=$rc"; exit 1; }
grep -qx 'MODE=super-hub' <<< "$out"  || { echo "FAIL: no MODE=super-hub"; printf '%s\n' "$out"; exit 1; }
grep -qE '^HUBS=hub_[ab],hub_[ab]$' <<< "$out" || { echo "FAIL: HUBS line wrong"; printf '%s\n' "$out"; exit 1; }
grep -q '^LEAVES=' <<< "$out" || { echo "FAIL: no LEAVES line"; exit 1; }
leaves=$(grep '^LEAVES=' <<< "$out" | cut -d= -f2)
for l in hub_a/leaf1 hub_a/leaf2 hub_b/leaf3; do
  [[ ",$leaves," == *,$l,* ]] || { echo "FAIL: leaf $l missing in $leaves"; exit 1; }
done
pass "super-hub detected with HUBS+LEAVES lines"
