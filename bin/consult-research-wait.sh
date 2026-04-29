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

cw_outbox_wait_since "$COMMANDER" "$MODEL" "$TOPIC" "$OFFSET" done error "$TIMEOUT" >/dev/null || true
# rc is intentionally ignored — status comes from cw_consult_findings_status.

TROOPER_DIR=$(cw_trooper_dir "$COMMANDER" "$MODEL" "$TOPIC")
FS=$(cw_consult_findings_status "$TROOPER_DIR/findings.md")
printf 'FS=%s\n' "$FS" >> "$STATE_FILE"
log_info "[research-wait] $COMMANDER FS=$FS"
