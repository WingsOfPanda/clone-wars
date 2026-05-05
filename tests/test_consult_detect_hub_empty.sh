#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/log.sh
source ../lib/consult.sh

TMPROOT=$(mktemp -d -t cw-detect-empty.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

git init -q "$TMPROOT"
mkdir -p "$TMPROOT/hub_a" "$TMPROOT/hub_b"
git init -q "$TMPROOT/hub_a"
git init -q "$TMPROOT/hub_b"   # both leaf-less

out=$(cw_consult_detect_hub "$TMPROOT") && rc=0 || rc=$?
[[ "$rc" -eq 1 ]] || { echo "FAIL: expected rc=1 (super-hub with all leaf-less), got $rc"; exit 1; }
pass "all-leaf-less super-hub falls back to single-repo"
