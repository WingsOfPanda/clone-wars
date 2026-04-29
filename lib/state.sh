# lib/state.sh — $CLONE_WARS_HOME resolution and state-dir layout helpers.
# Sourced. All paths are absolute.

cw_state_root() {
  printf '%s\n' "${CLONE_WARS_HOME:-$HOME/.clone-wars}"
}

cw_state_ensure() {
  local root; root=$(cw_state_root)
  mkdir -p "$root/state" "$root/archive"
}

cw_repo_hash() {
  local p
  p=$(realpath "$PWD" 2>/dev/null || readlink -f "$PWD" 2>/dev/null || printf '%s' "$PWD")
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$p" | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$p" | shasum -a 256 | awk '{print $1}'
  else
    echo "cw_repo_hash: no sha256 tool (sha256sum or shasum) found" >&2
    return 1
  fi
}

# cw_repo_root — resolve trooper's working directory.
# Uses git toplevel when inside a repo (so the trooper sees the whole project,
# not just the subdir the conductor happens to be in). Falls back to $PWD for
# non-git dirs. Used by lib/tmux.sh for the -c flag of tmux split-window.
cw_repo_root() {
  local root
  root=$(git rev-parse --show-toplevel 2>/dev/null) && { printf '%s\n' "$root"; return 0; }
  printf '%s\n' "$PWD"
}
