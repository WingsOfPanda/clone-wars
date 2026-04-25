#!/usr/bin/env bash
# bin/teardown.sh — STUB for v0.0.1-pre1.
set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
cat <<EOF
/clone-wars:teardown — args received: $*

This command is a stub in v0.0.1-pre1. The runtime (tmux kill-pane, mv state to
archive) lands in v0.0.1 after the tracer-bullet validates the IPC mechanics.
See docs/DESIGN.md §/clone-wars-teardown.
EOF
log_warn "teardown is a stub in v0.0.1-pre1"
exit 0
