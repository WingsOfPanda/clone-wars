#!/usr/bin/env bash
# bin/deploy-wave-wait.sh — per-trooper outbox watcher for v0.20.0+
# multi-repo deploy. Master Yoda invokes K in parallel (one per
# trooper in a wave).
#
# Usage: bin/deploy-wave-wait.sh <topic> <commander> <provider>
#
# Reads the trooper's outbox.jsonl from offset 0, blocks until a
# terminal event ({done} or {error}) appears OR the timeout fires.
# Writes _deploy/<topic>/wave-<commander>.txt with TS= line + EVENT=
# (and REASON= on error / TIMEOUT_S= on timeout). Touches a
# wave-<commander>.done sentinel to signal the harness.
#
# rc=0 always — outcome carried by the TS= field.
# rc=2 on bad args.

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/deploy.sh"

[[ $# -eq 3 ]] || { echo "Usage: $0 <topic> <commander> <provider>" >&2; exit 2; }
TOPIC="$1"; COMMANDER="$2"; PROVIDER="$3"

cw_deploy_assert_topic "$TOPIC"
[[ "$COMMANDER" =~ ^[a-z0-9_-]+$ ]] || { log_error "invalid commander: $COMMANDER"; exit 2; }
[[ "$PROVIDER"  =~ ^[a-z0-9_-]+$ ]] || { log_error "invalid provider: $PROVIDER"; exit 2; }

ART_DIR=$(cw_deploy_art_dir "$TOPIC")
[[ -d "$ART_DIR" ]] || { log_error "_deploy art-dir missing for topic '$TOPIC'"; exit 1; }

STATE_FILE="$ART_DIR/wave-$COMMANDER.txt"
DONE_SENTINEL="$ART_DIR/wave-$COMMANDER.done"
TIMEOUT="${CW_DEPLOY_WAVE_TIMEOUT_OVERRIDE:-${CW_DEPLOY_TURN_TIMEOUT:-14400}}"

log_info "[wave-wait] $COMMANDER timeout=${TIMEOUT}s"

# Block on terminal events from offset 0.
cw_outbox_wait_since "$COMMANDER" "$PROVIDER" "$TOPIC" 0 "done" "error" "$TIMEOUT" >/dev/null || true

OUTBOX=$(cw_outbox_path "$COMMANDER" "$PROVIDER" "$TOPIC")
MATCHED=""
[[ -f "$OUTBOX" ]] && MATCHED=$(grep -m1 -E '"event":"(done|error)"' "$OUTBOX" 2>/dev/null || true)

write_state() {
  local ts="$1"; shift
  {
    printf 'TS=%s\n' "$ts"
    printf 'COMMANDER=%s\n' "$COMMANDER"
    printf 'PROVIDER=%s\n' "$PROVIDER"
    printf 'TOPIC=%s\n' "$TOPIC"
    while [[ $# -gt 0 ]]; do printf '%s\n' "$1"; shift; done
  } > "$STATE_FILE"
  : > "$DONE_SENTINEL"
}

if [[ -z "$MATCHED" ]]; then
  write_state timeout "TIMEOUT_S=$TIMEOUT"
  log_warn "[wave-wait] $COMMANDER timeout after ${TIMEOUT}s"
  exit 0
fi

EVENT=$(printf '%s' "$MATCHED" | sed -nE 's/.*"event":"([a-z]+)".*/\1/p')
case "$EVENT" in
  done)
    write_state ok "EVENT=done"
    log_ok "[wave-wait] $COMMANDER done"
    ;;
  error)
    REASON=$(printf '%s' "$MATCHED" | sed -nE 's/.*"reason":"([^"]*)".*/\1/p')
    write_state failed "EVENT=error" "REASON=$REASON"
    log_error "[wave-wait] $COMMANDER error: $REASON"
    ;;
  *)
    write_state failed "EVENT=unknown"
    log_error "[wave-wait] $COMMANDER unknown event: $MATCHED"
    ;;
esac

exit 0
