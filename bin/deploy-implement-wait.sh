#!/usr/bin/env bash
# bin/deploy-implement-wait.sh — Phase 2 implement wait.
# Usage: bin/deploy-implement-wait.sh <topic>

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
STATE_FILE="$ART_DIR/implement-cody.txt"
[[ -f "$STATE_FILE" ]] || { log_error "$STATE_FILE missing — run implement-send first"; exit 1; }
# shellcheck disable=SC1090
source "$STATE_FILE"
[[ -n "${OFFSET:-}" ]] || { log_error "OFFSET not set in $STATE_FILE"; exit 1; }

TIMEOUT="${CW_DEPLOY_IMPLEMENT_TIMEOUT:-7200}"
log_info "[implement-wait] cody offset=$OFFSET timeout=${TIMEOUT}s"

cw_outbox_wait_since cody codex "$TOPIC" "$OFFSET" done error "$TIMEOUT" >/dev/null || true

TROOPER_DIR=$(cw_trooper_dir cody codex "$TOPIC")
OUTBOX="$TROOPER_DIR/outbox.jsonl"
TAIL=$(tail -c "+$(( OFFSET + 1 ))" "$OUTBOX" 2>/dev/null || true)
MATCHED=$(printf '%s\n' "$TAIL" | grep -m1 -E '"event":"(done|error)"' || true)
EVENT=$(printf '%s' "$MATCHED" | sed -n 's/.*"event":"\([^"]*\)".*/\1/p')

case "$EVENT" in
  done)  printf 'IS=ok\n'      >> "$STATE_FILE"; log_info "[implement-wait] cody IS=ok" ;;
  error) printf 'IS=failed\n'  >> "$STATE_FILE"; log_warn "[implement-wait] cody IS=failed (error event)" ;;
  '')    printf 'IS=timeout\n' >> "$STATE_FILE"; log_warn "[implement-wait] cody IS=timeout" ;;
  *)     printf 'IS=failed\n'  >> "$STATE_FILE"; log_warn "[implement-wait] cody IS=failed (unknown event '$EVENT')" ;;
esac

touch "${STATE_FILE%.txt}.done"
exit 0
