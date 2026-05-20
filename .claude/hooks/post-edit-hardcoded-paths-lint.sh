#!/usr/bin/env bash
# Project-level PostToolUse hook for clone-wars.
# Fires after Edit/Write of files under commands/, bin/, lib/, hooks/,
# config/, or .claude-plugin/. Runs tests/test_no_hardcoded_paths.sh and
# surfaces output if it failed.
#
# Advisory only — never blocks. Caught the v0.43.0 and near-missed in
# v0.44.0 incidents where absolute /home/liupan/... paths slipped into
# directive bash blocks.
set -uo pipefail

# shellcheck source=.claude/hooks/_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
REPO_ROOT=$(cw_hook_repo_root)
file_path=$(cw_hook_file_path_from_stdin)

[[ -n "$file_path" ]] || exit 0

# Normalize absolute path under repo to relative.
case "$file_path" in
  "$REPO_ROOT"/*) rel_path="${file_path#"$REPO_ROOT/"}" ;;
  *)              rel_path="$file_path" ;;
esac

# Only fire for paths the lint actually scans.
case "$rel_path" in
  commands/*|bin/*|lib/*|hooks/*|config/*|.claude-plugin/*) ;;
  *) exit 0 ;;
esac

lint="$REPO_ROOT/tests/test_no_hardcoded_paths.sh"
[[ -f "$lint" ]] || exit 0

if ! out=$(cd "$REPO_ROOT" && bash "$lint" 2>&1); then
  echo "[hook] post-edit hardcoded-paths lint failed after editing $rel_path:" >&2
  printf '%s\n' "$out" >&2
fi

exit 0
