#!/usr/bin/env bash
# tests/test_deploy_teardown_preflight_orphans.sh
# Mirrors test_consult_teardown_preflight_orphans.sh but for /clone-wars:deploy.
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
source "$PLUGIN_ROOT/lib/deploy.sh"

TOPIC="dpl-orph-$$"
REPO_HASH=$(cw_repo_hash)
ART_DIR="$CLONE_WARS_HOME/state/$REPO_HASH/$TOPIC/_deploy"
mkdir -p "$ART_DIR"

# Open isolated test window with 3 panes
TEST_WIN="cw-deploy-orph-$$-${RANDOM}"
tmux new-window -d -n "$TEST_WIN"
trap 'tmux kill-window -t "$TEST_WIN" 2>/dev/null || true; rm -rf "$SANDBOX"' EXIT
sleep 0.3

BASE_PANE=$(tmux list-panes -t "$TEST_WIN" -F '#{pane_id}' | head -1)
PANE1=$(tmux split-window -P -F '#{pane_id}' -t "$BASE_PANE" -h 'sleep infinity')
PANE2=$(tmux split-window -P -F '#{pane_id}' -t "$PANE1" -v 'sleep infinity')
PANE3=$(tmux split-window -P -F '#{pane_id}' -t "$PANE2" -v 'sleep infinity')

# preflight-panes has 3; troopers.txt only has 2 → PANE3 is orphan
cat > "$ART_DIR/preflight-panes.txt" <<EOF
rex	$PANE1
wolffe	$PANE2
bly	$PANE3
EOF
cat > "$ART_DIR/troopers.txt" <<EOF
rex	$SANDBOX/auth	codex
wolffe	$SANDBOX/api	codex
EOF

# Stub state dirs for rex+wolffe so bin/teardown.sh (called by deploy-teardown)
# can find their pane.json files and kill PANE1+PANE2. Without these stubs,
# bin/teardown.sh sees no trooper state and the live panes stay alive.
# (Mirrors test_consult_teardown_preflight_orphans.sh's stub pattern.)
mkdir -p "$SANDBOX/auth" "$SANDBOX/api"
echo "init" > "$SANDBOX/auth/CLAUDE.md"
echo "init" > "$SANDBOX/api/CLAUDE.md"
for cmdr_pane in "rex:codex:$PANE1" "wolffe:codex:$PANE2"; do
  IFS=: read -r cmdr provider pane <<<"$cmdr_pane"
  trooper_dir="$CLONE_WARS_HOME/state/$REPO_HASH/$TOPIC/$cmdr-$provider"
  mkdir -p "$trooper_dir"
  printf '{"pane_id":"%s","pid":1,"spawned_at":"2026-05-09T00:00:00Z"}\n' "$pane" > "$trooper_dir/pane.json"
done

# Invoke deploy-teardown
"$PLUGIN_ROOT/bin/deploy-teardown.sh" "$TOPIC" 2>&1 || true
sleep 0.5

# All 3 preflight panes should be killed
for p in "$PANE1" "$PANE2" "$PANE3"; do
  if tmux list-panes -a -F '#{pane_id}' | grep -qx "$p"; then
    echo "FAIL: pane $p still alive after deploy-teardown" >&2; exit 1
  fi
done

# preflight-panes.txt should be removed by orphan extension
[[ ! -f "$ART_DIR/preflight-panes.txt" ]] \
  || { echo "FAIL: preflight-panes.txt should be removed by deploy-teardown" >&2; exit 1; }

pass "deploy-teardown kills preflight orphan panes (PANE3 not in troopers.txt)"
