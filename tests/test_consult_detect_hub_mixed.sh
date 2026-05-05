#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/log.sh
source ../lib/consult.sh

TMPROOT=$(mktemp -d -t cw-detect-mixed.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

git init -q "$TMPROOT"
mkdir -p "$TMPROOT/hub_a/leaf1" "$TMPROOT/hub_b"
git init -q "$TMPROOT/hub_a"
git init -q "$TMPROOT/hub_a/leaf1"
git init -q "$TMPROOT/hub_b"   # no grandchild git → leaf-less hub, dropped

out=$(cw_consult_detect_hub "$TMPROOT") && rc=0 || rc=$?
[[ "$rc" -eq 0 ]] || { echo "FAIL"; exit 1; }
grep -qx 'MODE=super-hub' <<< "$out" || { echo "FAIL"; exit 1; }
hubs=$(grep '^HUBS=' <<< "$out" | cut -d= -f2)
[[ "$hubs" == "hub_a" ]] || { echo "FAIL: expected HUBS=hub_a, got $hubs"; exit 1; }
pass "mixed super-hub: leaf-less hub dropped"
