#!/usr/bin/env bash
# tests/test_preflight_layout_rollback.sh
# Failure path: count-mismatch validation should rc=1 BEFORE any panes are
# created (early-exit), and no preflight-panes.txt should be written.
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

TOPIC="preflight-rb-$$"
REPO_HASH=$(cw_repo_hash)
ART_DIR="$CLONE_WARS_HOME/state/$REPO_HASH/$TOPIC/_consult"
mkdir -p "$ART_DIR"

# Inject failure: troopers.txt has only 2 entries but caller asks for N=3 →
# preflight should reject with rc=1 BEFORE any pane is created.
cat > "$ART_DIR/troopers.txt" <<EOF
codex	rex
claude	cody
EOF

TEST_WIN="cw-pfrb-$$-${RANDOM}"
tmux new-window -d -n "$TEST_WIN"
trap 'tmux kill-window -t "$TEST_WIN" 2>/dev/null || true; rm -rf "$SANDBOX"; rm -f /tmp/cw-pfrb-rc-test-$$.log' EXIT
YODA_PANE=$(tmux list-panes -t "$TEST_WIN" -F '#{pane_id}' | head -1)
sleep 0.5

LOG_FILE="/tmp/cw-pfrb-rc-test-$$.log"
tmux send-keys -t "$YODA_PANE" "CLAUDE_PLUGIN_ROOT='$PLUGIN_ROOT' CLONE_WARS_HOME='$CLONE_WARS_HOME' bash '$PLUGIN_ROOT/bin/preflight-layout.sh' '$TOPIC' 3 > '$LOG_FILE' 2>&1; echo PFRC=\$?" Enter

got_pfrc=""
for _ in $(seq 1 20); do
  out=$(tmux capture-pane -p -t "$YODA_PANE" 2>/dev/null)
  if [[ "$out" == *"PFRC=0"* ]]; then got_pfrc=0; break; fi
  if [[ "$out" == *"PFRC=1"* ]]; then got_pfrc=1; break; fi
  if [[ "$out" == *"PFRC=2"* ]]; then got_pfrc=2; break; fi
  sleep 0.5
done
[[ "$got_pfrc" == "1" ]] || { echo "FAIL: count-mismatch should rc=1 (got '$got_pfrc')" >&2; cat "$LOG_FILE" >&2 || true; exit 1; }

[[ ! -f "$ART_DIR/preflight-panes.txt" ]] \
  || { echo "FAIL: preflight-panes.txt should NOT exist on failure" >&2; exit 1; }
[[ ! -f "$ART_DIR/preflight-panes.txt.tmp" ]] \
  || { echo "FAIL: preflight-panes.txt.tmp should be cleaned up" >&2; exit 1; }

# Confirm only the original pane exists in the test window (no orphans)
n=$(tmux list-panes -t "$TEST_WIN" | wc -l)
[[ "$n" -eq 1 ]] || { echo "FAIL: expected 1 pane in test window after failure (got $n)" >&2; exit 1; }

pass "preflight rollback on count-mismatch: rc=1, no orphans, no preflight-panes.txt"
