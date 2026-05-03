#!/usr/bin/env bash
# bin/deploy-turn-wait.sh — single-turn wait.
#
# Usage: bin/deploy-turn-wait.sh <topic> <round>
#
# Reads OFFSET= from _deploy/turn-cody-<round>.txt; appends TS=<status>.
# Returns rc=0 always — status field carries the outcome.
#
# Status values:
#   ok       — done event + verify-report-<round>.md exists with content
#   failed   — done event but verify-report missing/empty, OR error event
#   timeout  — no done|error event before CW_DEPLOY_TURN_TIMEOUT (default 14400s)

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/deploy.sh"

[[ $# -eq 2 ]] || { echo "Usage: $0 <topic> <round>" >&2; exit 2; }
TOPIC="$1"
ROUND="$2"
[[ "$ROUND" =~ ^[1-9][0-9]*$ ]] || { log_error "round must be a positive integer (got: $ROUND)"; exit 1; }
cw_deploy_assert_topic "$TOPIC"

ART_DIR="$(cw_deploy_art_dir "$TOPIC")"
STATE_FILE="$ART_DIR/turn-cody-$ROUND.txt"
[[ -f "$STATE_FILE" ]] || { log_error "$STATE_FILE missing — run deploy-turn-send first"; exit 1; }
# shellcheck disable=SC1090
source "$STATE_FILE"
[[ -n "${OFFSET:-}" ]] || { log_error "OFFSET not set in $STATE_FILE"; exit 1; }

TIMEOUT="${CW_DEPLOY_TURN_TIMEOUT:-14400}"
log_info "[turn-wait] cody round=$ROUND offset=$OFFSET timeout=${TIMEOUT}s"

cw_outbox_wait_since cody codex "$TOPIC" "$OFFSET" done error "$TIMEOUT" >/dev/null || true

TROOPER_DIR=$(cw_trooper_dir cody codex "$TOPIC")
OUTBOX="$TROOPER_DIR/outbox.jsonl"
TAIL=$(tail -c "+$(( OFFSET + 1 ))" "$OUTBOX" 2>/dev/null || true)
MATCHED=$(printf '%s\n' "$TAIL" | grep -m1 -E '"event":"(done|error)"' || true)
EVENT=$(printf '%s' "$MATCHED" | sed -n 's/.*"event":"\([^"]*\)".*/\1/p')

VERIFY_OUT="$ART_DIR/verify-report-$ROUND.md"

case "$EVENT" in
  done)
    if [[ -f "$VERIFY_OUT" && -s "$VERIFY_OUT" ]]; then
      printf 'TS=ok\n' >> "$STATE_FILE"
      log_info "[turn-wait] cody round=$ROUND TS=ok"
    else
      printf 'TS=failed\n' >> "$STATE_FILE"
      log_warn "[turn-wait] cody round=$ROUND TS=failed (done but verify-report-$ROUND.md empty/missing)"
    fi
    ;;
  error)
    printf 'TS=failed\n' >> "$STATE_FILE"
    log_warn "[turn-wait] cody round=$ROUND TS=failed (error event)"
    ;;
  '')
    printf 'TS=timeout\n' >> "$STATE_FILE"
    log_warn "[turn-wait] cody round=$ROUND TS=timeout"
    ;;
  *)
    printf 'TS=failed\n' >> "$STATE_FILE"
    log_warn "[turn-wait] cody round=$ROUND TS=failed (unknown event '$EVENT')"
    ;;
esac

# background-await sentinel
touch "${STATE_FILE%.txt}.done"
exit 0
