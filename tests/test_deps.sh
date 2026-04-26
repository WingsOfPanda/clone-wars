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

# 2. cw_tmux_version_ok requires tmux ≥ 3.0.
# We mock by overriding cw_tmux_version_string in subshells.

assert_tmux_ok() {
  local version="$1" expected_code="$2"
  ( cw_tmux_version_string() { printf '%s\n' "$version"; }
    set +e
    cw_tmux_version_ok
    code=$?
    set -e
    [[ "$code" -eq "$expected_code" ]] || { echo "FAIL: tmux=$version expected $expected_code got $code" >&2; exit 1; }
  )
}

assert_tmux_ok "tmux 3.0a"  0
assert_tmux_ok "tmux 3.4"   0
assert_tmux_ok "tmux 4.1"   0
assert_tmux_ok "tmux 2.9a"  1
assert_tmux_ok "tmux 1.8"   1
pass "tmux version gate ≥ 3.0"

# 3. cw_in_tmux_session is 0 iff $TMUX is set non-empty.
( unset TMUX; ! cw_in_tmux_session ) || { echo "FAIL: expected fail when TMUX unset" >&2; exit 1; }
pass "not in tmux"

( TMUX=/tmp/x,123,0 cw_in_tmux_session ) || { echo "FAIL: expected ok when TMUX set" >&2; exit 1; }
pass "in tmux"
