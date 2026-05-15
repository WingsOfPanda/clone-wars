#!/usr/bin/env bash
# tests/test_user_prompt_submit_hook.sh — v0.28.0 UserPromptSubmit hook
# v0.31.0: hook scans $PWD/.clone-wars/state directly (no CLONE_WARS_HOME
# inheritance), so the sandbox cds into a project-local layout.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Sandbox: project-local layout. cw_state_root resolves to $PWD/.clone-wars
# in v0.31.0; the hook reads $PWD/.clone-wars/state directly. Unsetting
# CLONE_WARS_HOME ensures the lib helpers don't pick up an env-overridden
# path during cw_repo_hash computation.
unset CLONE_WARS_HOME
PROJ="$TMP/proj"
mkdir -p "$PROJ"
cd "$PROJ"

source "$PLUGIN_ROOT/lib/state.sh"
REPO_HASH=$(cw_repo_hash)
HOOK="$PLUGIN_ROOT/hooks/user-prompt-submit-active-session.sh"

# Case A: no active sessions → exit 0, empty stdout
mkdir -p "$PROJ/.clone-wars/state/$REPO_HASH"
OUT=$("$HOOK"); rc=$?
[[ "$rc" == "0" ]] || { echo "FAIL: hook rc=$rc when no active.txt" >&2; exit 1; }
[[ -z "$OUT" ]] || { echo "FAIL: hook should emit nothing when no active session, got: $OUT" >&2; exit 1; }
pass "no active session → exit 0, empty stdout"

# Case B: active.txt exists → emit context block referencing resume directive
TOPIC=deep-research-hooktest
mkdir -p "$PROJ/.clone-wars/state/$REPO_HASH/$TOPIC/_deep-research"
echo "$TOPIC" > "$PROJ/.clone-wars/state/$REPO_HASH/$TOPIC/_deep-research/active.txt"

OUT=$("$HOOK"); rc=$?
[[ "$rc" == "0" ]] || { echo "FAIL: hook rc=$rc when active.txt exists" >&2; exit 1; }
assert_contains "$OUT" "clone-wars:deep-research active session" "marker phrase"
assert_contains "$OUT" "$TOPIC" "topic slug surfaced"
assert_contains "$OUT" "commands/deep-research-resume.md" "resume directive path"
pass "active session → context block emitted"
