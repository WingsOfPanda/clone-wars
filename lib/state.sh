# lib/state.sh — $CLONE_WARS_HOME resolution and state-dir layout helpers.
# Sourced. All paths are absolute.

cw_state_root() {
  printf '%s\n' "${CLONE_WARS_HOME:-$HOME/.clone-wars}"
}

cw_state_ensure() {
  local root; root=$(cw_state_root)
  mkdir -p "$root/state" "$root/archive"
}
