#!/usr/bin/env bash
# hooks/user-prompt-submit-active-session.sh — v0.28.0 (project-local in v0.31.0)
# Fires on every UserPromptSubmit. If any deep-research session has an
# active.txt under the current project's `.clone-wars/state/` dir,
# emit a compact context block telling Yoda to run handler 3.b.
# Otherwise exit silently.
set -uo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=../lib/state.sh
source "$PLUGIN_ROOT/lib/state.sh" 2>/dev/null || exit 0

# v0.31.0: scan project-local state, not the global root. The hook fires
# only on active.txt files within the current Claude Code session's
# project (.clone-wars/ in $PWD). Cross-session bleed (a deep-research
# session in project A firing reminders in project B) is fixed at the
# scope-of-scan layer. The hook uses $PWD directly rather than
# cw_state_root so it doesn't inherit the test/debug env-var seam —
# production semantics are unconditional.
STATE_ROOT="$PWD/.clone-wars/state"
[[ -d "$STATE_ROOT" ]] || exit 0

# Scan for any topic with active.txt under _deep-research/.
# Stop at the first match (only one active session expected; if multiple,
# Yoda will surface the collision at the next handler 3.a entry check).
while IFS= read -r active_file; do
  [[ -f "$active_file" ]] || continue
  art_dir=$(dirname "$active_file")
  topic_slug=$(tr -d '\n' < "$active_file" 2>/dev/null)
  [[ -n "$topic_slug" ]] || continue

  cat <<EOF
[clone-wars:deep-research active session — topic: $topic_slug]
You are mid-session as the research advisor. Before responding to the
user message, read $PLUGIN_ROOT/commands/deep-research-resume.md and
follow handler 3.b's steps. Skip handler 4.a (initial entry already
ran in a prior turn).
Active state: $art_dir/
EOF
  exit 0
done < <(find "$STATE_ROOT" -maxdepth 4 -name 'active.txt' -path '*/_deep-research/*' 2>/dev/null)

exit 0
