#!/usr/bin/env bash
# tests/test_state_root_project_local.sh — v0.31.0 item 1
# Locks: cw_state_root returns $PWD/.clone-wars when CLONE_WARS_HOME unset;
# cw_state_ensure writes <root>/.gitignore with '*' on first creation;
# CLONE_WARS_HOME override still works as a test seam.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

# Case 1: default behavior — $PWD/.clone-wars (no CLONE_WARS_HOME)
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
cd "$SANDBOX"
unset CLONE_WARS_HOME
source "$PLUGIN_ROOT/lib/state.sh"
out=$(cw_state_root)
[[ "$out" == "$SANDBOX/.clone-wars" ]] || { echo "FAIL: default cw_state_root: $out, expected $SANDBOX/.clone-wars" >&2; exit 1; }
pass "1. cw_state_root returns \$PWD/.clone-wars when CLONE_WARS_HOME unset"

# Case 2: CLONE_WARS_HOME override (test seam) still works
export CLONE_WARS_HOME="$SANDBOX/override"
out=$(cw_state_root)
[[ "$out" == "$SANDBOX/override" ]] || { echo "FAIL: CLONE_WARS_HOME override: $out, expected $SANDBOX/override" >&2; exit 1; }
unset CLONE_WARS_HOME
pass "2. CLONE_WARS_HOME override honored as test seam"

# Case 3: cw_state_ensure creates state/ + archive/ + .gitignore on first call
cd "$SANDBOX"
unset CLONE_WARS_HOME
cw_state_ensure
[[ -d "$SANDBOX/.clone-wars/state" ]] || { echo "FAIL: state/ not created" >&2; exit 1; }
[[ -d "$SANDBOX/.clone-wars/archive" ]] || { echo "FAIL: archive/ not created" >&2; exit 1; }
[[ -f "$SANDBOX/.clone-wars/.gitignore" ]] || { echo "FAIL: .gitignore not written" >&2; exit 1; }
content=$(cat "$SANDBOX/.clone-wars/.gitignore")
[[ "$content" == "*" ]] || { echo "FAIL: .gitignore content '$content', expected '*'" >&2; exit 1; }
pass "3. cw_state_ensure writes state/, archive/, .gitignore with '*'"

# Case 4: idempotent — second call doesn't overwrite user's custom .gitignore
printf '*\n!keep-me.txt\n' > "$SANDBOX/.clone-wars/.gitignore"
cw_state_ensure
content=$(cat "$SANDBOX/.clone-wars/.gitignore")
[[ "$content" == $'*\n!keep-me.txt' ]] || { echo "FAIL: custom .gitignore was overwritten (got '$content')" >&2; exit 1; }
pass "4. cw_state_ensure preserves user-customized .gitignore"

# Case 5: cw_topic_repo_hash returns hash of $PWD (no CW_TOPIC_REPO_CWD branch)
cd "$SANDBOX"
unset CW_TOPIC_REPO_CWD
hash_pwd=$(cw_topic_repo_hash)
expected_hash=$(cw_repo_hash_for "$SANDBOX")
[[ "$hash_pwd" == "$expected_hash" ]] || { echo "FAIL: cw_topic_repo_hash should match cw_repo_hash_for \$PWD" >&2; exit 1; }
pass "5. cw_topic_repo_hash returns hash of \$PWD"

# Case 6: cw_topic_repo_hash IGNORES CW_TOPIC_REPO_CWD env var (v0.31.0 dead branch)
SANDBOX2=$(mktemp -d)
export CW_TOPIC_REPO_CWD="$SANDBOX2"
hash_after_env=$(cw_topic_repo_hash)
[[ "$hash_after_env" == "$expected_hash" ]] || { echo "FAIL: cw_topic_repo_hash should ignore CW_TOPIC_REPO_CWD (got $hash_after_env, expected $expected_hash)" >&2; exit 1; }
unset CW_TOPIC_REPO_CWD
rm -rf "$SANDBOX2"
pass "6. cw_topic_repo_hash ignores CW_TOPIC_REPO_CWD (v0.31.0 dead branch removed)"

echo "test_state_root_project_local: 6 cases passed"
