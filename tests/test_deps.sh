#!/usr/bin/env bash
# tests/test_deps.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/deps.sh

# 1. cw_have_cmd returns 0 for sh and 1 for definitely-missing.
cw_have_cmd sh || { echo "FAIL: sh should be present" >&2; exit 1; }
pass "have sh"

! cw_have_cmd cw-definitely-not-a-binary-2026 || { echo "FAIL: bogus binary should be absent" >&2; exit 1; }
pass "missing bogus"
