#!/usr/bin/env bash
# tests/test_spawn_mode_fallthrough.sh
# Regression for v0.20.4: when MODE is empty AND
# cw_contract_default_mode returns rc=0 with empty stdout, MODE must
# fall through to "full" (not stay empty as in the chained-|| bug).
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

# Simulate the exact MODE-resolution snippet from bin/spawn.sh.
# Stub cw_contract_default_mode to return empty stdout with rc=0.
cw_contract_default_mode() { :; }   # rc=0, empty stdout
MODEL="any-model"
MODE=""

# This is the post-fix snippet from spawn.sh:150.
[[ -n "$MODE" ]] || MODE=$(cw_contract_default_mode "$MODEL")
[[ -n "$MODE" ]] || MODE=full

[[ "$MODE" == "full" ]] \
  || { echo "FAIL: MODE='$MODE', expected 'full' after fallthrough" >&2; exit 1; }

# Sanity: also verify the happy path (default_mode returns a value) still works.
cw_contract_default_mode() { echo "headless"; }
MODE=""
[[ -n "$MODE" ]] || MODE=$(cw_contract_default_mode "$MODEL")
[[ -n "$MODE" ]] || MODE=full
[[ "$MODE" == "headless" ]] \
  || { echo "FAIL: MODE='$MODE', expected 'headless' from default_mode" >&2; exit 1; }

# And: explicit MODE wins over default_mode.
cw_contract_default_mode() { echo "should-be-ignored"; }
MODE="explicit"
[[ -n "$MODE" ]] || MODE=$(cw_contract_default_mode "$MODEL")
[[ -n "$MODE" ]] || MODE=full
[[ "$MODE" == "explicit" ]] \
  || { echo "FAIL: MODE='$MODE', expected 'explicit'" >&2; exit 1; }

pass "spawn.sh MODE fallthrough: empty default_mode → full; non-empty → kept; explicit wins"
