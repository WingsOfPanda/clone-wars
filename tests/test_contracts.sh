#!/usr/bin/env bash
# tests/test_contracts.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/state.sh
source ../lib/contracts.sh

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

# 1. cw_contracts_path returns $CLONE_WARS_HOME/contracts.yaml regardless of file existence.
assert_eq "$(cw_contracts_path)" "$TMP/cw/contracts.yaml" "contracts path"
pass "contracts path"

# 2. cw_contracts_exists is non-zero before file is created, zero after.
! cw_contracts_exists || { echo "FAIL: should not exist yet" >&2; exit 1; }
mkdir -p "$TMP/cw"; touch "$TMP/cw/contracts.yaml"
cw_contracts_exists || { echo "FAIL: should exist after touch" >&2; exit 1; }
pass "contracts existence check"
