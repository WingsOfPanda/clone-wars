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

[[ $# -eq 1 ]] || { echo "Usage: $0 <topic>" >&2; exit 2; }
TOPIC="$1"
cw_deploy_assert_topic "$TOPIC"

ART_DIR=$(cw_deploy_art_dir "$TOPIC")

"$PLUGIN_ROOT/bin/teardown.sh" "$TOPIC" || true

# v0.20.0: also kill any preflight pane that is NOT in troopers.txt
# (orphan sentinel left over from Stage 2 partial-success abort, fix-loop
# "give up" abort, or pre-spawn Ctrl-C). Idempotent — safe when
# preflight-panes.txt is absent (single-repo deploys + pre-v0.20 archived).
PFP_FILE="$ART_DIR/preflight-panes.txt"
if [[ -f "$PFP_FILE" ]]; then
  declare -A LIVE_CMDRS=()
  if [[ -f "$ART_DIR/troopers.txt" ]]; then
    while IFS=$'\t' read -r cmdr cwd provider; do
      [[ -n "$cmdr" ]] && LIVE_CMDRS["$cmdr"]=1
    done < "$ART_DIR/troopers.txt"
  fi
  while IFS=$'\t' read -r cmdr pane; do
    [[ -n "$cmdr" && -n "$pane" ]] || continue
    [[ "${LIVE_CMDRS[$cmdr]:-0}" == "1" ]] && continue  # not orphan
    log_info "killing preflight orphan pane $pane (commander=$cmdr)"
    tmux kill-pane -t "$pane" 2>/dev/null || log_warn "kill-pane $pane failed (already dead?)"
  done < "$PFP_FILE"
  rm -f "$PFP_FILE"
fi
