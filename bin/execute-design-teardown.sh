#!/usr/bin/env bash
# bin/execute-design-teardown.sh — kill cody pane via shared teardown.
# Usage: bin/execute-design-teardown.sh <topic>

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/execute_design.sh"

[[ $# -eq 1 ]] || { echo "Usage: $0 <topic>" >&2; exit 2; }
TOPIC="$1"
cw_execute_design_assert_topic "$TOPIC"

"$PLUGIN_ROOT/bin/teardown.sh" "$TOPIC"
