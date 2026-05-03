#!/usr/bin/env bash
# bin/deploy-teardown.sh — kill cody pane via shared teardown.
# Usage: bin/deploy-teardown.sh <topic>

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/deploy.sh"

[[ $# -eq 1 ]] || { echo "Usage: $0 <topic>" >&2; exit 2; }
TOPIC="$1"
cw_deploy_assert_topic "$TOPIC"

"$PLUGIN_ROOT/bin/teardown.sh" "$TOPIC"
