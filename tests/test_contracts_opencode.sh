#!/usr/bin/env bash
# tests/test_contracts_opencode.sh — v0.13.0 regression for opencode
# contract row. Asserts cw_contract_* helpers return expected values.
set -euo pipefail
cd "$(dirname "$0")"
PLUGIN_ROOT=$(cd .. && pwd)
source lib/assert.sh

# Stage a state root with the shipped contracts.yaml so the helpers
# read from the in-tree file (medic copies on first run; here we copy
# directly to keep the test hermetic).
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"
mkdir -p "$CLONE_WARS_HOME"
cp "$PLUGIN_ROOT/config/contracts.yaml" "$CLONE_WARS_HOME/contracts.yaml"

source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/contracts.sh"

# === Provider enumeration includes opencode ===
providers=$(cw_contracts_providers | sort | tr '\n' ',' | sed 's/,$//')
assert_contains "$providers" "opencode" "opencode listed by cw_contracts_providers"
pass "contracts: opencode appears in cw_contracts_providers output"

# === Binary ===
bin=$(cw_contract_binary opencode)
assert_eq "$bin" "opencode" "cw_contract_binary opencode"
pass "contracts: cw_contract_binary opencode == opencode"

# === Default mode ===
mode=$(cw_contract_default_mode opencode)
assert_eq "$mode" "full" "cw_contract_default_mode opencode"
pass "contracts: cw_contract_default_mode opencode == full"

# === Mode args (full) ===
args=$(cw_contract_mode_args opencode full | tr '\n' '|')
assert_eq "$args" "-m|deepseek/deepseek-v4-pro|" "cw_contract_mode_args opencode full"
pass "contracts: cw_contract_mode_args opencode full == -m deepseek/deepseek-v4-pro"

# === Ready timeout (calibrated from PR1 tracer; see plan §PR1 measurements) ===
rt=$(cw_contract_ready_timeout opencode)
# Accept any positive integer >= 30 (lets the calibrated value vary by
# machine without breaking the test). Tracer-pinned exact value was 60.
[[ "$rt" =~ ^[0-9]+$ ]] && (( rt >= 30 )) \
  || { echo "FAIL: ready_timeout_s expected >=30 integer, got '$rt'" >&2; exit 1; }
pass "contracts: cw_contract_ready_timeout opencode is sane (got $rt)"

# === Bootstrap sleep ===
bs=$(cw_contract_bootstrap_sleep opencode)
[[ "$bs" =~ ^[0-9]+$ ]] && (( bs >= 5 )) \
  || { echo "FAIL: bootstrap_sleep_s expected >=5 integer, got '$bs'" >&2; exit 1; }
pass "contracts: cw_contract_bootstrap_sleep opencode is sane (got $bs)"
