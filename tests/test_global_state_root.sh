#!/usr/bin/env bash
# v0.38.0 — cw_global_state_root + cw_global_state_ensure helpers
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"

# Case 1: default (no CLONE_WARS_HOME) → $HOME/.clone-wars
unset CLONE_WARS_HOME
expected="$HOME/.clone-wars"
out=$(cw_global_state_root)
assert_eq "$out" "$expected" "case 1: default resolves to \$HOME/.clone-wars"
pass "1. cw_global_state_root default = \$HOME/.clone-wars"

# Case 2: CLONE_WARS_HOME=$TMP → $TMP (test/debug seam)
export CLONE_WARS_HOME="$TMP"
out=$(cw_global_state_root)
assert_eq "$out" "$TMP" "case 2: CLONE_WARS_HOME env var honored"
pass "2. CLONE_WARS_HOME env var honored"

# Case 3: changing PWD does NOT affect cw_global_state_root (unlike cw_state_root)
cd "$TMP" && mkdir -p subdir && cd subdir
out=$(cw_global_state_root)
assert_eq "$out" "$TMP" "case 3: cwd change must not affect global root"
pass "3. cwd change doesn't affect cw_global_state_root"

# Case 4: cw_global_state_ensure creates dir + .gitignore
unset CLONE_WARS_HOME
ALT="$TMP/alt-global"
export CLONE_WARS_HOME="$ALT"
cw_global_state_ensure
[[ -d "$ALT" ]] || { echo "FAIL: case 4 dir not created"; exit 1; }
[[ -f "$ALT/.gitignore" ]] || { echo "FAIL: case 4 .gitignore not created"; exit 1; }
grep -qE '^\*$' "$ALT/.gitignore" \
  || { echo "FAIL: case 4 .gitignore missing '*'"; cat "$ALT/.gitignore"; exit 1; }
pass "4. cw_global_state_ensure creates dir + auto .gitignore"

# Case 5: cw_state_root (per-PROJECT) is independent of cw_global_state_root
unset CLONE_WARS_HOME
cd "$TMP"
project_root=$(cw_state_root)
global_root=$(cw_global_state_root)
assert_eq "$project_root" "$TMP/.clone-wars" "case 5a: project root = \$PWD/.clone-wars"
assert_eq "$global_root"  "$HOME/.clone-wars" "case 5b: global root = \$HOME/.clone-wars"
[[ "$project_root" != "$global_root" ]] \
  || { echo "FAIL: case 5 project and global should differ"; exit 1; }
pass "5. cw_state_root (project) and cw_global_state_root (global) are independent"

echo "test_global_state_root: 5 cases passed"
