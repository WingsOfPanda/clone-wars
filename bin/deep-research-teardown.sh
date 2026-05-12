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

ts=$(date -u +%Y%m%dT%H%M%SZ)
archive_dir="$state_root/archive/$repo_hash/${TOPIC}-${ts}"
mkdir -p "$(dirname "$archive_dir")"
mv "$state_dir" "$archive_dir"
log_ok "[teardown] archived $TOPIC → $archive_dir"
printf '%s\n' "$archive_dir"
