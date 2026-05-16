#!/usr/bin/env bash
# bin/meditate-adversary-send.sh — Phase 6 dispatch for one commander.
# Master Yoda invokes Nx in parallel (one per trooper, against the same
# landscape-draft.md).
#
# Usage: bin/meditate-adversary-send.sh <meditate-topic> <commander> <model>
#
# Writes _meditate/adversary-<commander>.txt with: OFFSET=<n>
# Trooper writes adversary critique to _meditate/adversary-<commander>.md
# Refuses if state file already exists.

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/meditate.sh"

[[ $# -eq 3 ]] || { echo "Usage: $0 <meditate-topic> <commander> <model>" >&2; exit 2; }
TOPIC="$1"; COMMANDER="$2"; MODEL="$3"
cw_meditate_assert_topic "$TOPIC"
cw_consult_assert_topic "$TOPIC"
cw_consult_assert_commander "$COMMANDER"
[[ "$MODEL" =~ ^[a-z0-9_-]+$ ]] || { log_error "invalid model: $MODEL"; exit 2; }

ART_DIR="$(cw_meditate_art_dir "$TOPIC")"
[[ -d "$ART_DIR" ]] || { log_error "$ART_DIR not found"; exit 1; }
[[ -s "$ART_DIR/landscape-draft.md" ]] || { log_error "landscape-draft.md missing or empty — run preliminary synthesis first"; exit 1; }

STATE_FILE="$ART_DIR/adversary-$COMMANDER.txt"
[[ ! -e "$STATE_FILE" ]] || {
  log_error "$STATE_FILE already exists; reset with: bin/consult-offset-reset.sh $TOPIC $COMMANDER adversary"
  exit 1
}

TROOPER_DIR=$(cw_trooper_dir "$COMMANDER" "$MODEL" "$TOPIC")
OUTBOX="$TROOPER_DIR/outbox.jsonl"
[[ -f "$OUTBOX" ]] || { log_error "outbox not found at $OUTBOX — trooper not spawned?"; exit 1; }

PROMPT_FILE="$ART_DIR/${COMMANDER}_adversary_prompt.md"
OUT_PATH="$ART_DIR/adversary-$COMMANDER.md"

# Build adversary prompt — inline the draft content into the template.
LANDSCAPE_DRAFT=$(cat "$ART_DIR/landscape-draft.md")
cw_consult_load_prompt meditate/adversary.md \
  "LANDSCAPE_DRAFT=$LANDSCAPE_DRAFT" \
  "COMMANDER=$COMMANDER" \
  "OUT_PATH=$OUT_PATH" > "$PROMPT_FILE"

OFFSET=$(cw_outbox_offset "$OUTBOX")
printf 'OFFSET=%s\n' "$OFFSET" > "$STATE_FILE"

if ! "$PLUGIN_ROOT/bin/send.sh" "$COMMANDER" "$TOPIC" "@$PROMPT_FILE" >/dev/null; then
  log_error "send.sh failed; state file kept for retry"
  exit 1
fi

log_info "[adversary-send] $COMMANDER offset=$OFFSET"
