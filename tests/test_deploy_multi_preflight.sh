#!/usr/bin/env bash
# tests/test_deploy_multi_preflight.sh
# Tmux-dep: bin/preflight-layout.sh --art-dir <deploy-art-dir> allocates
# K=3 evenly-sized panes for the v0.20.0 multi-repo deploy flow.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

[[ -n "${TMUX:-}" ]] || { echo "  SKIP: no tmux session ($TMUX unset)" >&2; exit 0; }
command -v tmux >/dev/null || { echo "  SKIP: tmux not on PATH" >&2; exit 0; }

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

SANDBOX=$(mktemp -d)
export CLONE_WARS_HOME="$SANDBOX/.clone-wars"
mkdir -p "$CLONE_WARS_HOME"

source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"

TOPIC="dpl-mpf-$$"
REPO_HASH=$(cw_repo_hash)
ART_DIR="$CLONE_WARS_HOME/state/$REPO_HASH/$TOPIC/_deploy"
mkdir -p "$ART_DIR"

# preflight-layout.sh expects troopers.txt with TSV. For deploy multi-repo,
# the format is <commander>\t<cwd>\t<provider>. preflight-layout.sh uses
# cw_consult_load_troopers which is a generic 2-col reader and tolerates
# extra columns.
cat > "$ART_DIR/troopers.txt" <<EOF
rex	/tmp/auth	codex
wolffe	/tmp/api	codex
bly	/tmp/ui	codex
EOF

TEST_WIN="cw-deploy-pf-$$-${RANDOM}"
tmux new-window -d -n "$TEST_WIN"
trap 'tmux kill-window -t "$TEST_WIN" 2>/dev/null || true; rm -rf "$SANDBOX"; rm -f /tmp/cw-deploy-pf-$$.log' EXIT
sleep 0.5

YODA_PANE=$(tmux list-panes -t "$TEST_WIN" -F '#{pane_id}' | head -1)
LOG_FILE="/tmp/cw-deploy-pf-$$.log"

# Write PFRC into the log file (mirrors v0.19.0 stable preflight test pattern).
tmux send-keys -t "$YODA_PANE" "CLAUDE_PLUGIN_ROOT='$PLUGIN_ROOT' CLONE_WARS_HOME='$CLONE_WARS_HOME' bash '$PLUGIN_ROOT/bin/preflight-layout.sh' --art-dir '$ART_DIR' '$TOPIC' 3 > '$LOG_FILE' 2>&1; echo PFRC=\$? >> '$LOG_FILE'" Enter

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
[[ "$got_pfrc" == "0" ]] || { echo "FAIL: preflight rc=$got_pfrc" >&2; if [[ -f "$LOG_FILE" ]]; then cat "$LOG_FILE" >&2; fi; exit 1; }

# Verify preflight-panes.txt was written under the deploy art-dir
PFP="$ART_DIR/preflight-panes.txt"
assert_file_exists "$PFP" "preflight-panes.txt written under deploy art-dir"

mapfile -t LINES < "$PFP"
[[ ${#LINES[@]} -eq 3 ]] || { echo "FAIL: expected 3 lines in preflight-panes.txt (got ${#LINES[@]})" >&2; exit 1; }

# Heights within ±5 rows
heights=()
for line in "${LINES[@]}"; do
  pane="${line#*$'\t'}"
  heights+=( "$(tmux display-message -p -t "$pane" '#{pane_height}')" )
done
hmin=${heights[0]}; hmax=${heights[0]}
for h in "${heights[@]}"; do
  (( h < hmin )) && hmin=$h
  (( h > hmax )) && hmax=$h
done
diff=$(( hmax - hmin ))
(( diff <= 5 )) || { echo "FAIL: pane heights uneven (min=$hmin max=$hmax diff=$diff)" >&2; exit 1; }

pass "bin/preflight-layout.sh --art-dir <deploy>: K=3 panes allocated under _deploy/, even heights"
