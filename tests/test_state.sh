#!/usr/bin/env bash
# tests/test_state.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/state.sh

# 1. Default root is $HOME/.clone-wars when CLONE_WARS_HOME is unset.
unset CLONE_WARS_HOME
assert_eq "$(cw_state_root)" "$HOME/.clone-wars" "default root"
pass "default root"

# 2. Override via CLONE_WARS_HOME.
CLONE_WARS_HOME=/tmp/cw-test assert_eq "$(CLONE_WARS_HOME=/tmp/cw-test cw_state_root)" "/tmp/cw-test" "override"
pass "override root"
