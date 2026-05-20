#!/usr/bin/env bash
# bin/deep-research-abort.sh — v0.32.0 #16
# One-shot graceful teardown for a /clone-wars:deep-research session.
#
# Usage: bin/deep-research-abort.sh <topic> [<reason>]
#
# Exit codes:
#   0 = ok
#   1 = no active deep-research session for topic
#   2 = usage error / invalid topic
#
# Flow:
#   1. Validate args, auto-prefix topic if needed.
#   2. Resolve ART_DIR; refuse if absent.
#   3. Read monitor-tasks.txt (capture in memory before teardown).
#   4. Write halt.flag with reason.
#   5. Invoke deep-research-finalize.sh.
#   6. Invoke deep-research-teardown.sh (archives state).
#   7. Print TaskStop deferral hint.

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"

[[ $# -ge 1 && $# -le 2 ]] \
  || { log_error "Usage: $0 <topic> [<reason>]"; exit 2; }
TOPIC="$1"
REASON="${2:-unspecified}"

cw_deep_research_normalize_topic TOPIC

ART_DIR="$(cw_deep_research_art_dir "$TOPIC")"
[[ -d "$ART_DIR" ]] \
  || { log_error "no active deep-research session for topic: $TOPIC (art-dir $ART_DIR missing)"; exit 1; }

# Capture monitor task IDs BEFORE teardown moves the file into archive
MONITOR_TASKS=()
if [[ -f "$ART_DIR/monitor-tasks.txt" ]]; then
  while IFS= read -r tid; do
    [[ -n "$tid" ]] && MONITOR_TASKS+=("$tid")
  done < "$ART_DIR/monitor-tasks.txt"
fi

# Write halt.flag (v0.43.0 Lane E — structured key=value format)
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
{
  printf 'halted_by=user\n'
  printf 'halted_at=%s\n' "$now"
  printf 'reason=%s\n' "$REASON"
} > "$ART_DIR/halt.flag"
log_info "halt.flag written ($REASON)"

# Finalize (renders ## Halt section into session-summary.md; idempotent)
"$PLUGIN_ROOT/bin/deep-research-finalize.sh" "$TOPIC" \
  || { log_error "finalize failed"; exit 1; }

# Teardown (archives state dir; kills any trooper panes via --pairs)
"$PLUGIN_ROOT/bin/deep-research-teardown.sh" "$TOPIC" \
  || { log_error "teardown failed"; exit 1; }

# TaskStop deferral hint
if (( ${#MONITOR_TASKS[@]} > 0 )); then
  log_info "note: ${#MONITOR_TASKS[@]} Monitor task(s) still active; will TaskStop on next Yoda turn (halt.flag detected):"
  for tid in "${MONITOR_TASKS[@]}"; do
    log_info "  - $tid"
  done
else
  log_info "no Monitor tasks to stop"
fi

log_ok "deep-research session $TOPIC aborted"
