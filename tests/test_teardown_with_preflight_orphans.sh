#!/usr/bin/env bash
# tests/test_teardown_with_preflight_orphans.sh — shared teardown helper contract.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

[[ -n "${TMUX:-}" ]] || { echo "  SKIP: no tmux session ($TMUX unset)" >&2; exit 0; }
command -v tmux >/dev/null || { echo "  SKIP: tmux not on PATH" >&2; exit 0; }

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/tmux.sh"

declare -F cw_teardown_with_preflight_orphans >/dev/null \
  || { echo "FAIL: cw_teardown_with_preflight_orphans not defined" >&2; exit 1; }
pass "helper defined"

TEST_WIN="cw-test-td-$$-${RANDOM}"
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"; tmux kill-window -t "$TEST_WIN" 2>/dev/null || true' EXIT

ART_DIR="$SANDBOX/_consult"
mkdir -p "$ART_DIR"

# Open isolated test window with 4 panes
tmux new-window -d -n "$TEST_WIN"
sleep 0.3
BASE_PANE=$(tmux list-panes -t "$TEST_WIN" -F '#{pane_id}' | head -1)
PANE1=$(tmux split-window -P -F '#{pane_id}' -t "$BASE_PANE" -h 'sleep infinity')
PANE2=$(tmux split-window -P -F '#{pane_id}' -t "$PANE1"     -v 'sleep infinity')
PANE3=$(tmux split-window -P -F '#{pane_id}' -t "$PANE2"     -v 'sleep infinity')

cat > "$ART_DIR/preflight-panes.txt" <<EOF
rex	$PANE1
keeli	$PANE2
cody	$PANE3
EOF

# 2-col TSV mode (consult/meditate): keep rex+keeli, drop cody
cat > "$ART_DIR/troopers.txt" <<EOF
codex	rex
codex	keeli
EOF

cw_teardown_with_preflight_orphans "$ART_DIR" "$ART_DIR/troopers.txt" 2col
sleep 0.5

tmux list-panes -a -F '#{pane_id}' | grep -qx "$PANE3" \
  && { echo "FAIL: 2col mode: orphan $PANE3 still alive" >&2; exit 1; }
pass "2col mode: orphan pane killed"

for p in "$PANE1" "$PANE2"; do
  tmux list-panes -a -F '#{pane_id}' | grep -qx "$p" \
    || { echo "FAIL: 2col mode: non-orphan $p was killed" >&2; exit 1; }
done
pass "2col mode: non-orphan panes preserved"

[[ ! -f "$ART_DIR/preflight-panes.txt" ]] \
  || { echo "FAIL: preflight-panes.txt should be removed after orphan-cleanup" >&2; exit 1; }
pass "preflight-panes.txt removed by orphan cleanup"

# 1col mode (deep-research): rebuild scenario with NEW panes
PANE1=$(tmux split-window -P -F '#{pane_id}' -t "$BASE_PANE" -h 'sleep infinity')
PANE2=$(tmux split-window -P -F '#{pane_id}' -t "$PANE1"     -v 'sleep infinity')
cat > "$ART_DIR/preflight-panes.txt" <<EOF
rex	$PANE1
keeli	$PANE2
EOF
cat > "$ART_DIR/troopers.txt" <<'EOF'
# comment line to test filter
rex
EOF

cw_teardown_with_preflight_orphans "$ART_DIR" "$ART_DIR/troopers.txt" 1col
sleep 0.5

tmux list-panes -a -F '#{pane_id}' | grep -qx "$PANE2" \
  && { echo "FAIL: 1col mode: orphan $PANE2 still alive" >&2; exit 1; }
pass "1col mode: orphan pane killed (comment lines filtered)"

tmux list-panes -a -F '#{pane_id}' | grep -qx "$PANE1" \
  || { echo "FAIL: 1col mode: non-orphan $PANE1 was killed" >&2; exit 1; }
pass "1col mode: non-orphan pane preserved"

# Bad mode rejected
set +e
cw_teardown_with_preflight_orphans "$ART_DIR" "$ART_DIR/troopers.txt" badmode 2>/dev/null
rc=$?
set -e
[[ "$rc" == "2" ]] || { echo "FAIL: bad mode should rc=2, got $rc" >&2; exit 1; }
pass "bad mode rejected with rc=2"

echo "test_teardown_with_preflight_orphans: 6 cases passed"
