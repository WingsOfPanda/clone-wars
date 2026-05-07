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

# v0.15.0: cw_consult_write_adjudicated discovers N + commander list from
# $ART_DIR/troopers.txt and emits 4-tier (N=2) or 5-tier (N>=3) output.
cw_consult_write_adjudicated "$ART_DIR" "$ART_DIR/adjudicated-draft.md"

log_info "[adjudicate] wrote $ART_DIR/adjudicated-draft.md"
log_info "  Master Yoda: cp \"\$TOPIC_DIR/_consult/adjudicated-draft.md\" \"\$TOPIC_DIR/_consult/adjudicated.md\" then resolve PENDINGs."
