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

# 3. Provider enumeration + binary lookup against a fixture.
cat > "$TMP/cw/contracts.yaml" <<'YAML'
codex:
  binary: codex
  modes:
    full:      [--dangerously-bypass-approvals-and-sandbox]
    read-only: [--sandbox, read-only]
  default_mode: full
  ready_timeout_s: 30

gemini:
  binary: gemini
  modes:
    full:      [--approval-mode, yolo]
    read-only: [--approval-mode, default]
  default_mode: full
  ready_timeout_s: 30

claude:
  binary: claude
  modes:
    full:      [--dangerously-skip-permissions]
    read-only: []
  default_mode: full
  ready_timeout_s: 60
YAML

PROVS=$(cw_contracts_providers | tr '\n' ' ' | sed 's/ $//')
assert_eq "$PROVS" "codex gemini claude" "provider list in file order"
pass "providers enumerated"

assert_eq "$(cw_contract_binary codex)"  "codex"  "codex binary"
assert_eq "$(cw_contract_binary gemini)" "gemini" "gemini binary"
assert_eq "$(cw_contract_binary claude)" "claude" "claude binary"
pass "binary lookup"

# 4. Missing provider returns non-zero with empty stdout.
out=$(cw_contract_binary nope 2>/dev/null) || rc=$?
assert_eq "$out" "" "empty for missing"
[[ "${rc:-0}" -ne 0 ]] || { echo "FAIL: expected non-zero rc for missing provider" >&2; exit 1; }
pass "missing provider returns non-zero"

# 5. Nested binary: fields don't shadow the canonical 2-space-indent binary: field.
cat > "$TMP/cw/contracts.yaml" <<'YAML'
alpha:
  modes:
    binary: NESTED-SHOULD-NOT-MATCH
  binary: alpha-bin
beta:
  binary: beta-bin
YAML

assert_eq "$(cw_contract_binary alpha)" "alpha-bin" "alpha lookup ignores nested binary"
assert_eq "$(cw_contract_binary beta)"  "beta-bin"  "beta lookup unaffected"
pass "nested binary field doesn't shadow canonical"
