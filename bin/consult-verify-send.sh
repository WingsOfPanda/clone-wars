#!/usr/bin/env bash
# bin/consult-verify-send.sh — Phase 4 dispatch for one commander.
# Master Yoda invokes 2x in parallel.
#
# Usage: bin/consult-verify-send.sh <consult-topic> <commander> <model>
#
# Reads PEER's _only_items.txt: rex sends → reads cody_only_items.txt; cody → reads rex_only_items.txt.
# If peer file is empty → writes VS=skipped (no actual send). Else writes OFFSET= and sends.

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/consult.sh"

[[ $# -eq 3 ]] || { echo "Usage: $0 <consult-topic> <commander> <model>" >&2; exit 2; }
TOPIC="$1"; COMMANDER="$2"; MODEL="$3"

cw_consult_assert_topic "$TOPIC"
cw_consult_assert_commander "$COMMANDER"
[[ "$MODEL" =~ ^[a-z0-9_-]+$ ]]    || { log_error "invalid model: $MODEL"; exit 2; }

ART_DIR="$(cw_consult_art_dir "$TOPIC")"
[[ -d "$ART_DIR" ]] || { log_error "$ART_DIR not found"; exit 1; }

STATE_FILE="$ART_DIR/verify-$COMMANDER.txt"
[[ ! -e "$STATE_FILE" ]] || {
  log_error "$STATE_FILE already exists; reset with: bin/consult-offset-reset.sh $TOPIC $COMMANDER verify"
  exit 1
}

# rex sends → reads cody's _only items; cody sends → reads rex's.
case "$COMMANDER" in
  rex)  PEER_ITEMS="$ART_DIR/cody_only_items.txt" ;;
  cody) PEER_ITEMS="$ART_DIR/rex_only_items.txt"  ;;
  *)    log_error "verify-send only supports rex/cody for now; got $COMMANDER"; exit 2 ;;
esac
[[ -f "$PEER_ITEMS" ]] || { log_error "$PEER_ITEMS missing — run consult-diff first"; exit 1; }

if [[ ! -s "$PEER_ITEMS" ]]; then
  printf 'VS=skipped\n' > "$STATE_FILE"
  log_info "[verify-send] $COMMANDER VS=skipped (peer has no _only items)"
  exit 0
fi

TROOPER_DIR=$(cw_trooper_dir "$COMMANDER" "$MODEL" "$TOPIC")
OUTBOX="$TROOPER_DIR/outbox.jsonl"
[[ -f "$OUTBOX" ]] || { log_error "outbox not found at $OUTBOX"; exit 1; }

PROMPT_FILE="$ART_DIR/${COMMANDER}_verify_prompt.md"
BASE_PROMPT=$(cw_consult_build_verify_prompt "$PEER_ITEMS" "$TROOPER_DIR/verify.md")
cw_consult_skill_hint_append "$ART_DIR/skill.txt" "$BASE_PROMPT" > "$PROMPT_FILE"

OFFSET=$(wc -c < "$OUTBOX" | tr -d ' ')
printf 'OFFSET=%s\n' "$OFFSET" > "$STATE_FILE"

if ! "$PLUGIN_ROOT/bin/send.sh" "$COMMANDER" "$TOPIC" "@$PROMPT_FILE" >/dev/null; then
  log_error "send.sh failed; state file kept for retry"
  exit 1
fi

log_info "[verify-send] $COMMANDER offset=$OFFSET items=$(wc -l < "$PEER_ITEMS")"
