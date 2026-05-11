#!/usr/bin/env bash
# bin/consult-research-wait.sh — per-commander research-phase wait.
# Master Yoda invokes N× in parallel (one per trooper). Thin shim
# around cw_consult_wait in lib/consult-wait.sh.
#
# Usage: bin/consult-research-wait.sh <consult-topic> <commander> <model>

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/contracts.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/consult-wait.sh"

[[ $# -eq 3 ]] || { echo "Usage: $0 <consult-topic> <commander> <model>" >&2; exit 2; }
cw_consult_wait research "$1" "$2" "$3"
