#!/usr/bin/env bash
# bin/deploy-archive.sh — move _deploy/ to archive.
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
[[ -d "$ART_DIR" ]] || { log_error "$ART_DIR missing — already archived?"; exit 1; }

ARCHIVE_BASE="$(cw_state_root)/archive/$(cw_topic_repo_hash)/$TOPIC"
mkdir -p "$ARCHIVE_BASE" || { log_error "mkdir failed: $ARCHIVE_BASE"; exit 1; }
TS=$(date -u +'%Y%m%dT%H%M%SZ')
DEST="$ARCHIVE_BASE/_deploy-$TS"
n=2
while [[ -e "$DEST" ]]; do
  DEST="$ARCHIVE_BASE/_deploy-$TS-$n"
  n=$((n + 1))
  (( n > 99 )) && { log_error "too many same-second archive collisions; aborting"; exit 1; }
done
mv "$ART_DIR" "$DEST" \
  || { log_error "mv failed: $ART_DIR -> $DEST"; exit 1; }
rmdir "$TOPIC_DIR" 2>/dev/null || true

log_ok "archived: $DEST"
