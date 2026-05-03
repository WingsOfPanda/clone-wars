#!/usr/bin/env bash
# bin/deploy-plan-wait.sh — Phase 1 plan wait.
#
# Usage: bin/deploy-plan-wait.sh <topic>
#
# Reads OFFSET= from _deploy/plan-cody.txt; appends PS=<status>.
# Returns rc=0 always — status field carries the outcome.

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/deploy.sh"

[[ $# -eq 1 ]] || { echo "Usage: $0 <topic>" >&2; exit 2; }
TOPIC="$1"
cw_deploy_assert_topic "$TOPIC"

ART_DIR="$(cw_deploy_art_dir "$TOPIC")"
STATE_FILE="$ART_DIR/plan-cody.txt"
[[ -f "$STATE_FILE" ]] || { log_error "$STATE_FILE missing — run deploy-plan-send first"; exit 1; }
# shellcheck disable=SC1090
source "$STATE_FILE"
[[ -n "${OFFSET:-}" ]] || { log_error "OFFSET not set in $STATE_FILE"; exit 1; }

TIMEOUT="${CW_DEPLOY_PLAN_TIMEOUT:-600}"
log_info "[plan-wait] cody offset=$OFFSET timeout=${TIMEOUT}s"

cw_outbox_wait_since cody codex "$TOPIC" "$OFFSET" done error "$TIMEOUT" >/dev/null || true

TROOPER_DIR=$(cw_trooper_dir cody codex "$TOPIC")
OUTBOX="$TROOPER_DIR/outbox.jsonl"
TAIL=$(tail -c "+$(( OFFSET + 1 ))" "$OUTBOX" 2>/dev/null || true)
MATCHED=$(printf '%s\n' "$TAIL" | grep -m1 -E '"event":"(done|error)"' || true)
EVENT=$(printf '%s' "$MATCHED" | sed -n 's/.*"event":"\([^"]*\)".*/\1/p')

case "$EVENT" in
  done)
    if [[ -f "$ART_DIR/plan.md" && -s "$ART_DIR/plan.md" ]]; then
      printf 'PS=ok\n' >> "$STATE_FILE"
      log_info "[plan-wait] cody PS=ok"
    else
      printf 'PS=failed\n' >> "$STATE_FILE"
      log_warn "[plan-wait] cody PS=failed (done but plan.md empty/missing)"
    fi
    ;;
  error)
    printf 'PS=failed\n' >> "$STATE_FILE"
    log_warn "[plan-wait] cody PS=failed (error event)"
    ;;
  '')
    printf 'PS=timeout\n' >> "$STATE_FILE"
    log_warn "[plan-wait] cody PS=timeout"
    ;;
  *)
    printf 'PS=failed\n' >> "$STATE_FILE"
    log_warn "[plan-wait] cody PS=failed (unknown event '$EVENT')"
    ;;
esac

# background-await sentinel
touch "${STATE_FILE%.txt}.done"
exit 0
