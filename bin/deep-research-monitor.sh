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
# shellcheck source=../lib/state.sh
source "$PLUGIN_ROOT/lib/state.sh"
# shellcheck source=../lib/ipc.sh
source "$PLUGIN_ROOT/lib/ipc.sh"
# shellcheck source=../lib/deep-research.sh
source "$PLUGIN_ROOT/lib/deep-research.sh"

[[ $# -eq 2 ]] || { echo "Usage: $0 <art-dir> <commander>" >&2; exit 2; }
ART_DIR="$1"; COMMANDER="$2"

[[ -d "$ART_DIR" ]] || { echo "monitor: art-dir missing: $ART_DIR" >&2; exit 2; }

PROBE_S="${CW_DEEP_RESEARCH_PROBE_S:-900}"
STUCK_S="${CW_DEEP_RESEARCH_STUCK_S:-1800}"
# v0.32.0 #2: periodic rescan safety net — re-read outbox every N
# seconds and emit any done/error/question we haven't already rescanned.
RESCAN_EVERY_S="${CW_DEEP_RESEARCH_RESCAN_EVERY_S:-30}"

TOPIC_DIR=$(dirname "$ART_DIR")
OUTBOX="$(cw_outbox_path_in "$TOPIC_DIR" "$COMMANDER" codex)"
CURSOR_FILE="$ART_DIR/troopers/$COMMANDER/liveness-cursor.txt"
mkdir -p "$(dirname "$CURSOR_FILE")"

# v0.32.0 #3: cursor persists across restarts. Honor previous offset if
# valid; otherwise initialize to current outbox size (skip prior events).
cur_size=$(wc -c < "$OUTBOX" 2>/dev/null || echo 0)
if [[ -s "$CURSOR_FILE" ]]; then
  prev=$(<"$CURSOR_FILE")
  prev="${prev//[[:space:]]/}"
  if [[ "$prev" =~ ^[0-9]+$ ]] && (( prev <= cur_size )); then
    OFFSET=$prev
  else
    OFFSET=$cur_size
  fi
else
  OFFSET=$cur_size
fi
printf '%d' "$OFFSET" > "$CURSOR_FILE"

LAST_STALE_TS=0
LAST_STUCK_TS=0

# v0.32.0 #2: rescan dedup set keyed by "<line-num>\t<event>". Touch the
# file so grep -q operates on an existing file even on first run.
RESCAN_CURSOR_FILE="$ART_DIR/troopers/$COMMANDER/liveness-rescan-emitted.txt"
touch "$RESCAN_CURSOR_FILE"
LAST_RESCAN=0

# v0.32.0 #2+#3 interaction: on cursor-restore, pre-seed the rescan
# dedup set with all <line-num>\t<event> pairs that fall below the
# restored byte-cursor — those have already been seen by a prior byte-tail
# pass, so the rescan loop must not re-emit them.
if (( OFFSET > 0 )) && [[ -f "$OUTBOX" ]]; then
  bytes_seen=0
  pre_ln=0
  while IFS= read -r pre_line; do
    pre_ln=$((pre_ln + 1))
    # +1 byte accounts for the trailing newline that `read` consumes.
    bytes_seen=$((bytes_seen + ${#pre_line} + 1))
    pre_ev=$(cw_event_name_extract "$pre_line")
    case "$pre_ev" in
      done|error|question)
        if ! grep -qE "^${pre_ln}	${pre_ev}\$" "$RESCAN_CURSOR_FILE" 2>/dev/null; then
          printf '%d\t%s\n' "$pre_ln" "$pre_ev" >> "$RESCAN_CURSOR_FILE"
        fi
        ;;
    esac
    (( bytes_seen >= OFFSET )) && break
  done < "$OUTBOX"
fi

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
        ev=$(cw_event_name_extract "$line")
        case "$ev" in
          done|error|question|heartbeat)
            summary=$(cw_jsonl_string_field "$line" summary)
            emit "$ev" "$summary"
            ;;
        esac
      done
      OFFSET=$local_size
      # v0.32.0 #3: writeback cursor after each tail pass so a restart
      # doesn't replay events we just emitted.
      printf '%d' "$OFFSET" > "$CURSOR_FILE"
    fi

    # v0.32.0 #1: phase-aware liveness — only emit stale/stuck when
    # phase=working. Once Yoda probes a stale trooper (phase=stale) or
    # the trooper blocks on a question (phase=blocked), Monitor goes
    # silent. Yoda owns escalation. Missing state.txt → empty phase → skip.
    phase=$(cw_deep_research_trooper_state_field "$ART_DIR" "$COMMANDER" phase 2>/dev/null || echo "")
    if [[ "$phase" == "working" ]]; then
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
  fi

  # v0.32.0 #2: periodic rescan safety net
  now_rescan=$(date +%s)
  if (( now_rescan - LAST_RESCAN >= RESCAN_EVERY_S )) && [[ -f "$OUTBOX" ]]; then
    line_num=0
    while IFS= read -r rline; do
      line_num=$((line_num + 1))
      rev=$(cw_event_name_extract "$rline")
      case "$rev" in
        done|error|question)
          # Dedup against liveness-rescan-emitted.txt — TAB-separated
          # <line-num><TAB><event>.
          if ! grep -qE "^${line_num}	${rev}\$" "$RESCAN_CURSOR_FILE" 2>/dev/null; then
            rsum=$(cw_jsonl_string_field "$rline" summary)
            emit "$rev" "${rsum} (rescan)"
            printf '%d\t%s\n' "$line_num" "$rev" >> "$RESCAN_CURSOR_FILE"
          fi
          ;;
      esac
    done < "$OUTBOX"
    LAST_RESCAN=$now_rescan
  fi

  sleep 2
done
