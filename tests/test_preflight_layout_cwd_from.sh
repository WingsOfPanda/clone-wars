#!/usr/bin/env bash
# tests/test_preflight_layout_cwd_from.sh
# v0.20.3: preflight --cwd-from places each sentinel pane in the assigned cwd.
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

# Build two stub sub-repo dirs (must exist; tmux split-window -c requires
# the target directory to exist).
DIR_A=$(mktemp -d)
DIR_B=$(mktemp -d)

TOPIC="cwdfrom-test-$$"
REPO_HASH=$(cw_repo_hash)
ART_DIR="$CLONE_WARS_HOME/state/$REPO_HASH/$TOPIC/_consult"
mkdir -p "$ART_DIR"

# Roster: 2 troopers in consult shape (provider TAB commander)
cat > "$ART_DIR/troopers.txt" <<EOF
codex	rex
claude	cody
EOF

# CMDR_TO_CWD map: rex → DIR_A, cody → DIR_B
cat > "$ART_DIR/cmdr-cwd-map.txt" <<EOF
rex	$DIR_A
cody	$DIR_B
EOF

TEST_WIN="cw-cwdfrom-$$-${RANDOM}"
tmux new-window -d -n "$TEST_WIN"
trap 'tmux kill-window -t "$TEST_WIN" 2>/dev/null || true; rm -rf "$SANDBOX" "$DIR_A" "$DIR_B"; rm -f /tmp/cw-cwdfrom-rc-$$.log' EXIT
YODA_PANE=$(tmux list-panes -t "$TEST_WIN" -F '#{pane_id}' | head -1)
sleep 0.5

LOG_FILE="/tmp/cw-cwdfrom-rc-$$.log"
tmux send-keys -t "$YODA_PANE" \
  "CLAUDE_PLUGIN_ROOT='$PLUGIN_ROOT' CLONE_WARS_HOME='$CLONE_WARS_HOME' bash '$PLUGIN_ROOT/bin/preflight-layout.sh' --art-dir '$ART_DIR' --cwd-from '$ART_DIR/cmdr-cwd-map.txt' '$TOPIC' 2 > '$LOG_FILE' 2>&1; echo PFRC=\$? >> '$LOG_FILE'" Enter

got_pfrc=""
for _ in $(seq 1 30); do
  if [[ -f "$LOG_FILE" ]]; then
    line=$(grep '^PFRC=' "$LOG_FILE" 2>/dev/null | tail -1 || true)
    if [[ "$line" == "PFRC=0" ]]; then got_pfrc=0; break; fi
    if [[ "$line" == "PFRC=1" ]]; then got_pfrc=1; break; fi
    if [[ "$line" == "PFRC=2" ]]; then got_pfrc=2; break; fi
  fi
  sleep 0.5
done
[[ "$got_pfrc" == "0" ]] || { echo "FAIL: preflight rc=$got_pfrc"; cat "$LOG_FILE" >&2; exit 1; }

PFP="$ART_DIR/preflight-panes.txt"
assert_file_exists "$PFP" "preflight-panes.txt written"
mapfile -t LINES < "$PFP"
[[ ${#LINES[@]} -eq 2 ]] || { echo "FAIL: expected 2 lines in preflight-panes.txt, got ${#LINES[@]}" >&2; exit 1; }

# Verify each pane's pane_current_path matches the assigned cwd
for line in "${LINES[@]}"; do
  cmdr="${line%%$'\t'*}"
  pane="${line#*$'\t'}"
  expected_cwd=""
  case "$cmdr" in
    rex)  expected_cwd="$DIR_A" ;;
    cody) expected_cwd="$DIR_B" ;;
    *)    echo "FAIL: unexpected cmdr '$cmdr'" >&2; exit 1 ;;
  esac
  actual_cwd=$(tmux display-message -p -t "$pane" '#{pane_current_path}')
  [[ "$actual_cwd" == "$expected_cwd" ]] \
    || { echo "FAIL: pane $pane ($cmdr) cwd '$actual_cwd' != '$expected_cwd'" >&2; exit 1; }
done

pass "preflight --cwd-from: each pane allocated in its assigned sub-repo cwd"
