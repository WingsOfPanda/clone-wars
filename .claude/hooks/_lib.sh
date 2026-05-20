# .claude/hooks/_lib.sh — shared helpers for project-level PostToolUse hooks.
# Sourced by hook scripts in the same dir. Underscore prefix marks this as
# private to the hooks (not part of the plugin runtime).

# cw_hook_repo_root — absolute path to the clone-wars repo root.
# Walks up two dirs from the SOURCING script's location (not this helper's
# location), so callers under .claude/hooks/<name>.sh resolve to the repo
# root. Uses ${BASH_SOURCE[1]} = the sourcing script's path.
cw_hook_repo_root() {
  cd "$(dirname "${BASH_SOURCE[1]}")/../.." && pwd
}

# cw_hook_file_path_from_stdin — extract tool_input.file_path from
# Claude Code's hook JSON payload (no jq dep). Reads stdin; prints the
# value or empty if absent.
cw_hook_file_path_from_stdin() {
  local input; input=$(cat 2>/dev/null || true)
  # `|| true` swallows grep's exit=1 on no-match so callers running
  # under `set -euo pipefail` don't abort on absent file_path.
  printf '%s' "$input" \
    | { grep -oE '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' || true; } \
    | head -1 \
    | sed -E 's/.*"file_path"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/'
}
