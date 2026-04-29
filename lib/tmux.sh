# lib/tmux.sh — tmux pane lifecycle helpers for Clone Wars troopers.
# Sourced. Depends on lib/log.sh, lib/state.sh, lib/colors.sh.
#
# Pane identity is carried via three OSC-immune custom user-options:
#   @cw_label      — plain text "<rank>-<commander>:<model>:<topic>"
#   @cw_color      — primary Morandi color (used by active-border hook)
#   @cw_label_fmt  — pre-rendered colored label (read by pane-border-format)

# cw_pane_spawn_right <commander> <model> <topic> <launch_cmd> [<target_pane>]
# Splits horizontally (right) of <target_pane> if given, else of the Jedi general's pane.
# Sets the three @cw_* user-options. Returns: pane id on stdout (e.g. "%62").
cw_pane_spawn_right() {
  local commander="$1" model="$2" topic="$3" launch="$4" target="${5:-}"
  local pane
  if [[ -n "$target" ]]; then
    pane=$(tmux split-window -P -F '#{pane_id}' -h -t "$target" -c "$PWD" "$launch")
  else
    pane=$(tmux split-window -P -F '#{pane_id}' -h -c "$PWD" "$launch")
  fi
  cw_pane_label_set "$pane" "$commander" "$model" "$topic"
  printf '%s\n' "$pane"
}

# cw_pane_spawn_down <commander> <model> <topic> <launch_cmd> <target_pane>
# Splits vertically (down) of <target_pane> — used for second-and-later
# troopers in the same topic per docs/DESIGN.md §Pane layout.
cw_pane_spawn_down() {
  local commander="$1" model="$2" topic="$3" launch="$4" target="$5"
  local pane
  pane=$(tmux split-window -P -F '#{pane_id}' -v -t "$target" -c "$PWD" "$launch")
  cw_pane_label_set "$pane" "$commander" "$model" "$topic"
  printf '%s\n' "$pane"
}

# cw_pane_label_set <pane> <commander> <model> <topic>
# Stamps the three @cw_* user-options on a pane. Idempotent.
cw_pane_label_set() {
  local pane="$1" commander="$2" model="$3" topic="$4"
  tmux set-option -p -t "$pane" @cw_label    "$(cw_label_for     "$commander" "$model" "$topic")"
  tmux set-option -p -t "$pane" @cw_color    "$(cw_color_for     "$commander")"
  tmux set-option -p -t "$pane" @cw_label_fmt "$(cw_label_fmt    "$commander" "$model" "$topic")"
}

# cw_pane_label <pane> — print the @cw_label of <pane>.
cw_pane_label() {
  tmux display-message -p -t "$1" '#{@cw_label}' 2>/dev/null
}

# cw_pane_color <pane> — print the @cw_color of <pane>.
cw_pane_color() {
  tmux display-message -p -t "$1" '#{@cw_color}' 2>/dev/null
}

# cw_pane_alive <pane> — return 0 iff <pane> exists in tmux.
cw_pane_alive() {
  tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qx "$1"
}

# cw_pane_send <pane> <line>
# Send a single line of input to a pane via send-keys -l (literal, no keymap
# interpretation), followed by Enter. Used for nudges.
cw_pane_send() {
  local pane="$1" line="$2"
  tmux send-keys -t "$pane" -l "$line"
  sleep 0.3
  tmux send-keys -t "$pane" Enter
}

# cw_pane_kill_graceful <pane>
# Replaces the trooper's TUI with a snapshot + colored "MISSION ACCOMPLISHED"
# banner + 8s countdown via bin/_close-banner.sh, then kills the pane.
# Caller is responsible for waiting ~9s before issuing further actions.
cw_pane_kill_graceful() {
  local pane="$1"
  cw_pane_alive "$pane" || return 0
  local label color snap
  label=$(cw_pane_label "$pane"); [[ -z "$label" ]] && label="trooper"
  color=$(cw_pane_color "$pane")
  snap=$(mktemp -t cw-snap-XXXXXX.txt)
  tmux capture-pane -p -e -t "$pane" > "$snap" 2>/dev/null
  tmux respawn-pane -k -t "$pane" \
    "cat '$snap'; '$PLUGIN_ROOT/bin/_close-banner.sh' '$label' '$color'; rm -f '$snap'" 2>/dev/null
}

# cw_pane_kill_now <pane>
# Hard kill — no banner. For error paths and orphan cleanup.
cw_pane_kill_now() {
  local pane="$1"
  tmux kill-pane -t "$pane" 2>/dev/null || true
}
