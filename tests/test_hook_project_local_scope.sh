#!/usr/bin/env bash
# tests/test_hook_project_local_scope.sh — v0.31.0 item 2
# Locks: hook scans $PWD/.clone-wars/state, not the global root.
# Two sibling project dirs; only one has active.txt; hook fires only
# when invoked from THAT project's cwd.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
HOOK="$PLUGIN_ROOT/hooks/user-prompt-submit-active-session.sh"

[[ -x "$HOOK" ]] || { echo "FAIL: hook script missing or not executable" >&2; exit 1; }
pass "hook script present + executable"

# Sandbox: 2 sibling projects, only proj-A has an active deep-research session
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/proj-A/.clone-wars/state/HASH-A/topic-foo/_deep-research"
mkdir -p "$SANDBOX/proj-B/.clone-wars/state/HASH-B/topic-bar"

# v0.40.0: hook matches active-<session-id>.txt against the .session_id
# field in stdin JSON. Tests pipe synthetic payload with the matching SID.
SID=ffffffff-projscope-test-9999-aaaaaaaaaaaa
PAYLOAD="{\"session_id\":\"$SID\",\"hook_event_name\":\"UserPromptSubmit\"}"
echo "topic-foo" > "$SANDBOX/proj-A/.clone-wars/state/HASH-A/topic-foo/_deep-research/active-${SID}.txt"

# Hook MUST NOT see proj-A's marker when invoked from proj-B's cwd
unset CLONE_WARS_HOME   # ensure project-local resolution
cd "$SANDBOX/proj-B"
out=$(printf '%s' "$PAYLOAD" | bash "$HOOK" 2>&1)
[[ -z "$out" ]] || { echo "FAIL: hook leaked proj-A's marker into proj-B's session" >&2; echo "$out" >&2; exit 1; }
pass "1. hook silent in proj-B (no local active-<sid>.txt)"

# Hook MUST see proj-A's marker when invoked from proj-A's cwd
cd "$SANDBOX/proj-A"
out=$(printf '%s' "$PAYLOAD" | bash "$HOOK" 2>&1)
[[ -n "$out" ]] || { echo "FAIL: hook missed proj-A's active-<sid>.txt when invoked from proj-A" >&2; exit 1; }
grep -q 'topic: topic-foo' <<<"$out" \
  || { echo "FAIL: hook output doesn't mention the active topic (got: $out)" >&2; exit 1; }
pass "2. hook fires in proj-A (local active-<sid>.txt detected)"

# CLONE_WARS_HOME override does NOT affect the hook (it uses $PWD directly)
export CLONE_WARS_HOME="$SANDBOX/proj-A/.clone-wars"
cd "$SANDBOX/proj-B"   # cwd is proj-B, but env points at proj-A
out=$(printf '%s' "$PAYLOAD" | bash "$HOOK" 2>&1)
# v0.31.0 hook uses $PWD/.clone-wars/state directly — production semantics
# unconditional, no inheritance of the CLONE_WARS_HOME test seam.
[[ -z "$out" ]] || { echo "FAIL: hook should ignore CLONE_WARS_HOME (uses \$PWD directly per v0.31.0 spec); got: $out" >&2; exit 1; }
unset CLONE_WARS_HOME
pass "3. hook uses \$PWD directly (independent of CLONE_WARS_HOME seam)"

echo "test_hook_project_local_scope: 3 cases passed"
