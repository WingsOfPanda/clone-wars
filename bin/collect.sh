#!/usr/bin/env bash
# bin/collect.sh — STUB for v0.0.1-pre1.
set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
cat <<EOF
/clone-wars:collect — args received: $*

This command is a stub in v0.0.1-pre1. The runtime (tail outbox.jsonl until
{event:done|error}, print summary) lands in v0.0.1 after the tracer-bullet
validates the IPC mechanics. See docs/DESIGN.md §/clone-wars-collect.
EOF
log_warn "collect is a stub in v0.0.1-pre1"
exit 0
