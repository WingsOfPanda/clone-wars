#!/usr/bin/env bash
# bin/deep-research-monitor.sh — watcher invoked by Monitor task.
# Tails outbox.jsonl for events and checks mtime against liveness thresholds.
# Each detection prints one stdout line (notification body). Runs until killed.
#
# Usage: bin/deep-research-monitor.sh <art-dir> <commander>
#
# Env overrides:
#   CW_DEEP_RESEARCH_PROBE_S=300   — mtime stale threshold (default 300s)
#   CW_DEEP_RESEARCH_STUCK_S=600   — mtime stuck threshold (default 600s)
#
# Each stdout line is a JSON object with: trooper, event, summary, ts.
# Spec Section 4 (liveness state machine) + Section 8 (helper inventory).
set -uo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=../lib/log.sh
source "$PLUGIN_ROOT/lib/log.sh"

[[ $# -eq 2 ]] || { echo "Usage: $0 <art-dir> <commander>" >&2; exit 2; }
ART_DIR="$1"; COMMANDER="$2"

[[ -d "$ART_DIR" ]] || { echo "monitor: art-dir missing: $ART_DIR" >&2; exit 2; }

PROBE_S="${CW_DEEP_RESEARCH_PROBE_S:-900}"
STUCK_S="${CW_DEEP_RESEARCH_STUCK_S:-1800}"

TOPIC_DIR=$(dirname "$ART_DIR")
OUTBOX="$TOPIC_DIR/$COMMANDER-codex/outbox.jsonl"
CURSOR_FILE="$ART_DIR/troopers/$COMMANDER/liveness-cursor.txt"
mkdir -p "$(dirname "$CURSOR_FILE")"
: > "$CURSOR_FILE"

OFFSET=0
LAST_STALE_TS=0
LAST_STUCK_TS=0

emit() {
  # $1 = event-type, $2 = optional summary
  printf '{"trooper":"%s","event":"%s","summary":"%s","ts":"%s"}\n' \
    "$COMMANDER" "$1" "${2:-}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

while true; do
  if [[ -f "$OUTBOX" ]]; then
    # Forward new lines since last offset
    local_size=$(wc -c < "$OUTBOX" | tr -d '[:space:]')
    if (( local_size > OFFSET )); then
      tail -c "+$((OFFSET + 1))" "$OUTBOX" 2>/dev/null | while IFS= read -r line; do
        ev=$(printf '%s' "$line" | sed -n 's/.*"event":"\([^"]*\)".*/\1/p')
        case "$ev" in
          done|error|question|heartbeat)
            summary=$(printf '%s' "$line" | sed -n 's/.*"summary":"\([^"]*\)".*/\1/p')
            emit "$ev" "$summary"
            ;;
        esac
      done
      OFFSET=$local_size
    fi

    # Liveness check via mtime
    mtime=$(stat -c '%Y' "$OUTBOX" 2>/dev/null || echo 0)
    now=$(date +%s)
    delta=$((now - mtime))
    if (( delta >= STUCK_S )) && (( now - LAST_STUCK_TS >= STUCK_S )); then
      emit "stuck" "outbox mtime ${delta}s old (>= ${STUCK_S}s threshold)"
      LAST_STUCK_TS=$now
    elif (( delta >= PROBE_S )) && (( now - LAST_STALE_TS >= PROBE_S )); then
      emit "stale" "outbox mtime ${delta}s old (>= ${PROBE_S}s threshold)"
      LAST_STALE_TS=$now
    fi
  fi
  sleep 2
done
