#!/usr/bin/env bash
# tests/test_deep_research_teardown_preflight_orphans.sh — v0.28.3 teardown extension.
# Mirrors test_consult_teardown_preflight_orphans.sh / test_deploy_teardown_preflight_orphans.sh
# but exercises bin/deep-research-teardown.sh's new orphan-cleanup block.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

[[ -n "${TMUX:-}" ]] || { echo "  SKIP: no tmux session ($TMUX unset)" >&2; exit 0; }
command -v tmux >/dev/null || { echo "  SKIP: tmux not on PATH" >&2; exit 0; }

PLUGIN_ROOT="$(cd .. && pwd)"
SANDBOX=$(mktemp -d)
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
export CLONE_WARS_HOME="$SANDBOX/.clone-wars"
mkdir -p "$CLONE_WARS_HOME"

source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"

TOPIC="deep-research-orph-$$"
REPO_HASH=$(cw_repo_hash)
ART_DIR="$CLONE_WARS_HOME/state/$REPO_HASH/$TOPIC/_deep-research"
mkdir -p "$ART_DIR"

# Open isolated test window with 3 panes
TEST_WIN="cw-dr-orph-$$-${RANDOM}"
tmux new-window -d -n "$TEST_WIN"
trap 'tmux kill-window -t "$TEST_WIN" 2>/dev/null || true; rm -rf "$SANDBOX"' EXIT
sleep 0.3

BASE_PANE=$(tmux list-panes -t "$TEST_WIN" -F '#{pane_id}' | head -1)
PANE1=$(tmux split-window -P -F '#{pane_id}' -t "$BASE_PANE" -h 'sleep infinity')
PANE2=$(tmux split-window -P -F '#{pane_id}' -t "$PANE1" -v 'sleep infinity')
PANE3=$(tmux split-window -P -F '#{pane_id}' -t "$PANE2" -v 'sleep infinity')

# preflight-panes.txt has 3 commanders; troopers.txt has only 2 → PANE3 (commander="cody")
# is an orphan that the teardown extension must kill.
cat > "$ART_DIR/preflight-panes.txt" <<EOF
rex	$PANE1
keeli	$PANE2
cody	$PANE3
EOF
# Native deep-research troopers.txt is 1-col commander-only (no provider column).
cat > "$ART_DIR/troopers.txt" <<EOF
rex
keeli
EOF

# Invoke deep-research-teardown directly (bypasses bin/teardown.sh --pairs which
# the directive normally calls first — we're testing the orphan-cleanup logic
# in isolation, not the end-to-end Phase 6 sequence).
"$PLUGIN_ROOT/bin/deep-research-teardown.sh" "$TOPIC" 2>&1 || {
  echo "FAIL: deep-research-teardown.sh exited non-zero" >&2; exit 1;
}
sleep 0.5

# PANE3 (orphan) should be killed by the extension
if tmux list-panes -a -F '#{pane_id}' | grep -qx "$PANE3"; then
  echo "FAIL: orphan pane $PANE3 still alive after deep-research-teardown" >&2; exit 1
fi
pass "orphan pane (commander not in troopers.txt) killed"

# PANE1 + PANE2 (non-orphans) should NOT have been touched by the extension
# (they would normally be killed by bin/teardown.sh --pairs in Phase 6, which
# this test does NOT invoke). So they should still be alive.
for p in "$PANE1" "$PANE2"; do
  tmux list-panes -a -F '#{pane_id}' | grep -qx "$p" \
    || { echo "FAIL: non-orphan pane $p was killed (extension should leave it alone)" >&2; exit 1; }
done
pass "non-orphan panes left alone by extension (PANE1, PANE2 still alive)"

# preflight-panes.txt should have been removed by cw_preflight_kill_orphans on success.
# Note: the topic dir was archived (mv), so check the archive path.
ARCHIVE=$(find "$CLONE_WARS_HOME/archive/$REPO_HASH" -maxdepth 1 -type d -name "${TOPIC}-*" | head -1)
[[ -n "$ARCHIVE" ]] || { echo "FAIL: archive dir not created" >&2; exit 1; }
[[ ! -f "$ARCHIVE/_deep-research/preflight-panes.txt" ]] \
  || { echo "FAIL: preflight-panes.txt should be removed by orphan cleanup before archive" >&2; exit 1; }
pass "preflight-panes.txt removed by orphan cleanup"

echo "test_deep_research_teardown_preflight_orphans: 3 cases passed"
