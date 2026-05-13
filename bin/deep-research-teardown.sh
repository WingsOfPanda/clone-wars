#!/usr/bin/env bash
# bin/deep-research-teardown.sh — archive a /clone-wars:deep-research topic state dir.
#
# Usage: bin/deep-research-teardown.sh <topic>
#
# Per-round commander panes are torn down inline by the directive via
# bin/teardown.sh --pairs after each round (batched 9s graceful banner).
# This script handles the final archive of the entire topic state dir to
# ~/.clone-wars/archive/. Parallels bin/meditate-teardown.sh.

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/tmux.sh"

[[ $# -eq 1 ]] || { echo "Usage: $0 <topic>" >&2; exit 2; }
TOPIC="$1"
[[ "$TOPIC" == deep-research-* ]] \
  || { log_error "topic must start with 'deep-research-': $TOPIC"; exit 2; }
cw_consult_topic_validate "$TOPIC" \
  || { log_error "invalid topic: $TOPIC"; exit 2; }

state_root="${CLONE_WARS_HOME:-$HOME/.clone-wars}"
repo_hash=$(cw_repo_hash)
state_dir="$state_root/state/$repo_hash/$TOPIC"
[[ -d "$state_dir" ]] || { log_error "$state_dir not found"; exit 1; }

# v0.28.3: kill preflight orphan panes (sentinels that never got respawned)
# before the archive mv. Reads <state_dir>/_deep-research/preflight-panes.txt;
# kills panes whose commander is NOT in the 1-col troopers.txt. No-op if
# preflight-panes.txt is absent (pre-v0.28.3 archives + happy-path runs where
# the file was already removed elsewhere).
ART_DIR="$state_dir/_deep-research"
PREFLIGHT_FILE="$ART_DIR/preflight-panes.txt"
TROOPERS_FILE="$ART_DIR/troopers.txt"
LIVE_CMDRS=()
if [[ -f "$TROOPERS_FILE" ]]; then
  while IFS= read -r cmdr; do
    [[ -n "$cmdr" && "${cmdr:0:1}" != "#" ]] && LIVE_CMDRS+=("$cmdr")
  done < "$TROOPERS_FILE"
fi
cw_preflight_kill_orphans "$PREFLIGHT_FILE" "${LIVE_CMDRS[@]}"

ts=$(date -u +%Y%m%dT%H%M%SZ)
archive_dir="$state_root/archive/$repo_hash/${TOPIC}-${ts}"
mkdir -p "$(dirname "$archive_dir")"
mv "$state_dir" "$archive_dir"
log_ok "[teardown] archived $TOPIC → $archive_dir"
printf '%s\n' "$archive_dir"
