#!/usr/bin/env bash
# bin/deep-research-experiment-wait.sh — thin shim over cw_consult_wait experiment.
#
# Usage: bin/deep-research-experiment-wait.sh <topic> <commander> <model>
#
# Per-trooper wait. Yoda's directive calls this N times in parallel (one per
# commander in the current round). Mirrors bin/meditate-adversary-wait.sh's
# shape; sources the same libs and dispatches to cw_consult_wait kind=experiment.
# State file expected at $art_dir/experiment-$commander.txt (written by
# bin/deep-research-experiment-send.sh).

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/contracts.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/consult-wait.sh"
[[ $# -eq 3 ]] || { echo "Usage: $0 <topic> <commander> <model>" >&2; exit 2; }
cw_consult_wait experiment "$@"
