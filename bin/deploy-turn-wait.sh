#!/usr/bin/env bash
# bin/deploy-turn-wait.sh — single-turn wait.
#
# Usage: bin/deploy-turn-wait.sh <topic> <round>
#
# Reads OFFSET= from _deploy/turn-cody-<round>.txt; appends TS=<status>.
# Returns rc=0 always — status field carries the outcome.
#
# Status values:
#   ok        — done event + verify-report-<round>.md exists with content
#   failed    — done event but verify-report missing/empty, OR error event
#   question  — v0.50: trooper halted with a {event:"question",...} event;
#               payload written to <art_dir>/question-cody-<round>.txt for
#               the directive (commands/deploy.md) to handle
#   timeout   — no done|error|question event before CW_DEPLOY_TURN_TIMEOUT

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/deploy.sh"
source "$PLUGIN_ROOT/lib/trooper-questions.sh"
source "$PLUGIN_ROOT/lib/deploy-questions.sh"

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

# v0.50 #1: wait set extended to include "question" so a trooper that
# emits a halt-and-ask event surfaces here instead of timing out.
cw_outbox_wait_since cody codex "$TOPIC" "$OFFSET" done error question "$TIMEOUT" >/dev/null || true

OUTBOX=$(cw_outbox_path cody codex "$TOPIC")
TAIL=$(tail -c "+$(( OFFSET + 1 ))" "$OUTBOX" 2>/dev/null || true)
# v0.50 #1: terminal done/error WINS over an in-flight question; only fall
# back to question if no done/error was emitted in this offset slice.
MATCHED=$(printf '%s\n' "$TAIL" | grep -m1 -E '"event":"(done|error)"' || true)
if [[ -z "$MATCHED" ]]; then
  MATCHED=$(printf '%s\n' "$TAIL" | grep -m1 '"event":"question"' || true)
fi
EVENT=$(cw_event_name_extract "$MATCHED")

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
  question)
    # v0.50 #1: trooper hit a blocker; write payload + TS=question and
    # let the directive (commands/deploy.md) handle verify-or-escalate.
    PAYLOAD="$ART_DIR/question-cody-$ROUND.txt"
    if cw_deploy_question_extract_to_payload "$MATCHED" "$PAYLOAD"; then
      printf 'TS=question\n' >> "$STATE_FILE"
      log_info "[turn-wait] cody round=$ROUND TS=question (payload: $PAYLOAD)"
    else
      printf 'TS=failed\n' >> "$STATE_FILE"
      log_warn "[turn-wait] cody round=$ROUND TS=failed (malformed question payload)"
    fi
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
