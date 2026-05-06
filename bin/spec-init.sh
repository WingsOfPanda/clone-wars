#!/usr/bin/env bash
# bin/spec-init.sh — resolve seed path and topic for /clone-wars:spec.
# Usage: spec-init.sh [<seed.md>]
#   With arg:   validate file exists, echo "TOPIC=<extracted>\nSEED=<resolved-abs>"
#   Without:    scan archive + state, pick most recent by mtime.
set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"

SEED="${1:-}"
if [[ -n "$SEED" ]]; then
  [[ -f "$SEED" ]] || { log_error "seed not found: $SEED"; exit 2; }
  SEED=$(readlink -f "$SEED")
else
  REPO_HASH=$(cw_repo_hash)
  STATE_ROOT=$(cw_state_root)
  SEED=$(find "$STATE_ROOT/archive/$REPO_HASH" "$STATE_ROOT/state/$REPO_HASH" \
              -path '*/_consult/synthesis.md' -type f -printf '%T@ %p\n' 2>/dev/null \
         | sort -n | tail -1 | cut -d' ' -f2-)
  [[ -n "$SEED" ]] || { log_error "no synthesis.md found; pass an explicit path"; exit 1; }
fi

TOPIC=$(basename "$(dirname "$(dirname "$SEED")")")
[[ -n "$TOPIC" && "$TOPIC" != "/" ]] || { log_error "cannot extract topic from $SEED"; exit 1; }

printf 'TOPIC=%s\nSEED=%s\n' "$TOPIC" "$SEED"
