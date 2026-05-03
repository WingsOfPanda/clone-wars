#!/usr/bin/env bash
# bin/deploy-verify-send.sh — Phase 3 self-verify dispatch.
# Usage: bin/deploy-verify-send.sh <topic> <round>

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/deploy.sh"

[[ $# -eq 2 ]] || { echo "Usage: $0 <topic> <round>" >&2; exit 2; }
TOPIC="$1"; ROUND="$2"
cw_deploy_assert_topic "$TOPIC"
[[ "$ROUND" =~ ^[1-9][0-9]*$ ]] || { log_error "round must be a positive integer; got '$ROUND'"; exit 2; }

ART_DIR="$(cw_deploy_art_dir "$TOPIC")"
[[ -d "$ART_DIR" ]] || { log_error "$ART_DIR not found"; exit 1; }
DESIGN="$ART_DIR/design.md"
[[ -f "$DESIGN" ]] || { log_error "design.md missing"; exit 1; }

STATE_FILE="$ART_DIR/verify-cody-$ROUND.txt"
REPORT="$ART_DIR/verify-report-$ROUND.md"
TEST_LOG="$ART_DIR/test-output-$ROUND.log"
[[ ! -e "$STATE_FILE" ]] || { log_error "$STATE_FILE already exists; rm to retry round $ROUND"; exit 1; }

TROOPER_DIR=$(cw_trooper_dir cody codex "$TOPIC")
OUTBOX="$TROOPER_DIR/outbox.jsonl"
[[ -f "$OUTBOX" ]] || { log_error "outbox not found at $OUTBOX"; exit 1; }

PROMPT_FILE="$ART_DIR/cody_verify_prompt-$ROUND.md"
cw_deploy_build_verify_prompt "$DESIGN" "$ROUND" "$REPORT" "$TEST_LOG" > "$PROMPT_FILE"

OFFSET=$(wc -c < "$OUTBOX" | tr -d ' ')
printf 'OFFSET=%s\n' "$OFFSET" > "$STATE_FILE"

if ! "$PLUGIN_ROOT/bin/send.sh" cody "$TOPIC" "@$PROMPT_FILE" >/dev/null; then
  log_error "send.sh failed; state file kept for retry"
  exit 1
fi

log_info "[verify-send] cody round=$ROUND offset=$OFFSET"
