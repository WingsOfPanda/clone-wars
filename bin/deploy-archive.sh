#!/usr/bin/env bash
# bin/deploy-archive.sh — move _deploy/ to archive.
#
# v0.29.0: thin wrapper around cw_state_archive_dir (lib/state.sh).
#
# Usage: bin/deploy-archive.sh <topic>

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deploy.sh"

[[ $# -eq 1 ]] || { echo "Usage: $0 <topic>" >&2; exit 2; }
TOPIC="$1"
cw_deploy_assert_topic "$TOPIC"

TOPIC_DIR="$(cw_deploy_topic_dir "$TOPIC")"
ART_DIR="$TOPIC_DIR/_deploy"
ARCHIVE_BASE="$(cw_global_state_root)/archive/$(cw_topic_repo_hash)/$TOPIC"

DEST=$(cw_state_archive_dir "$ART_DIR" "$ARCHIVE_BASE" "_deploy") || exit 1
rmdir "$TOPIC_DIR" 2>/dev/null || true

log_ok "archived: $DEST"
