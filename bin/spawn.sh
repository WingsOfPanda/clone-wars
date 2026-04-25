#!/usr/bin/env bash
# bin/spawn.sh — STUB for v0.0.1-pre1.
# Real implementation lands in v0.0.1 after the tracer-bullet validates tmux/IPC mechanics.
# This stub exists so the marketplace shell is complete (Phase 1 of the marketplace-prep spec).
set -uo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"

cat <<EOF
/clone-wars:spawn — args received: $*

This command is a stub in v0.0.1-pre1. The runtime (tmux split-window, send-keys
identity injection, outbox polling for the "ready" event) lands in v0.0.1 after
the tracer-bullet validates the underlying mechanics on this machine.

In the meantime:
  - Run /clone-wars:medic to verify your environment.
  - Read docs/DESIGN.md §Slash commands for the spec of how this will behave.
  - Track progress in CLAUDE.md status checklist.
EOF

log_warn "spawn is a stub in v0.0.1-pre1; nothing was launched"
exit 0
