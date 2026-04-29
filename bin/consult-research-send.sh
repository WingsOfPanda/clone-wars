#!/usr/bin/env bash
# bin/consult-research-send.sh — Phase 2 dispatch for one commander.
# the Jedi general invokes 2x in parallel (one per trooper).
#
# Usage: bin/consult-research-send.sh <consult-topic> <commander> <model>
#
# Writes _consult/research-<commander>.txt with one line: OFFSET=<n>
# Refuses if the file already exists — reset via bin/consult-offset-reset.sh.

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/consult.sh"

[[ $# -eq 3 ]] || { echo "Usage: $0 <consult-topic> <commander> <model>" >&2; exit 2; }
TOPIC="$1"; COMMANDER="$2"; MODEL="$3"

cw_consult_topic_validate "$TOPIC" || { log_error "invalid topic: $TOPIC"; exit 2; }
[[ "$COMMANDER" =~ ^[a-z0-9_-]+$ ]] || { log_error "invalid commander: $COMMANDER"; exit 2; }
[[ "$MODEL" =~ ^[a-z0-9_-]+$ ]] || { log_error "invalid model: $MODEL"; exit 2; }

ART_DIR="$(cw_state_root)/state/$(cw_repo_hash)/$TOPIC/_consult"
[[ -d "$ART_DIR" ]] || { log_error "$ART_DIR not found — run consult-init first"; exit 1; }

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
cw_consult_build_research_prompt "$TOPIC_TEXT" "$TROOPER_DIR/findings.md" > "$PROMPT_FILE"

OFFSET=$(wc -c < "$OUTBOX" | tr -d ' ')
printf 'OFFSET=%s\n' "$OFFSET" > "$STATE_FILE"

if ! "$PLUGIN_ROOT/bin/send.sh" "$COMMANDER" "$TOPIC" "@$PROMPT_FILE" >/dev/null; then
  log_error "send.sh failed; state file kept for retry via consult-offset-reset.sh"
  exit 1
fi

log_info "[research-send] $COMMANDER offset=$OFFSET"
