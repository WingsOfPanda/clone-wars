#!/usr/bin/env bash
# bin/execute-design-archive.sh — move _execute/ to archive.
# Usage: bin/execute-design-archive.sh <topic>

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/execute_design.sh"

[[ $# -eq 1 ]] || { echo "Usage: $0 <topic>" >&2; exit 2; }
TOPIC="$1"
cw_execute_design_assert_topic "$TOPIC"

TOPIC_DIR="$(cw_execute_design_topic_dir "$TOPIC")"
ART_DIR="$TOPIC_DIR/_execute"
[[ -d "$ART_DIR" ]] || { log_error "$ART_DIR missing — already archived?"; exit 1; }

ARCHIVE_BASE="$(cw_state_root)/archive/$(cw_repo_hash)/$TOPIC"
mkdir -p "$ARCHIVE_BASE"
TS=$(date -u +'%Y%m%dT%H%M%SZ')
mv "$ART_DIR" "$ARCHIVE_BASE/_execute-$TS"
rmdir "$TOPIC_DIR" 2>/dev/null || true

log_ok "archived: $ARCHIVE_BASE/_execute-$TS"
