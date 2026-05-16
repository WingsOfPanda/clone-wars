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
source "$PLUGIN_ROOT/lib/deep-research.sh"
source "$PLUGIN_ROOT/lib/tmux.sh"

[[ $# -eq 1 ]] || { echo "Usage: $0 <topic>" >&2; exit 2; }
TOPIC="$1"
cw_deep_research_assert_topic "$TOPIC"

state_root=$(cw_state_root)
repo_hash=$(cw_repo_hash)
state_dir="$state_root/state/$repo_hash/$TOPIC"
[[ -d "$state_dir" ]] || { log_error "$state_dir not found"; exit 1; }

# v0.29.0: shared helper handles 1-col troopers.txt parse + orphan kill +
# cleanup. No-op if preflight-panes.txt is absent (pre-v0.28.3 archives +
# happy-path runs where the file was already removed elsewhere).
ART_DIR="$state_dir/_deep-research"
TROOPERS_FILE="$ART_DIR/troopers.txt"
cw_teardown_with_preflight_orphans "$ART_DIR" "$TROOPERS_FILE" 1col

ts=$(date -u +%Y%m%dT%H%M%SZ)
# v0.38.0: archive is per-MACHINE (global), distinct from per-PROJECT state.
archive_dir="$(cw_global_state_root)/archive/$repo_hash/${TOPIC}-${ts}"
mkdir -p "$(dirname "$archive_dir")"
mv "$state_dir" "$archive_dir"
log_ok "[teardown] archived $TOPIC → $archive_dir"
printf '%s\n' "$archive_dir"
