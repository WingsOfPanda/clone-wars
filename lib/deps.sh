# lib/deps.sh — binary presence + version + tmux env checks.
# Sourced. Returns 0/1 — does not exit; callers decide how to react.

cw_have_cmd() {
  command -v "$1" >/dev/null 2>&1
}
