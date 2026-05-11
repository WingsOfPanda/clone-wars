#!/usr/bin/env bash
# bin/meditate-synth-final.sh — Phase 8 input-validator.
#
# Usage: bin/meditate-synth-final.sh <meditate-topic>
#
# Validates inputs and resolves the canonical output path.
# If adversary-skip.txt records user-decision=skip, only landscape-draft.md
# is required. Otherwise adversary-<cmdr>.md per trooper is required.
#
# Prints the resolved output path on stdout (Yoda Writes the final doc here):
#   _meditate/landscape-<YYYY-MM-DD>-<slug>.md

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/meditate.sh"

[[ $# -eq 1 ]] || { echo "Usage: $0 <meditate-topic>" >&2; exit 2; }
TOPIC="$1"
[[ "$TOPIC" == meditate-* ]] || { log_error "topic must start with 'meditate-': $TOPIC"; exit 2; }

ART_DIR="$(cw_meditate_art_dir "$TOPIC")"
[[ -d "$ART_DIR" ]] || { log_error "$ART_DIR not found"; exit 1; }
[[ -s "$ART_DIR/landscape-draft.md" ]] || { log_error "landscape-draft.md missing"; exit 1; }
[[ -s "$ART_DIR/topic.txt" ]] || { log_error "topic.txt missing"; exit 1; }

# Determine whether adversary ran
ADVERSARY_RAN=1
if [[ -f "$ART_DIR/adversary-skip.txt" ]] && grep -q '^user_decision: skip$' "$ART_DIR/adversary-skip.txt"; then
  ADVERSARY_RAN=0
fi

# If adversary ran, every adversary-<cmdr>.md must exist
if (( ADVERSARY_RAN == 1 )); then
  missing=()
  while IFS=$'\t' read -r prov cmdr; do
    [[ -n "$cmdr" ]] || continue
    if [[ ! -s "$ART_DIR/adversary-$cmdr.md" ]]; then
      missing+=("adversary-$cmdr.md")
    fi
  done < <(cw_consult_load_troopers "$ART_DIR/troopers.txt")
  if (( ${#missing[@]} > 0 )); then
    log_error "final synthesis blocked — adversary ran but critiques missing:"
    for m in "${missing[@]}"; do log_error "  - $ART_DIR/$m"; done
    exit 1
  fi
fi

# Derive canonical output filename. Slug taken from the topic (strip "meditate-" prefix).
SLUG="${TOPIC#meditate-}"
TODAY=$(date -u +%Y-%m-%d)
OUT_PATH="$ART_DIR/landscape-$TODAY-$SLUG.md"

log_info "[synth-final] inputs validated for $TOPIC (adversary_ran=$ADVERSARY_RAN)"
log_info "  output target:  $OUT_PATH"
printf '%s\n' "$OUT_PATH"
