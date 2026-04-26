#!/usr/bin/env bash
# bin/send.sh — STUB for v0.0.1-pre1.
set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
cat <<EOF
/clone-wars:send — args received: $*

This command is a stub in v0.0.1-pre1. The runtime (write inbox.md, append
END_OF_INSTRUCTION, nudge the pane via tmux send-keys) lands in v0.0.1 after the
tracer-bullet validates the IPC mechanics. See docs/DESIGN.md §/clone-wars-send.
EOF
log_warn "send is a stub in v0.0.1-pre1"
exit 0
