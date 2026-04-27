#!/usr/bin/env bash
# bin/collect.sh — block until a trooper reports {done} or {error}.
#
# Usage:
#   bin/collect.sh <commander> <topic> [--timeout <seconds>]
#
# Prints the matching JSON event line on success. Exit 1 on timeout or {error}.

set -uo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/argsfile.sh"

# --args-file <path> — read tokens from <path> and replace positional args.
# Used by commands/*.md to fence off shell injection from $ARGUMENTS.
if [[ "${1:-}" == "--args-file" ]]; then
  [[ -n "${2:-}" ]] || { echo "--args-file requires a path" >&2; exit 2; }
  args_file="$2"
  shift 2
  mapfile -t _TOKENS < <(cw_args_file_load "$args_file")
  set -- "${_TOKENS[@]}" "$@"
fi

usage() {
  echo "Usage: $0 <commander> <topic> [--timeout <seconds>]" >&2
}

[[ $# -ge 2 ]] || { usage; exit 2; }

COMMANDER="$1"; TOPIC="$2"; shift 2
TIMEOUT=600
while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout)   TIMEOUT="$2"; shift 2 ;;
    --timeout=*) TIMEOUT="${1#*=}"; shift ;;
    *)           echo "unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

# ------------------------------------------------------------ Resolve model

TOPIC_DIR="$(cw_state_root)/state/$(cw_repo_hash)/$TOPIC"
MODEL_HINT=""
if [[ -d "$TOPIC_DIR" ]]; then
  for d in "$TOPIC_DIR"/${COMMANDER}-*; do
    [[ -d "$d" ]] || continue
    MODEL_HINT="${d##*/${COMMANDER}-}"
    break
  done
fi
[[ -n "$MODEL_HINT" ]] || { log_error "no trooper '$COMMANDER' on topic '$TOPIC'"; exit 1; }
MODEL=$(cw_pane_meta_model "$COMMANDER" "$MODEL_HINT" "$TOPIC")

# ------------------------------------------------------------ Poll outbox

OUTBOX=$(cw_outbox_path "$COMMANDER" "$MODEL" "$TOPIC")
log_info "tailing $OUTBOX (timeout ${TIMEOUT}s)"

DONE_PAT=$(cw_event_match_pattern done)
ERROR_PAT=$(cw_event_match_pattern error)
for ((i = 0; i < TIMEOUT; i++)); do
  if grep -qE "$DONE_PAT" "$OUTBOX" 2>/dev/null; then
    EVENT=$(grep -E "$DONE_PAT" "$OUTBOX" | tail -n1)
    log_ok "{done} received"
    echo "$EVENT"
    exit 0
  fi
  if grep -qE "$ERROR_PAT" "$OUTBOX" 2>/dev/null; then
    EVENT=$(grep -E "$ERROR_PAT" "$OUTBOX" | tail -n1)
    log_error "{error} received from $COMMANDER"
    echo "$EVENT"
    exit 1
  fi
  sleep 1
done

log_error "timeout after ${TIMEOUT}s; outbox tail:"
tail -n 5 "$OUTBOX" >&2
exit 1
