#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/log.sh
source ../lib/consult.sh

TMPROOT=$(mktemp -d -t cw-detect-subrepo.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

git init -q "$TMPROOT"
mkdir -p "$TMPROOT/leaf1/src" "$TMPROOT/leaf2/src"
git init -q "$TMPROOT/leaf1"
git init -q "$TMPROOT/leaf2"

out=$(cw_consult_detect_hub "$TMPROOT") || rc=$?; rc=${rc:-0}
[[ "$rc" -eq 0 ]] || { echo "FAIL: rc=$rc"; exit 1; }
grep -qx 'MODE=hub-subrepo' <<< "$out" || { echo "FAIL"; exit 1; }
grep -q '^LEAVES=' <<< "$out" || { echo "FAIL: no LEAVES"; exit 1; }
grep -q '^HUBS=' <<< "$out" && { echo "FAIL: HUBS line should be absent in hub-subrepo"; exit 1; }
leaves=$(grep '^LEAVES=' <<< "$out" | cut -d= -f2)
self="$(basename "$TMPROOT")"
[[ ",$leaves," == *,"$self/leaf1",* ]] || { echo "FAIL: $self/leaf1 missing in $leaves"; exit 1; }
[[ ",$leaves," == *,"$self/leaf2",* ]] || { echo "FAIL: $self/leaf2 missing"; exit 1; }
pass "hub-subrepo detected"
