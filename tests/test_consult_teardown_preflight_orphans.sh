#!/usr/bin/env bash
# tests/test_consult_teardown_preflight_orphans.sh
# Verifies bin/consult-teardown.sh kills preflight panes that are NOT in
# troopers.txt (orphan from Stage 2 partial-success abort or pre-spawn Ctrl-C).
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
source "$PLUGIN_ROOT/lib/consult.sh"

TOPIC="consult-orphan-test-$$"
REPO_HASH=$(cw_repo_hash)
ART_DIR="$CLONE_WARS_HOME/state/$REPO_HASH/$TOPIC/_consult"
mkdir -p "$ART_DIR"

# Open isolated test window with 3 panes
TEST_WIN="cw-orphan-$$-${RANDOM}"
tmux new-window -d -n "$TEST_WIN"
trap 'tmux kill-window -t "$TEST_WIN" 2>/dev/null || true; rm -rf "$SANDBOX"' EXIT
sleep 0.3

# Find the test window's first pane
BASE_PANE=$(tmux list-panes -t "$TEST_WIN" -F '#{pane_id}' | head -1)

# Create 3 sentinel panes inside the test window
PANE1=$(tmux split-window -P -F '#{pane_id}' -t "$BASE_PANE" -h 'sleep infinity')
PANE2=$(tmux split-window -P -F '#{pane_id}' -t "$PANE1" -v 'sleep infinity')
PANE3=$(tmux split-window -P -F '#{pane_id}' -t "$PANE2" -v 'sleep infinity')

# preflight-panes has 3; troopers.txt only has 2 → PANE3 is orphan
cat > "$ART_DIR/preflight-panes.txt" <<EOF
rex	$PANE1
cody	$PANE2
bly	$PANE3
EOF
cat > "$ART_DIR/troopers.txt" <<EOF
codex	rex
claude	cody
EOF

# Stub trooper state dirs so bin/teardown.sh on rex/cody can find something.
# (bin/teardown.sh expects a state dir per trooper to look up the pane id.)
for cmdr_pane in "rex:codex:$PANE1" "cody:claude:$PANE2"; do
  IFS=: read -r cmdr provider pane <<<"$cmdr_pane"
  trooper_dir="$CLONE_WARS_HOME/state/$REPO_HASH/$TOPIC/$cmdr-$provider"
  mkdir -p "$trooper_dir"
  printf '{"pane_id":"%s","pid":1,"spawned_at":"2026-05-09T00:00:00Z"}\n' "$pane" > "$trooper_dir/pane.json"
done

# Run consult-teardown — should iterate troopers.txt (rex+cody) AND clean orphan PANE3
"$PLUGIN_ROOT/bin/consult-teardown.sh" "$TOPIC" 2>&1 || true
sleep 0.5

# All 3 preflight panes should be dead (rex+cody via troopers.txt, bly via orphan path)
for p in "$PANE1" "$PANE2" "$PANE3"; do
  if tmux list-panes -a -F '#{pane_id}' | grep -qx "$p"; then
    echo "FAIL: pane $p still alive after teardown" >&2; exit 1
  fi
done

# preflight-panes.txt should be removed
[[ ! -f "$ART_DIR/preflight-panes.txt" ]] \
  || { echo "FAIL: preflight-panes.txt should be removed by teardown" >&2; exit 1; }

pass "consult-teardown kills preflight orphan panes (PANE3 not in troopers.txt)"
