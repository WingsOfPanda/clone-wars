#!/usr/bin/env bash
# Project-level PostToolUse hook for clone-wars.
# Fires after Edit/Write of .claude-plugin/plugin.json. Reads the
# current version field from the file (post-edit) and warns if no
# matching tests/test_v<X_Y_Z>_static_wiring.sh exists.
#
# Advisory only — never blocks. Catches the "T6 bump before T5 lock
# scaffold" mistake. Reading the file post-edit avoids the brittle
# task of parsing escaped JSON quotes out of the Edit tool payload.
set -uo pipefail

# shellcheck source=.claude/hooks/_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
REPO_ROOT=$(cw_hook_repo_root)
file_path=$(cw_hook_file_path_from_stdin)

case "$file_path" in
  *.claude-plugin/plugin.json) ;;
  *) exit 0 ;;
esac

# Read the current version directly from the file.
plugin_json="$REPO_ROOT/.claude-plugin/plugin.json"
[[ -f "$plugin_json" ]] || exit 0

cur_version=$(grep -E '"version"' "$plugin_json" | head -1 \
  | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')

[[ -n "$cur_version" ]] || exit 0

# 0.46.0 → 0_46_0 for lock-file lookup.
token=$(printf '%s' "$cur_version" | tr '.' '_')
lock_file="$REPO_ROOT/tests/test_v${token}_static_wiring.sh"

if [[ ! -f "$lock_file" ]]; then
  echo "[hook] WARN: plugin.json is now at $cur_version, but" >&2
  echo "       $(basename "$lock_file") does not exist." >&2
  echo "       Per release pattern, scaffold the static-wiring lock test BEFORE the version bump (T5 → T6)." >&2
fi

exit 0
