#!/usr/bin/env bash
# bin/consult-archive.sh — move _consult/ to archive.
#
# Usage: bin/consult-archive.sh <consult-topic>

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/consult.sh"

[[ $# -eq 1 ]] || { echo "Usage: $0 <consult-topic>" >&2; exit 2; }
TOPIC="$1"
cw_consult_topic_validate "$TOPIC" || { log_error "invalid topic: $TOPIC"; exit 2; }

TOPIC_DIR="$(cw_consult_topic_dir "$TOPIC")"
ART_DIR="$TOPIC_DIR/_consult"
[[ -d "$ART_DIR" ]] || { log_error "$ART_DIR missing — already archived?"; exit 1; }

ARCHIVE_BASE="$(cw_state_root)/archive/$(cw_repo_hash)/$TOPIC"
mkdir -p "$ARCHIVE_BASE"
TS=$(date -u +'%Y%m%dT%H%M%SZ')
mv "$ART_DIR" "$ARCHIVE_BASE/_consult-$TS"
rmdir "$TOPIC_DIR" 2>/dev/null || true

log_ok "archived: $ARCHIVE_BASE/_consult-$TS"
