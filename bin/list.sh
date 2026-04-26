#!/usr/bin/env bash
# bin/list.sh — STUB for v0.0.1-pre1.
set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
cat <<EOF
/clone-wars:list — args received: $*

This command is a stub in v0.0.1-pre1. The runtime (read pane.json from each
trooper state dir, cross-check tmux list-panes, render a status table) lands in
v0.0.1 after the tracer-bullet validates the IPC mechanics. See docs/DESIGN.md
§/clone-wars-list.
EOF
log_warn "list is a stub in v0.0.1-pre1"
exit 0
