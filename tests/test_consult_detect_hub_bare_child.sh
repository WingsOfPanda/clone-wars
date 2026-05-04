#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/log.sh
source ../lib/consult.sh

TMPROOT=$(mktemp -d -t cw-detect-bare.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

git init -q "$TMPROOT"
mkdir -p "$TMPROOT/leaf1/src"   # real leaf with subdir
git init -q "$TMPROOT/leaf1"
git init -q "$TMPROOT/leaf2"    # bare leaf (no subdirs)

out=$(cw_consult_detect_hub "$TMPROOT" 2>/dev/null) && rc=0 || rc=$?
[[ "$rc" -eq 0 ]] || { echo "FAIL: rc=$rc"; exit 1; }
leaves=$(grep '^LEAVES=' <<< "$out" | cut -d= -f2)
[[ ",$leaves," == *,*"/leaf1",* ]] || { echo "FAIL: leaf1 missing in $leaves"; exit 1; }
[[ ",$leaves," != *,*"/leaf2",* ]] || { echo "FAIL: bare leaf2 should be dropped, got $leaves"; exit 1; }
pass "bare git child without subdirectories is dropped"

# stderr should carry the warning
err=$(cw_consult_detect_hub "$TMPROOT" 2>&1 >/dev/null || true)
grep -q "leaf2" <<< "$err" || { echo "FAIL: expected log_warn mentioning leaf2, got: $err"; exit 1; }
pass "log_warn emitted for dropped bare child"
