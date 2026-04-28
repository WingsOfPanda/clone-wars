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

# === Phase 2: bootstrap_sleep_s contract field ===

# 7. cw_contract_bootstrap_sleep returns the field when set.
TMP_C=$(mktemp -d)
# Merge into the existing $TMP trap (set on line 10) instead of overwriting it,
# otherwise $TMP leaks across runs.
trap 'rm -rf "$TMP" "$TMP_C"' EXIT
cat > "$TMP_C/contracts.yaml" <<YAML
codex:
  binary: codex
  modes:
    full: [--bypass]
  default_mode: full
  ready_timeout_s: 30
  bootstrap_sleep_s: 5

claude:
  binary: claude
  modes:
    full: [--skip]
  default_mode: full
  ready_timeout_s: 60
  bootstrap_sleep_s: 12
YAML
got=$(CLONE_WARS_HOME="$TMP_C" cw_contract_bootstrap_sleep codex)
assert_eq "$got" "5" "codex bootstrap_sleep_s reads back"
got=$(CLONE_WARS_HOME="$TMP_C" cw_contract_bootstrap_sleep claude)
assert_eq "$got" "12" "claude bootstrap_sleep_s reads back"
pass "bootstrap_sleep_s field reads back"

# 8. Default value when field is missing — provider-specific legacy default.
#    claude=12 (preserves the v0.0.4 hardcoded BOOT_SLEEP for claude installs
#    that haven't synced the new field yet); everything else=8.
cat > "$TMP_C/contracts.yaml" <<YAML
codex:
  binary: codex
  modes:
    full: [--bypass]
  default_mode: full
  ready_timeout_s: 30

claude:
  binary: claude
  modes:
    full: [--skip]
  default_mode: full
  ready_timeout_s: 60

gemini:
  binary: gemini
  modes:
    full: [--yolo]
  default_mode: full
  ready_timeout_s: 30
YAML
got=$(CLONE_WARS_HOME="$TMP_C" cw_contract_bootstrap_sleep codex)
assert_eq "$got" "8" "missing bootstrap_sleep_s on codex defaults to 8"
got=$(CLONE_WARS_HOME="$TMP_C" cw_contract_bootstrap_sleep gemini)
assert_eq "$got" "8" "missing bootstrap_sleep_s on gemini defaults to 8"
got=$(CLONE_WARS_HOME="$TMP_C" cw_contract_bootstrap_sleep claude)
assert_eq "$got" "12" "missing bootstrap_sleep_s on claude defaults to 12 (legacy preservation)"
pass "bootstrap_sleep_s default is provider-specific (preserves claude=12 for existing installs)"

# 9. Unknown provider with no field → 8 (the safe global default).
got=$(CLONE_WARS_HOME="$TMP_C" cw_contract_bootstrap_sleep nosuchprovider)
assert_eq "$got" "8" "unknown provider with no field defaults to 8"
pass "unknown-provider default is 8"

# === consult: block ===
cat > "$TMP_C/contracts.yaml" <<YAML
codex:
  binary: codex
  modes: { full: [--bypass] }
  default_mode: full
  ready_timeout_s: 30

consult:
  research_timeout_s: 600
  verify_timeout_s: 300
YAML
got=$(CLONE_WARS_HOME="$TMP_C" cw_consult_timeout research)
assert_eq "$got" "600" "research reads back"
got=$(CLONE_WARS_HOME="$TMP_C" cw_consult_timeout verify)
assert_eq "$got" "300" "verify reads back"
pass "consult timeouts read back"

# consult: is a reserved non-provider block — cw_contracts_providers must skip it.
PROVS=$(CLONE_WARS_HOME="$TMP_C" cw_contracts_providers | tr '\n' ' ' | sed 's/ $//')
assert_eq "$PROVS" "codex" "consult: skipped from provider enumeration"
pass "consult: not enumerated as a provider"

# Defaults when block missing.
cat > "$TMP_C/contracts.yaml" <<YAML
codex:
  binary: codex
  modes: { full: [--bypass] }
  default_mode: full
  ready_timeout_s: 30
YAML
got=$(CLONE_WARS_HOME="$TMP_C" cw_consult_timeout research); assert_eq "$got" "600" "research default 600"
got=$(CLONE_WARS_HOME="$TMP_C" cw_consult_timeout verify);   assert_eq "$got" "300" "verify default 300"
pass "defaults applied when block missing"

# Malformed value falls back to default.
cat > "$TMP_C/contracts.yaml" <<YAML
codex:
  binary: codex
  modes: { full: [--bypass] }
  default_mode: full
  ready_timeout_s: 30

consult:
  research_timeout_s: -5
  verify_timeout_s:   notaninteger
YAML
got=$(CLONE_WARS_HOME="$TMP_C" cw_consult_timeout research); assert_eq "$got" "600" "negative falls back"
got=$(CLONE_WARS_HOME="$TMP_C" cw_consult_timeout verify);   assert_eq "$got" "300" "non-integer falls back"
pass "malformed values fall back to defaults"
