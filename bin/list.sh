#!/usr/bin/env bash
# bin/list.sh — show active troopers across topics (or scoped to one).
#
# Usage:
#   bin/list.sh [<topic>]
#
# For each trooper:
#   - Reads pane.json for the recorded pane id
#   - Cross-checks with `tmux list-panes -a` for liveness
#   - Reads the last outbox event for state
#   - Flags orphans (state dir present, pane dead) as [ORPHAN]

set -uo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/tmux.sh"

TOPIC_FILTER="${1:-}"

REPO_DIR="$(cw_state_root)/state/$(cw_repo_hash)"
if [[ ! -d "$REPO_DIR" ]]; then
  echo "no troopers deployed (state dir absent: $REPO_DIR)"
  exit 0
fi

printf '%-32s %-8s %-12s %-9s %s\n' \
  'TROOPER' 'MODEL' 'TOPIC' 'PANE' 'STATE'
printf '%-32s %-8s %-12s %-9s %s\n' \
  '--------------------------------' '--------' '------------' '---------' '-----'

shopt -s nullglob
for topic_dir in "$REPO_DIR"/*/; do
  topic="${topic_dir%/}"; topic="${topic##*/}"
  [[ -z "$TOPIC_FILTER" || "$topic" == "$TOPIC_FILTER" ]] || continue
  for trooper_dir in "$topic_dir"*/; do
    [[ -d "$trooper_dir" ]] || continue
    mapfile -t META < <(cw_pane_meta_read_for_dir "$trooper_dir")
    commander="${META[0]}"
    model="${META[1]}"
    pane="${META[2]:-?}"
    [[ -z "$pane" ]] && pane='?'
    state='[ORPHAN]'
    if [[ "$pane" != '?' ]] && cw_pane_alive "$pane"; then
      outbox=$(cw_outbox_path "$commander" "$model" "$topic")
      if [[ -f "$outbox" && -s "$outbox" ]]; then
        last_event=$(tail -n1 "$outbox" | grep -oE '"event":"[^"]+"' | head -n1 | cut -d'"' -f4)
      else
        last_event='?'
      fi
      case "$last_event" in
        done)  state='idle (done)'   ;;
        error) state='idle (error)'  ;;
        ack)   state='working'       ;;
        ready) state='ready'         ;;
        '')    state='spawning'      ;;
        *)     state="$last_event"   ;;
      esac
    fi
    printf '%-32s %-8s %-12s %-9s %s\n' "$commander" "$model" "$topic" "$pane" "$state"
  done
done
