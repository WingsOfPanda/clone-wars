#!/usr/bin/env bash
# bin/consult-verify-wait.sh — per-commander verify wait.
#
# Usage: bin/consult-verify-wait.sh <consult-topic> <commander> <model>
#
# Reads OFFSET= from _consult/verify-<commander>.txt (or VS=skipped → no-op).
# Appends VS=<status> based on wait outcome + verify.md presence.

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
STATE_FILE="$ART_DIR/verify-$COMMANDER.txt"
[[ -f "$STATE_FILE" ]] || { log_error "$STATE_FILE missing — run consult-verify-send first"; exit 1; }

# Short-circuit if already skipped.
if grep -q '^VS=skipped' "$STATE_FILE"; then
  log_info "[verify-wait] $COMMANDER skipped (already)"
  exit 0
fi

unset OFFSET
# shellcheck disable=SC1090
source "$STATE_FILE"
[[ -n "${OFFSET:-}" ]] || { log_error "OFFSET not set in $STATE_FILE"; exit 1; }

TIMEOUT="${CW_CONSULT_VERIFY_TIMEOUT_OVERRIDE:-$(cw_consult_timeout verify)}"
log_info "[verify-wait] $COMMANDER offset=$OFFSET timeout=${TIMEOUT}s"

# v0.3: block on done|error|question; capture nothing (re-scan tail below).
cw_outbox_wait_since "$COMMANDER" "$MODEL" "$TOPIC" "$OFFSET" done error question "$TIMEOUT" >/dev/null || true

TROOPER_DIR=$(cw_trooper_dir "$COMMANDER" "$MODEL" "$TOPIC")
OUTBOX="$TROOPER_DIR/outbox.jsonl"
VERIFY_FILE="$TROOPER_DIR/verify.md"

# v0.3 priority + race fix (mirror of research-wait).
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
         "$MATCHED" "$ART_DIR/question-$COMMANDER.txt" "verify"; then
      printf 'OFFSET=%s\n' "$NEW_OFFSET" >> "$STATE_FILE"
      printf 'VS=question\n' >> "$STATE_FILE"
      log_info "[verify-wait] $COMMANDER VS=question (offset → $NEW_OFFSET)"
    else
      printf 'VS=failed\n' >> "$STATE_FILE"
      log_warn "[verify-wait] $COMMANDER VS=failed (malformed question payload)"
    fi
    ;;
  done)
    if [[ -s "$VERIFY_FILE" ]]; then VS=ok; else VS=missing; fi
    printf 'VS=%s\n' "$VS" >> "$STATE_FILE"
    log_info "[verify-wait] $COMMANDER VS=$VS"
    ;;
  error)
    printf 'VS=failed\n' >> "$STATE_FILE"
    log_warn "[verify-wait] $COMMANDER VS=failed (error event)"
    ;;
  '')
    printf 'VS=timeout\n' >> "$STATE_FILE"
    log_warn "[verify-wait] $COMMANDER VS=timeout"
    ;;
  *)
    printf 'VS=failed\n' >> "$STATE_FILE"
    log_warn "[verify-wait] $COMMANDER VS=failed (unknown event '$EVENT')"
    ;;
esac
