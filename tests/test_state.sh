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

# 3. cw_state_ensure creates root + standard subdirs and is idempotent.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
CLONE_WARS_HOME="$TMP/cw" cw_state_ensure
assert_file_exists "$TMP/cw" "root created"
assert_file_exists "$TMP/cw/state" "state subdir"
assert_file_exists "$TMP/cw/archive" "archive subdir"
# Idempotent: second call doesn't error.
CLONE_WARS_HOME="$TMP/cw" cw_state_ensure
pass "ensure idempotent"

# 4. cw_repo_hash is sha256 of realpath(pwd), 64 hex chars.
H=$(cw_repo_hash)
[[ "${#H}" -eq 64 ]] || { echo "FAIL: hash length ${#H}, want 64" >&2; exit 1; }
[[ "$H" =~ ^[0-9a-f]{64}$ ]] || { echo "FAIL: hash not hex: $H" >&2; exit 1; }
pass "repo_hash hex64"

# 5. Same cwd → same hash; different cwd → different hash.
H2=$(cw_repo_hash)
assert_eq "$H" "$H2" "stable across calls"
pass "repo_hash stable"

(cd "$TMP" && H3=$(cw_repo_hash); [[ "$H3" != "$H" ]]) || { echo "FAIL: different cwd produced same hash" >&2; exit 1; }
pass "repo_hash differs by cwd"
