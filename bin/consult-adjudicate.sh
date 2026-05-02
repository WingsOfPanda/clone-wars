#!/usr/bin/env bash
# bin/consult-adjudicate.sh — generate adjudicated-draft.md.
#
# Usage: bin/consult-adjudicate.sh <consult-topic>
#
# Writes _consult/adjudicated-draft.md (regenerable, idempotent).
# NEVER touches _consult/adjudicated.md (Master Yoda's resolution surface).

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/consult.sh"

[[ $# -eq 1 ]] || { echo "Usage: $0 <consult-topic>" >&2; exit 2; }
TOPIC="$1"
cw_consult_assert_topic "$TOPIC"

ART_DIR="$(cw_consult_art_dir "$TOPIC")"
[[ -d "$ART_DIR" ]] || { log_error "$ART_DIR not found"; exit 1; }

# Defaults if a state file is missing.
REX_VS_VAL=skipped; CODY_VS_VAL=skipped
if [[ -f "$ART_DIR/verify-rex.txt" ]]; then
  REX_VS_VAL=$(awk -F= '/^VS=/{print $2}' "$ART_DIR/verify-rex.txt")
  : "${REX_VS_VAL:=skipped}"
fi
if [[ -f "$ART_DIR/verify-cody.txt" ]]; then
  CODY_VS_VAL=$(awk -F= '/^VS=/{print $2}' "$ART_DIR/verify-cody.txt")
  : "${CODY_VS_VAL:=skipped}"
fi

REX_DIR=$(cw_trooper_dir rex codex "$TOPIC")
CODY_DIR=$(cw_trooper_dir cody claude "$TOPIC")

cw_consult_write_adjudicated \
  "$ART_DIR/adjudicated-draft.md" \
  "$REX_DIR/verify.md" \
  "$CODY_DIR/verify.md" \
  "$ART_DIR/rex_only_items.txt" \
  "$ART_DIR/cody_only_items.txt" \
  "$REX_VS_VAL" \
  "$CODY_VS_VAL"

log_info "[adjudicate] wrote $ART_DIR/adjudicated-draft.md"
log_info "  Master Yoda: cp \"\$TOPIC_DIR/_consult/adjudicated-draft.md\" \"\$TOPIC_DIR/_consult/adjudicated.md\" then resolve PENDINGs."
