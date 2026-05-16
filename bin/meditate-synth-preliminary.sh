#!/usr/bin/env bash
# bin/meditate-synth-preliminary.sh — Phase 5 input-validator.
#
# Usage: bin/meditate-synth-preliminary.sh <meditate-topic>
#
# Validates that the inputs for preliminary synthesis are present:
# - _meditate/topic.txt
# - _meditate/troopers.txt
# - _meditate/findings-<cmdr>.md for every commander in troopers.txt
# - optionally _meditate/literature-review.md if lit-track.txt == ON
#
# Prints the expected output path on stdout (Yoda Writes to this path):
#   _meditate/landscape-draft.md
#
# Exits non-zero with a specific error if any input is missing or empty.

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/meditate.sh"

[[ $# -eq 1 ]] || { echo "Usage: $0 <meditate-topic>" >&2; exit 2; }
TOPIC="$1"
cw_meditate_assert_topic "$TOPIC"

ART_DIR="$(cw_meditate_art_dir "$TOPIC")"
[[ -d "$ART_DIR" ]] || { log_error "$ART_DIR not found — run meditate-init first"; exit 1; }

# Required inputs
for f in topic.txt troopers.txt; do
  [[ -s "$ART_DIR/$f" ]] || { log_error "missing or empty: $ART_DIR/$f"; exit 1; }
done

# Findings per commander
missing=()
while IFS=$'\t' read -r prov cmdr; do
  [[ -n "$cmdr" ]] || continue
  if [[ ! -s "$ART_DIR/findings-$cmdr.md" ]]; then
    missing+=("findings-$cmdr.md")
  fi
done < <(cw_consult_load_troopers "$ART_DIR/troopers.txt")

if (( ${#missing[@]} > 0 )); then
  log_error "preliminary synthesis blocked — missing or empty findings:"
  for m in "${missing[@]}"; do log_error "  - $ART_DIR/$m"; done
  exit 1
fi

OUT_PATH="$ART_DIR/landscape-draft.md"
log_info "[synth-preliminary] inputs validated for $TOPIC"
log_info "  output target:    $OUT_PATH"
printf '%s\n' "$OUT_PATH"
