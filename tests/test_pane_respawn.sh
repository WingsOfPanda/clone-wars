#!/usr/bin/env bash
# tests/test_pane_respawn.sh
# Unit test for cw_pane_respawn — verifies it replaces pane content via
# tmux respawn-pane -k and re-stamps @cw_label / @cw_color / @cw_label_fmt.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

[[ -n "${TMUX:-}" ]] || { echo "  SKIP: no tmux session ($TMUX unset)" >&2; exit 0; }
command -v tmux >/dev/null || { echo "  SKIP: tmux not on PATH" >&2; exit 0; }

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/colors.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/tmux.sh"

TEST_WIN="cw-respawn-$$-${RANDOM}"
tmux new-window -d -n "$TEST_WIN" 'sleep infinity'
trap 'tmux kill-window -t "$TEST_WIN" 2>/dev/null || true' EXIT

# Create a sacrificial pane with a known sentinel command
TARGET=$(tmux split-window -P -F '#{pane_id}' -t "$TEST_WIN" -h 'echo SENTINEL_BEFORE; sleep infinity')
sleep 0.5

# Capture sentinel content to confirm the "before" state
before=$(tmux capture-pane -p -t "$TARGET")
[[ "$before" == *"SENTINEL_BEFORE"* ]] || { echo "FAIL: sentinel not visible before respawn" >&2; exit 1; }

# Call cw_pane_respawn — should replace sentinel with new launch
result=$(cw_pane_respawn "$TARGET" rex codex test-topic 'echo SENTINEL_AFTER; sleep infinity')
sleep 0.5

# Result should echo the same pane id back
assert_eq "$result" "$TARGET" "cw_pane_respawn returns the pane id"

# Pane content should now show the new sentinel
after=$(tmux capture-pane -p -t "$TARGET")
[[ "$after" == *"SENTINEL_AFTER"* ]] || { echo "FAIL: new sentinel not visible after respawn (saw: $after)" >&2; exit 1; }

# Labels should be stamped
label=$(tmux display-message -p -t "$TARGET" '#{@cw_label}')
[[ -n "$label" ]] || { echo "FAIL: @cw_label not stamped" >&2; exit 1; }
assert_contains "$label" "rex" "label contains commander"

color=$(tmux display-message -p -t "$TARGET" '#{@cw_color}')
[[ -n "$color" ]] || { echo "FAIL: @cw_color not stamped" >&2; exit 1; }

pass "cw_pane_respawn replaces pane content + stamps @cw_* labels"
