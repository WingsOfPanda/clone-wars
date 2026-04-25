# lib/deps.sh — binary presence + version + tmux env checks.
# Sourced. Returns 0/1 — does not exit; callers decide how to react.

cw_have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

# Print the raw `tmux -V` line, e.g. "tmux 3.4". Overridable in tests.
cw_tmux_version_string() {
  cw_have_cmd tmux || return 1
  tmux -V 2>/dev/null
}

# Return 0 iff tmux ≥ 3.0.
cw_tmux_version_ok() {
  local v major
  v=$(cw_tmux_version_string) || return 1
  # Strip "tmux " prefix and any non-numeric suffix on the major.
  v=${v#tmux }
  major=${v%%.*}
  # Drop trailing letters from major (e.g. "3a" → "3"); but typical is "3.0a" so major is "3".
  major=${major//[^0-9]/}
  [[ -n "$major" && "$major" -ge 3 ]]
}
