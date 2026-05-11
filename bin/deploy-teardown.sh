#!/usr/bin/env bash
# bin/deploy-teardown.sh — kill cody pane via shared teardown.
# v0.20.0: also cleans preflight orphan panes for multi-repo deploys
# (mirrors v0.19.0 consult-teardown's orphan-cleanup extension).
# Usage: bin/deploy-teardown.sh <topic>

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deploy.sh"
source "$PLUGIN_ROOT/lib/tmux.sh"

[[ $# -eq 1 ]] || { echo "Usage: $0 <topic>" >&2; exit 2; }
TOPIC="$1"
cw_deploy_assert_topic "$TOPIC"

ART_DIR=$(cw_deploy_art_dir "$TOPIC")

"$PLUGIN_ROOT/bin/teardown.sh" "$TOPIC" || true

# v0.20.0: also kill any preflight pane that is NOT in troopers.txt
# (orphan sentinel left over from Stage 2 partial-success abort, fix-loop
# "give up" abort, or pre-spawn Ctrl-C). Helper extracted to lib/tmux.sh
# in v0.24.0.
LIVE_CMDRS=()
if [[ -f "$ART_DIR/troopers.txt" ]]; then
  while IFS=$'\t' read -r cmdr cwd provider; do
    [[ -n "$cmdr" ]] && LIVE_CMDRS+=("$cmdr")
  done < "$ART_DIR/troopers.txt"
fi
cw_preflight_kill_orphans "$ART_DIR/preflight-panes.txt" "${LIVE_CMDRS[@]}"
