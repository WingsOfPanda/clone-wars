#!/usr/bin/env bash
# bin/deep-research-fresh-trooper.sh — v0.34.0 D1
# Graceful codex session reset by pane respawn. state.txt (exp_counter,
# experiment history) preserved; phase reset to idle; last_event=fresh-trooper-respawn.
#
# Usage: bin/deep-research-fresh-trooper.sh <topic> <commander>
#
# Exit codes:
#   0 = ok
#   1 = trooper state or pane missing; OR phase=working (refuse mid-experiment)
#   2 = usage error / invalid topic / invalid commander

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"

[[ $# -eq 2 ]] || { log_error "Usage: $0 <topic> <commander>"; exit 2; }
TOPIC="$1"
COMMANDER="$2"

# Auto-prefix common typo (parallel v0.32.0 experiment-send.sh #7)
[[ "$TOPIC" == deep-research-* ]] || TOPIC="deep-research-$TOPIC"
cw_consult_topic_validate "$TOPIC" || { log_error "invalid topic: $TOPIC"; exit 2; }

[[ "$COMMANDER" =~ ^[a-z][a-z0-9-]*$ ]] \
  || { log_error "commander must match [a-z][a-z0-9-]*; got '$COMMANDER'"; exit 2; }

TOPIC_DIR="$(cw_topic_state_dir "$TOPIC")"
ART_DIR="$TOPIC_DIR/_deep-research"
STATE_FILE="$ART_DIR/troopers/$COMMANDER/state.txt"
[[ -f "$STATE_FILE" ]] \
  || { log_error "trooper state.txt missing: $STATE_FILE"; exit 1; }

cur_phase=$(cw_deep_research_trooper_state_field "$ART_DIR" "$COMMANDER" phase)
if [[ "$cur_phase" == "working" ]]; then
  log_error "trooper $COMMANDER is mid-experiment (phase=working); abort or wait for done before fresh-trooper."
  exit 1
fi

# Preserve experiment counter + history; clear runtime state.
prev_counter=$(cw_deep_research_trooper_state_field "$ART_DIR" "$COMMANDER" exp_counter)
[[ "$prev_counter" =~ ^[0-9]+$ ]] || prev_counter=0

# Teardown the live pane gracefully (9s banner). Script handles missing-pane
# cases internally.
log_info "[fresh-trooper] tearing down $COMMANDER's pane on $TOPIC ..."
"$PLUGIN_ROOT/bin/teardown.sh" --pairs "$TOPIC" "$COMMANDER" 2>/dev/null || true

# Respawn in a new pane — same commander, same topic.
log_info "[fresh-trooper] respawning $COMMANDER ..."
"$PLUGIN_ROOT/bin/spawn.sh" "$COMMANDER" codex "$TOPIC" >/dev/null \
  || { log_error "spawn failed for $COMMANDER on $TOPIC"; exit 1; }

# Reset runtime state (preserve exp_counter so the next dispatch numbers correctly).
cw_deep_research_trooper_state_write "$ART_DIR" "$COMMANDER" \
  phase=idle \
  current_exp_id= \
  exp_counter="$prev_counter" \
  last_event_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  last_event=fresh-trooper-respawn \
  probe_sent_ts=

# Surface new pane id (best-effort).
pane_id=""
pane_id_file="$TOPIC_DIR/$COMMANDER-codex/pane.json"
if [[ -f "$pane_id_file" ]]; then
  pane_id=$(grep -oE '"pane_id"[[:space:]]*:[[:space:]]*"%[0-9]+"' "$pane_id_file" \
    | grep -oE '%[0-9]+' | head -1)
fi
log_ok "[fresh-trooper] $COMMANDER respawned ${pane_id:+(pane $pane_id) }on $TOPIC; state preserved (exp_counter=$prev_counter)"
