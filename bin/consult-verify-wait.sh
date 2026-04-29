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

cw_outbox_wait_since "$COMMANDER" "$MODEL" "$TOPIC" "$OFFSET" done error "$TIMEOUT" >/dev/null
WAIT_RC=$?

TROOPER_DIR=$(cw_trooper_dir "$COMMANDER" "$MODEL" "$TOPIC")
VERIFY_FILE="$TROOPER_DIR/verify.md"

if [[ -s "$VERIFY_FILE" ]]; then
  VS=ok
elif [[ "$WAIT_RC" -ne 0 ]]; then
  VS=timeout
else
  VS=missing
fi

printf 'VS=%s\n' "$VS" >> "$STATE_FILE"
log_info "[verify-wait] $COMMANDER VS=$VS"
