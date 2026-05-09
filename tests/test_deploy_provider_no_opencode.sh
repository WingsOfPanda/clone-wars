#!/usr/bin/env bash
# tests/test_deploy_provider_no_opencode.sh
# Verifies cw_deploy_detect_provider rejects --provider opencode.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/deploy.sh"

# Test A: override "opencode" → rc!=0 + clear error
err=$(cw_deploy_detect_provider "$PWD" "opencode" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: opencode override should rc!=0" >&2; exit 1; }
echo "$err" | grep -qi 'opencode' || { echo "FAIL: error should mention opencode: $err" >&2; exit 1; }
echo "$err" | grep -qi 'codex\|claude' || { echo "FAIL: error should suggest codex/claude: $err" >&2; exit 1; }
pass "cw_deploy_detect_provider rejects --provider opencode"

# Test B: codex override still works
result=$(cw_deploy_detect_provider "$PWD" "codex")
assert_eq "$result" "codex" "codex override accepted"

# Test C: claude override still works
result=$(cw_deploy_detect_provider "$PWD" "claude")
assert_eq "$result" "claude" "claude override accepted"

# Test D: unknown override → rc!=0
err=$(cw_deploy_detect_provider "$PWD" "gemini" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: unknown override should rc!=0" >&2; exit 1; }
pass "cw_deploy_detect_provider rejects unknown override"

# Test E: no override + no plugin.json → codex (existing behavior)
SANDBOX=$(mktemp -d)
result=$(cw_deploy_detect_provider "$SANDBOX")
assert_eq "$result" "codex" "no override + no plugin.json → codex"
rm -rf "$SANDBOX"

# Test F: no override + plugin.json present → claude
SANDBOX2=$(mktemp -d)
mkdir -p "$SANDBOX2/.claude-plugin"
echo '{}' > "$SANDBOX2/.claude-plugin/plugin.json"
result=$(cw_deploy_detect_provider "$SANDBOX2")
assert_eq "$result" "claude" "no override + plugin.json → claude"
rm -rf "$SANDBOX2"

pass "cw_deploy_detect_provider auto-detect unchanged for codex/claude"
