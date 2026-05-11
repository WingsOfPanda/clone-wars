#!/usr/bin/env bash
# bin/meditate-adversary-wait.sh — thin shim over cw_consult_wait adversary.
#
# Usage: bin/meditate-adversary-wait.sh <meditate-topic> <commander> <model>
#
# Mirror of bin/consult-verify-wait.sh structure (which is itself a thin
# shim over cw_consult_wait verify). Sources the same libs and dispatches
# to the same wait function with kind=adversary.

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/contracts.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/consult-wait.sh"
[[ $# -eq 3 ]] || { echo "Usage: $0 <topic> <commander> <model>" >&2; exit 2; }
cw_consult_wait adversary "$@"
