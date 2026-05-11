#!/usr/bin/env bash
# bin/consult-verify-wait.sh — per-commander verify-phase wait.
# Master Yoda invokes N× in parallel. Thin shim around cw_consult_wait
# in lib/consult-wait.sh. Honors VS=skipped short-circuit.
#
# Usage: bin/consult-verify-wait.sh <consult-topic> <commander> <model>

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/contracts.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/consult-wait.sh"

[[ $# -eq 3 ]] || { echo "Usage: $0 <consult-topic> <commander> <model>" >&2; exit 2; }
cw_consult_wait verify "$1" "$2" "$3"
