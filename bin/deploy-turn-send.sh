#!/usr/bin/env bash
# bin/deploy-turn-send.sh — single-turn dispatch (codex).
#
# Usage: bin/deploy-turn-send.sh <topic> <round>
#
# Round 1: writes _deploy/turn-cody-1.txt (OFFSET=<n>) using the
# round-1 prompt (plan + implement + verify in one turn).
# Round >=2: reads _deploy/fix-prompt-<round>.md from disk and
# wraps it with the fix-round preamble.
# Refuses if the state file already exists (idempotency-fail-loud) OR if
# the trooper's status.json shows state != idle.

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/deploy.sh"

[[ $# -eq 2 ]] || { echo "Usage: $0 <topic> <round>" >&2; exit 2; }
TOPIC="$1"
ROUND="$2"
[[ "$ROUND" =~ ^[1-9][0-9]*$ ]] || { log_error "round must be a positive integer (got: $ROUND)"; exit 1; }
cw_deploy_assert_topic "$TOPIC"

ART_DIR="$(cw_deploy_art_dir "$TOPIC")"
[[ -d "$ART_DIR" ]] || { log_error "$ART_DIR not found — run deploy-init first"; exit 1; }

STATE_FILE="$ART_DIR/turn-cody-$ROUND.txt"
[[ ! -e "$STATE_FILE" ]] || { log_error "$STATE_FILE already exists; rm to retry"; exit 1; }

OUTBOX=$(cw_outbox_path cody codex "$TOPIC")
STATUS=$(cw_status_path cody codex "$TOPIC")
[[ -f "$OUTBOX" ]] || { log_error "outbox not found at $OUTBOX — was cody spawned?"; exit 1; }

# Trooper-not-idle gate (prevents racing the previous turn's mid-write).
if [[ -f "$STATUS" ]]; then
  STATE=$(grep -oE '"state":"[^"]*"' "$STATUS" | head -1 | sed 's/.*"state":"\([^"]*\)".*/\1/')
  if [[ -n "$STATE" && "$STATE" != "idle" ]]; then
    log_error "trooper not idle (state=$STATE); previous turn still in flight"
    exit 1
  fi
fi

PROMPT_FILE="$ART_DIR/cody_turn_prompt_$ROUND.md"

if [[ "$ROUND" -eq 1 ]]; then
  DESIGN="$ART_DIR/design.md"
  PLAN_OUT="$ART_DIR/plan.md"
  VERIFY_OUT="$ART_DIR/verify-report-1.md"
  cw_deploy_build_turn_prompt_round1 "$DESIGN" "$PLAN_OUT" "$VERIFY_OUT" > "$PROMPT_FILE"
else
  FIX_BUNDLE="$ART_DIR/fix-prompt-$ROUND.md"
  [[ -f "$FIX_BUNDLE" ]] || { log_error "fix-prompt-$ROUND.md not found at $FIX_BUNDLE; the directive must write it before invoking"; exit 1; }
  VERIFY_OUT="$ART_DIR/verify-report-$ROUND.md"
  if ! cw_deploy_build_turn_prompt_fix "$FIX_BUNDLE" "$VERIFY_OUT" "$ROUND" > "$PROMPT_FILE"; then
    log_error "failed to build fix-round prompt"
    exit 1
  fi
fi

OFFSET=$(wc -c < "$OUTBOX" | tr -d ' ')
printf 'OFFSET=%s\n' "$OFFSET" > "$STATE_FILE"

if ! "$PLUGIN_ROOT/bin/send.sh" cody "$TOPIC" "@$PROMPT_FILE" >/dev/null; then
  log_error "send.sh failed; state file kept for retry"
  exit 1
fi

log_info "[turn-send] cody round=$ROUND offset=$OFFSET"
