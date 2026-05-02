#!/usr/bin/env bash
# bin/consult-teardown.sh — kill consult panes + archive trooper state.
# Thin wrapper around bin/teardown.sh with topic validation.
#
# Usage: bin/consult-teardown.sh <consult-topic>

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/consult.sh"

[[ $# -eq 1 ]] || { echo "Usage: $0 <consult-topic>" >&2; exit 2; }
TOPIC="$1"
cw_consult_assert_topic "$TOPIC"

"$PLUGIN_ROOT/bin/teardown.sh" "$TOPIC"
