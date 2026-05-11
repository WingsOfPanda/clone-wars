#!/usr/bin/env bash
# bin/meditate-research-send.sh — Phase 3 dispatch for one commander.
# Master Yoda invokes Nx in parallel (one per trooper).
#
# Usage: bin/meditate-research-send.sh <meditate-topic> <commander> <model>
#
# Writes _meditate/research-<commander>.txt with: OFFSET=<n>
# Trooper writes findings to _meditate/findings-<commander>.md
# Refuses if state file already exists (reset via consult-offset-reset.sh
# which is topic-agnostic).

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/meditate.sh"

[[ $# -eq 3 ]] || { echo "Usage: $0 <meditate-topic> <commander> <model>" >&2; exit 2; }
TOPIC="$1"; COMMANDER="$2"; MODEL="$3"

# Topic must start with "meditate-" to ensure we're not writing into a
# consult topic dir by accident.
[[ "$TOPIC" == meditate-* ]] || { log_error "topic must start with 'meditate-': $TOPIC"; exit 2; }
[[ "$TOPIC" =~ ^[a-z0-9-]+$ ]] || { log_error "invalid topic: $TOPIC"; exit 2; }
cw_consult_assert_commander "$COMMANDER"
[[ "$MODEL" =~ ^[a-z0-9_-]+$ ]] || { log_error "invalid model: $MODEL"; exit 2; }

ART_DIR="$(cw_meditate_art_dir "$TOPIC")"
[[ -d "$ART_DIR" ]] || { log_error "$ART_DIR not found — run meditate-init first"; exit 1; }

STATE_FILE="$ART_DIR/research-$COMMANDER.txt"
[[ ! -e "$STATE_FILE" ]] || {
  log_error "$STATE_FILE already exists; reset with: bin/consult-offset-reset.sh $TOPIC $COMMANDER research"
  exit 1
}

TROOPER_DIR=$(cw_trooper_dir "$COMMANDER" "$MODEL" "$TOPIC")
OUTBOX="$TROOPER_DIR/outbox.jsonl"
[[ -f "$OUTBOX" ]] || { log_error "outbox not found at $OUTBOX — was the trooper spawned?"; exit 1; }

TOPIC_TEXT=$(cat "$ART_DIR/topic.txt")
PROMPT_FILE="$ART_DIR/${COMMANDER}_research_prompt.md"
WRITE_TO="$ART_DIR/findings-$COMMANDER.md"

# Build prompt from meditate template.
cw_consult_load_prompt meditate/research.md \
  "TOPIC=$TOPIC_TEXT" "WRITE_TO=$WRITE_TO" > "$PROMPT_FILE"

OFFSET=$(wc -c < "$OUTBOX" | tr -d ' ')
printf 'OFFSET=%s\n' "$OFFSET" > "$STATE_FILE"

if ! "$PLUGIN_ROOT/bin/send.sh" "$COMMANDER" "$TOPIC" "@$PROMPT_FILE" >/dev/null; then
  log_error "send.sh failed; state file kept for retry via consult-offset-reset.sh"
  exit 1
fi

log_info "[research-send] $COMMANDER offset=$OFFSET"
