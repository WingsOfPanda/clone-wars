#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/consult.sh"

# Provider → commander mapping (locked in v0.15.0 spec)
out=$(cw_consult_provider_to_commander codex);    assert_eq "$out" "rex"  "codex → rex"
out=$(cw_consult_provider_to_commander claude);   assert_eq "$out" "cody" "claude → cody"
out=$(cw_consult_provider_to_commander opencode); assert_eq "$out" "bly"  "opencode → bly"

# Unknown provider → rc=1
cw_consult_provider_to_commander gemini 2>/dev/null && { echo FAIL: gemini should error; exit 1; }
pass "unknown provider returns rc=1"

# Eligible-providers filter: keeps codex/claude/opencode in input order, drops others.
out=$(printf '%s\n' codex claude gemini opencode | cw_consult_eligible_providers)
assert_eq "$out" $'codex\nclaude\nopencode' "filter drops gemini"

# Load troopers: TSV reader with trailing newline tolerance.
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/troopers.txt" <<TSV
# header
codex	rex
claude	cody
opencode	bly
TSV
mapfile -t lines < <(cw_consult_load_troopers "$TMP/troopers.txt")
assert_eq "${#lines[@]}" "3" "3 trooper lines parsed"
assert_eq "${lines[0]}" "codex	rex"  "first line"
pass "cw_consult_load_troopers parses TSV with header comment"
