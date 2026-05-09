#!/usr/bin/env bash
# bin/preflight-layout.sh — pre-allocate N tmux panes for a consult run.
#
# Usage: bin/preflight-layout.sh <topic> <N>
#
# Reads _consult/<topic>/troopers.txt for commander order; splits N panes
# off Yoda's pane (the pane the conductor is running in); applies tmux
# select-layout main-vertical to redistribute heights evenly; writes
# ordered _consult/<topic>/preflight-panes.txt (TSV: <commander>\t<pane_id>).
#
# Each preflight pane runs a colored sentinel banner that identifies its
# reserved commander. bin/spawn.sh --target-pane <id> later replaces the
# sentinel with the live trooper TUI via tmux respawn-pane -k.
#
# Atomic: any failure mid-preflight kills already-created panes and exits 1.

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/colors.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/tmux.sh"

[[ $# -eq 2 ]] || { echo "Usage: $0 <topic> <N>" >&2; exit 2; }
TOPIC="$1"
N="$2"

# Validate
if ! [[ "$TOPIC" =~ ^[a-z0-9-]+$ ]] || (( ${#TOPIC} > 64 )); then
  log_error "topic must match [a-z0-9-]+ and be <= 64 chars; got: '$TOPIC'"
  exit 2
fi
if ! [[ "$N" =~ ^[0-9]+$ ]] || (( N < 2 || N > 4 )); then
  log_error "N must be 2..4; got: '$N'"
  exit 2
fi

# Resolve topic + roster
ART_DIR="$(cw_consult_art_dir "$TOPIC")"
ROSTER_FILE="$ART_DIR/troopers.txt"
[[ -f "$ROSTER_FILE" ]] || { log_error "troopers.txt not found at $ROSTER_FILE"; exit 1; }

mapfile -t ROSTER < <(cw_consult_load_troopers "$ROSTER_FILE")
(( ${#ROSTER[@]} == N )) || {
  log_error "troopers.txt has ${#ROSTER[@]} entries, expected $N"
  exit 1
}

# Discover Yoda's pane — the pane the conductor (this script's caller) is
# running in. Prefer $TMUX_PANE (set by tmux per-pane env), fall back to
# `tmux display-message` which returns the active pane in the active client.
# The fallback is unsafe in headless contexts (no client = "active pane"
# defaults to the client's last focus) so $TMUX_PANE must win when present.
YODA_PANE="${TMUX_PANE:-$(tmux display-message -p '#{pane_id}' 2>/dev/null || true)}"
[[ -n "$YODA_PANE" ]] || { log_error "could not discover Yoda's pane; not in tmux?"; exit 1; }

# Created panes — used by trap-driven rollback
declare -a CREATED_PANES=()

rollback() {
  local rc=$?
  if (( rc != 0 )); then
    log_warn "preflight failed (rc=$rc); rolling back ${#CREATED_PANES[@]} pane(s)"
    for p in "${CREATED_PANES[@]}"; do
      tmux kill-pane -t "$p" 2>/dev/null || true
    done
    rm -f "$ART_DIR/preflight-panes.txt.tmp"
  fi
}
trap rollback EXIT

TMP_FILE="$ART_DIR/preflight-panes.txt.tmp"
: > "$TMP_FILE"

# Build sentinel command for a commander. Uses cw_label_fmt for color, then
# sleep infinity to hold the pane open until respawn-pane replaces it.
build_sentinel() {
  local commander="$1" provider="$2" topic="$3"
  local label_fmt
  label_fmt=$(cw_label_fmt "$commander" "$provider" "$topic")
  printf 'printf "%s\\n  preflight pane reserved — awaiting trooper spawn...\\n"; sleep infinity' "$label_fmt"
}

# First pane: right-split Yoda. Subsequent: down-split the previous pane.
PREV_PANE="$YODA_PANE"
SPLIT_FLAG="-h"  # first split is horizontal; rest are vertical

for i in "${!ROSTER[@]}"; do
  IFS=$'\t' read -r prov cmdr <<<"${ROSTER[$i]}"
  sentinel=$(build_sentinel "$cmdr" "$prov" "$TOPIC")
  PANE=$(tmux split-window -P -F '#{pane_id}' "$SPLIT_FLAG" -t "$PREV_PANE" "$sentinel") || {
    log_error "split-window failed at index $i ($cmdr)"
    exit 1
  }
  CREATED_PANES+=( "$PANE" )
  cw_pane_label_set "$PANE" "$cmdr" "$prov" "$TOPIC" || {
    log_error "cw_pane_label_set failed for pane $PANE"
    exit 1
  }
  printf '%s\t%s\n' "$cmdr" "$PANE" >> "$TMP_FILE"
  PREV_PANE="$PANE"
  SPLIT_FLAG="-v"  # subsequent splits are vertical (down)
done

# Redistribute heights evenly via main-vertical
tmux select-layout -t "$YODA_PANE" main-vertical || {
  log_error "select-layout main-vertical failed"
  exit 1
}

# Atomic rename
mv "$TMP_FILE" "$ART_DIR/preflight-panes.txt" || {
  log_error "mv preflight-panes.txt.tmp failed"
  exit 1
}

# Disarm rollback by clearing the array (nothing to roll back on success)
CREATED_PANES=()

log_ok "preflight: $N panes allocated for topic $TOPIC"
while IFS= read -r line; do
  printf '  %s\n' "$line"
done < "$ART_DIR/preflight-panes.txt"
exit 0
