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
  # v0.16.0: single canonical seed pattern — `_consult/design-doc/<date>-<slug>-design.md`
  # (both fast-path Yoda-solo and trooper-path escalation write to this path).
  # Match both live state (`_consult/`) and archived (`_consult-<timestamp>/`) layouts;
  # consult-archive.sh appends a timestamp suffix to the dir, so the strict `_consult/`
  # glob would never match real archives. Pre-v0.16 also looked for
  # `_consult/synthesis.md` — that pattern is dropped (no back-compat for
  # archived consult dirs without a design-doc, per v0.14 precedent).
  SEED=$(find "$STATE_ROOT/archive/$REPO_HASH" "$STATE_ROOT/state/$REPO_HASH" \
              -path '*/_consult*/design-doc/*-design.md' -type f -printf '%T@ %p\n' 2>/dev/null \
         | sort -n | tail -1 | cut -d' ' -f2-)
  [[ -n "$SEED" ]] || { log_error "no design-doc found; pass an explicit path"; exit 1; }
fi

[[ "$SEED" =~ /_consult(-[0-9TZ]+)?/design-doc/[^/]+-design\.md$ ]] || { log_error "seed must be a consult design-doc (path */<topic>/_consult[-<ts>]/design-doc/<date>-<slug>-design.md): $SEED"; exit 2; }

TOPIC=$(basename "$(dirname "$(dirname "$(dirname "$SEED")")")")
[[ -n "$TOPIC" && "$TOPIC" != "/" ]] || { log_error "cannot extract topic from $SEED"; exit 1; }

printf 'TOPIC=%q\nSEED=%q\n' "$TOPIC" "$SEED"
