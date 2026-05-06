#!/usr/bin/env bash
# bin/spec-init.sh — resolve seed path and topic for /clone-wars:spec.
# Usage: spec-init.sh [<seed.md>]
#   With arg:   validate file exists, echo "TOPIC=<extracted>\nSEED=<resolved-abs>"
#   Without:    scan archive (then state) for most-recent _consult/synthesis.md
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$SCRIPT_DIR/../lib/state.sh"

SEED="${1:-}"
if [[ -n "$SEED" ]]; then
  [[ -f "$SEED" ]] || { echo "FAIL: seed not found: $SEED" >&2; exit 1; }
  SEED=$(readlink -f "$SEED")
else
  REPO_HASH=$(cw_repo_hash)
  STATE_ROOT="${CLONE_WARS_HOME:-$HOME/.clone-wars}"
  SEED=$(find "$STATE_ROOT/archive/$REPO_HASH" "$STATE_ROOT/state/$REPO_HASH" \
              -path '*/_consult/synthesis.md' -type f -printf '%T@ %p\n' 2>/dev/null \
         | sort -n | tail -1 | cut -d' ' -f2-)
  [[ -n "$SEED" ]] || { echo "FAIL: no synthesis.md found; pass an explicit path" >&2; exit 1; }
fi

TOPIC=$(basename "$(dirname "$(dirname "$SEED")")")
[[ -n "$TOPIC" && "$TOPIC" != "/" ]] || { echo "FAIL: cannot extract topic from $SEED" >&2; exit 1; }

printf 'TOPIC=%s\nSEED=%s\n' "$TOPIC" "$SEED"
