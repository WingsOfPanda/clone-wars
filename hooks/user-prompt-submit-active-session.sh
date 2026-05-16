#!/usr/bin/env bash
# hooks/user-prompt-submit-active-session.sh
# v0.40.0: filters by session id read from stdin JSON. Only emits the
# resume directive for active-<own-session-id>.txt — markers from other
# Claude Code sessions running in the same repo are invisible.
#
# Returns silently on:
#   - no stdin / no .session_id field
#   - tampered session id (regex mismatch)
#   - no matching active-<sid>.txt for this session
#   - no .clone-wars/state/ dir at $PWD
set -uo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=../lib/state.sh
source "$PLUGIN_ROOT/lib/state.sh" 2>/dev/null || exit 0

# Read stdin once. Claude Code passes the hook payload as single-line JSON
# (per CC hooks contract), so a non-greedy sed match works as a jq fallback.
PAYLOAD=$(cat 2>/dev/null || true)

SESSION_ID=""
if command -v jq >/dev/null 2>&1; then
  SESSION_ID=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // empty' 2>/dev/null)
fi
if [[ -z "$SESSION_ID" ]]; then
  SESSION_ID=$(printf '%s' "$PAYLOAD" \
    | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -1)
fi
# Last-resort fallback: env var (used by tests that don't pipe JSON).
[[ -n "$SESSION_ID" ]] || SESSION_ID="${CLAUDE_CODE_SESSION_ID:-}"
[[ -n "$SESSION_ID" ]] || exit 0

# Defense in depth: session_id must be uuid-shaped (alphanumerics +
# hyphens). Anything else means a tampered payload — silently no-op
# rather than expanding attacker-controlled content into a find command.
[[ "$SESSION_ID" =~ ^[0-9a-zA-Z-]+$ ]] || exit 0

STATE_ROOT="$PWD/.clone-wars/state"
[[ -d "$STATE_ROOT" ]] || exit 0

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
done < <(find "$STATE_ROOT" -maxdepth 4 -name "active-${SESSION_ID}.txt" -path '*/_deep-research/*' 2>/dev/null)

exit 0
