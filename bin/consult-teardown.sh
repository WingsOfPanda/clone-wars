#!/usr/bin/env bash
# bin/consult-teardown.sh — kill consult panes + archive trooper state.
#
# v0.15.0: iterates _consult/troopers.txt (TSV: <provider>\t<commander>) so the
# teardown scales to N troopers (2/3) instead of the legacy hardcoded rex+cody
# pair. Per-trooper errors are reported via log_warn and the loop continues so
# one failed pane never blocks the others from being archived. When troopers.txt
# is missing (defensive: pre-v0.15 archived state, or a consult that failed
# before consult-init wrote it), falls back to `bin/teardown.sh <topic>` which
# discovers troopers via filesystem scan of the topic dir.
#
# Usage: bin/consult-teardown.sh <consult-topic>

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/tmux.sh"

[[ $# -eq 1 ]] || { echo "Usage: $0 <consult-topic>" >&2; exit 2; }
TOPIC="$1"
cw_consult_assert_topic "$TOPIC"

ART_DIR=$(cw_consult_art_dir "$TOPIC")
TROOPERS_FILE="$ART_DIR/troopers.txt"

if [[ -f "$TROOPERS_FILE" ]]; then
  # v0.20.5: collect commanders from troopers.txt and invoke teardown.sh
  # ONCE in --pairs mode so all panes share a single 9s graceful-banner
  # sleep (parallel via _teardown_batch). The previous per-commander
  # loop hit the 9s sleep N times sequentially. troopers.txt selectivity
  # is preserved — rogue dirs not in troopers.txt are left alone.
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

# v0.29.0: shared helper handles troopers.txt parse + orphan kill + cleanup
# (extracted from this script + meditate-teardown.sh + deep-research-teardown.sh).
cw_teardown_with_preflight_orphans "$ART_DIR" "$TROOPERS_FILE" 2col
