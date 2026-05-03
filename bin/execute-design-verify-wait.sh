#!/usr/bin/env bash
# bin/execute-design-verify-wait.sh — Phase 3 self-verify wait.
# Usage: bin/execute-design-verify-wait.sh <topic> <round>

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/execute_design.sh"

[[ $# -eq 2 ]] || { echo "Usage: $0 <topic> <round>" >&2; exit 2; }
TOPIC="$1"; ROUND="$2"
cw_execute_design_assert_topic "$TOPIC"
[[ "$ROUND" =~ ^[1-9][0-9]*$ ]] || { log_error "round must be a positive integer; got '$ROUND'"; exit 2; }

ART_DIR="$(cw_execute_design_art_dir "$TOPIC")"
STATE_FILE="$ART_DIR/verify-cody-$ROUND.txt"
[[ -f "$STATE_FILE" ]] || { log_error "$STATE_FILE missing — run verify-send first"; exit 1; }
# shellcheck disable=SC1090
source "$STATE_FILE"
[[ -n "${OFFSET:-}" ]] || { log_error "OFFSET not set in $STATE_FILE"; exit 1; }

TIMEOUT="${CW_EXECUTE_VERIFY_TIMEOUT:-1200}"
log_info "[verify-wait] cody round=$ROUND offset=$OFFSET timeout=${TIMEOUT}s"

cw_outbox_wait_since cody codex "$TOPIC" "$OFFSET" done error "$TIMEOUT" >/dev/null || true

TROOPER_DIR=$(cw_trooper_dir cody codex "$TOPIC")
OUTBOX="$TROOPER_DIR/outbox.jsonl"
TAIL=$(tail -c "+$(( OFFSET + 1 ))" "$OUTBOX" 2>/dev/null || true)
MATCHED=$(printf '%s\n' "$TAIL" | grep -m1 -E '"event":"(done|error)"' || true)
EVENT=$(printf '%s' "$MATCHED" | sed -n 's/.*"event":"\([^"]*\)".*/\1/p')

REPORT="$ART_DIR/verify-report-$ROUND.md"
case "$EVENT" in
  done)
    if [[ -f "$REPORT" && -s "$REPORT" ]]; then
      printf 'VS=ok\n' >> "$STATE_FILE"
      log_info "[verify-wait] cody round=$ROUND VS=ok"
    else
      printf 'VS=failed\n' >> "$STATE_FILE"
      log_warn "[verify-wait] cody round=$ROUND VS=failed (done but report empty/missing)"
    fi
    ;;
  error) printf 'VS=failed\n'  >> "$STATE_FILE"; log_warn "[verify-wait] cody round=$ROUND VS=failed (error)" ;;
  '')    printf 'VS=timeout\n' >> "$STATE_FILE"; log_warn "[verify-wait] cody round=$ROUND VS=timeout" ;;
  *)     printf 'VS=failed\n'  >> "$STATE_FILE"; log_warn "[verify-wait] cody round=$ROUND VS=failed (unknown event '$EVENT')" ;;
esac

touch "${STATE_FILE%.txt}.done"
exit 0
