#!/usr/bin/env bash
# bin/consult-research-wait.sh — per-commander wait for {done,error}.
# Master Yoda invokes 2x in parallel (one per trooper).
#
# Usage: bin/consult-research-wait.sh <consult-topic> <commander> <model>
#
# Reads OFFSET= from _consult/research-<commander>.txt; appends FS=<status>.
# Returns rc=0 always — status field carries the outcome.

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/contracts.sh"
source "$PLUGIN_ROOT/lib/consult.sh"

[[ $# -eq 3 ]] || { echo "Usage: $0 <consult-topic> <commander> <model>" >&2; exit 2; }
TOPIC="$1"; COMMANDER="$2"; MODEL="$3"

cw_consult_topic_validate "$TOPIC" || { log_error "invalid topic: $TOPIC"; exit 2; }
[[ "$COMMANDER" =~ ^[a-z0-9_-]+$ ]] || { log_error "invalid commander: $COMMANDER"; exit 2; }

ART_DIR="$(cw_state_root)/state/$(cw_repo_hash)/$TOPIC/_consult"
STATE_FILE="$ART_DIR/research-$COMMANDER.txt"
[[ -f "$STATE_FILE" ]] || { log_error "$STATE_FILE missing — run consult-research-send first"; exit 1; }

# shellcheck disable=SC1090
source "$STATE_FILE"   # sets OFFSET
[[ -n "${OFFSET:-}" ]] || { log_error "OFFSET not set in $STATE_FILE"; exit 1; }

TIMEOUT="${CW_CONSULT_RESEARCH_TIMEOUT_OVERRIDE:-$(cw_consult_timeout research)}"
log_info "[research-wait] $COMMANDER offset=$OFFSET timeout=${TIMEOUT}s"

# v0.3: block on done|error|question; capture nothing (re-scan tail below).
cw_outbox_wait_since "$COMMANDER" "$MODEL" "$TOPIC" "$OFFSET" done error question "$TIMEOUT" >/dev/null || true

TROOPER_DIR=$(cw_trooper_dir "$COMMANDER" "$MODEL" "$TOPIC")
OUTBOX="$TROOPER_DIR/outbox.jsonl"

# v0.3 priority + race fix:
#   1. Terminal events (done/error) WIN over in-flight question events.
#   2. Among questions, FIRST wins (head -n1) — serialization across re-arms.
#   3. NEW_OFFSET is the matched line's exact end-byte (NOT wc -c of outbox,
#      which would silently consume events written after the match).
TAIL=$(tail -c "+$(( OFFSET + 1 ))" "$OUTBOX" 2>/dev/null || true)
MATCHED=$(printf '%s\n' "$TAIL" | grep -m1 -E '"event":"(done|error)"' || true)
[[ -z "$MATCHED" ]] \
  && MATCHED=$(printf '%s\n' "$TAIL" | grep -m1 '"event":"question"' || true)
EVENT=$(printf '%s' "$MATCHED" | sed -n 's/.*"event":"\([^"]*\)".*/\1/p')

if [[ -n "$MATCHED" ]]; then
  NEW_OFFSET=$(cw_consult_outbox_match_endbyte "$OUTBOX" "$OFFSET" "$MATCHED" 2>/dev/null) \
    || NEW_OFFSET="$OFFSET"
else
  NEW_OFFSET="$OFFSET"
fi

case "$EVENT" in
  question)
    if cw_consult_question_extract_to_payload \
         "$MATCHED" "$ART_DIR/question-$COMMANDER.txt" "research"; then
      printf 'OFFSET=%s\n' "$NEW_OFFSET" >> "$STATE_FILE"
      printf 'FS=question\n' >> "$STATE_FILE"
      log_info "[research-wait] $COMMANDER FS=question (offset → $NEW_OFFSET)"
    else
      printf 'FS=failed\n' >> "$STATE_FILE"
      log_warn "[research-wait] $COMMANDER FS=failed (malformed question payload)"
    fi
    ;;
  done)
    FS=$(cw_consult_findings_status "$TROOPER_DIR/findings.md")
    printf 'FS=%s\n' "$FS" >> "$STATE_FILE"
    log_info "[research-wait] $COMMANDER FS=$FS"
    ;;
  error)
    printf 'FS=failed\n' >> "$STATE_FILE"
    log_warn "[research-wait] $COMMANDER FS=failed (error event)"
    ;;
  '')
    printf 'FS=timeout\n' >> "$STATE_FILE"
    log_warn "[research-wait] $COMMANDER FS=timeout"
    ;;
  *)
    printf 'FS=failed\n' >> "$STATE_FILE"
    log_warn "[research-wait] $COMMANDER FS=failed (unknown event '$EVENT')"
    ;;
esac

# v0.5.0 background-await pattern: signal terminal completion to the
# directive's notification handler. The .done sentinel lets the controller
# distinguish a clean exit from a notification-arrived-before-write race.
touch "${STATE_FILE%.txt}.done"
exit 0
