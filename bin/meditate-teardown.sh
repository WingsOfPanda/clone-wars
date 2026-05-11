#!/usr/bin/env bash
# bin/meditate-teardown.sh — kill meditate panes + archive trooper state.
#
# Usage: bin/meditate-teardown.sh <meditate-topic>
#
# Mirrors bin/consult-teardown.sh but reads from _meditate/. v0.20.5
# --pairs mode is used so all panes share a single 9s graceful-banner
# sleep. v0.19.0/v0.24.0 preflight-orphan cleanup is reused.

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/meditate.sh"
source "$PLUGIN_ROOT/lib/tmux.sh"

[[ $# -eq 1 ]] || { echo "Usage: $0 <meditate-topic>" >&2; exit 2; }
TOPIC="$1"
[[ "$TOPIC" == meditate-* ]] || { log_error "topic must start with 'meditate-': $TOPIC"; exit 2; }

ART_DIR=$(cw_meditate_art_dir "$TOPIC")
TROOPERS_FILE="$ART_DIR/troopers.txt"

if [[ -f "$TROOPERS_FILE" ]]; then
  CMDRS=()
  while IFS=$'\t' read -r prov cmdr; do
    [[ -n "$cmdr" ]] || continue
    log_info "queued for teardown: $cmdr-$prov"
    CMDRS+=("$cmdr")
  done < <(cw_consult_load_troopers "$TROOPERS_FILE")
  if (( ${#CMDRS[@]} > 0 )); then
    "$PLUGIN_ROOT/bin/teardown.sh" --pairs "$TOPIC" "${CMDRS[@]}" \
      || log_warn "teardown failed for $TOPIC (continuing)"
  fi
else
  log_warn "troopers.txt missing for '$TOPIC'; falling back to topic-scan teardown"
  "$PLUGIN_ROOT/bin/teardown.sh" "$TOPIC" \
    || log_warn "teardown failed for $TOPIC (continuing)"
fi

# Preflight orphan cleanup
LIVE_CMDRS=()
if [[ -f "$TROOPERS_FILE" ]]; then
  while IFS=$'\t' read -r prov cmdr; do
    [[ -n "$cmdr" ]] && LIVE_CMDRS+=("$cmdr")
  done < <(cw_consult_load_troopers "$TROOPERS_FILE")
fi
cw_preflight_kill_orphans "$ART_DIR/preflight-panes.txt" "${LIVE_CMDRS[@]}"
