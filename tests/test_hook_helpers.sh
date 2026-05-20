#!/usr/bin/env bash
# tests/test_hook_helpers.sh — v0.47.0 finding #8
# Locks the contract of .claude/hooks/_lib.sh (project-level helpers
# shared between post-edit-hardcoded-paths-lint.sh and
# post-version-bump-lock-check.sh).
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
LIB="$PLUGIN_ROOT/.claude/hooks/_lib.sh"
[[ -f "$LIB" ]] || { echo "FAIL: $LIB missing" >&2; exit 1; }
# shellcheck source=/dev/null
source "$LIB"

# Case 1: cw_hook_file_path_from_stdin extracts present file_path
payload='{"tool_name":"Edit","tool_input":{"file_path":"/abs/path/to/file.sh","old_string":"x","new_string":"y"}}'
out=$(printf '%s' "$payload" | cw_hook_file_path_from_stdin)
assert_eq "$out" "/abs/path/to/file.sh" "present file_path"
pass "1. file_path extracted from full payload"

# Case 2: absent file_path → empty
payload='{"tool_name":"Bash","tool_input":{"command":"ls"}}'
out=$(printf '%s' "$payload" | cw_hook_file_path_from_stdin)
assert_eq "$out" "" "absent file_path → empty"
pass "2. absent file_path → empty"

# Case 3: multi-key payload, file_path among others (first match)
payload='{"tool_name":"Write","tool_input":{"file_path":"/a/b.md","content":"x"}}'
out=$(printf '%s' "$payload" | cw_hook_file_path_from_stdin)
assert_eq "$out" "/a/b.md" "multi-key payload"
pass "3. multi-key payload extracts file_path"

# Case 4: empty stdin → empty
out=$(printf '' | cw_hook_file_path_from_stdin)
assert_eq "$out" "" "empty stdin → empty"
pass "4. empty stdin → empty"

# Case 5: cw_hook_repo_root walks up from caller. Simulate by sourcing
# from a fixture script under a temp dir's .claude/hooks/ subpath.
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/.claude/hooks"
cp "$LIB" "$SANDBOX/.claude/hooks/_lib.sh"
cat > "$SANDBOX/.claude/hooks/fake-hook.sh" <<'HOOK'
#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
cw_hook_repo_root
HOOK
chmod +x "$SANDBOX/.claude/hooks/fake-hook.sh"
out=$(bash "$SANDBOX/.claude/hooks/fake-hook.sh")
expected=$(cd "$SANDBOX" && pwd -P)
got=$(cd "$out" && pwd -P)
assert_eq "$got" "$expected" "repo_root walks up 2 dirs from caller"
pass "5. cw_hook_repo_root resolves from caller's location"

echo "test_hook_helpers: 5 cases passed"
