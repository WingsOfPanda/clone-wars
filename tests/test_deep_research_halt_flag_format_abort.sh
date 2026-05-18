#!/usr/bin/env bash
# tests/test_deep_research_halt_flag_format_abort.sh
# v0.43.0 Lane E: abort.sh writes halt.flag in structured key=value format.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
cd "$SANDBOX"
export CLONE_WARS_HOME="$SANDBOX/.clone-wars"

TOPIC=deep-research-halt-abort
TD="$(cw_topic_state_dir "$TOPIC")"
ART="$TD/_deep-research"
mkdir -p "$ART/troopers/rex"
echo "$TOPIC" > "$ART/topic.txt"
echo "rex" > "$ART/troopers.txt"
cat > "$ART/metric.md" <<'M'
# Research goal

**Primary metric:** test_metric
**Direction:** maximize
M
cw_deep_research_trooper_state_write "$ART" rex phase=idle exp_counter=2 last_event=scored
date -u +%Y-%m-%dT%H:%M:%SZ > "$ART/session-start.txt"

"$PLUGIN_ROOT/bin/deep-research-abort.sh" "$TOPIC" "ctrl-c by user" || true

# The flag may have been moved into archive by abort.sh's chained teardown;
# locate it under archive/ if not at original path.
HALT=""
[[ -f "$ART/halt.flag" ]] && HALT="$ART/halt.flag"
if [[ -z "$HALT" ]]; then
  HALT=$(find "$SANDBOX/.clone-wars/archive" -name halt.flag -type f 2>/dev/null | head -1)
fi
[[ -n "$HALT" && -f "$HALT" ]] || { echo "FAIL: halt.flag not found anywhere" >&2; exit 1; }

BODY=$(cat "$HALT")
echo "$BODY" | grep -qE '^halted_by=user$'  || { echo "FAIL: halted_by=user missing" >&2; echo "$BODY" >&2; exit 1; }
echo "$BODY" | grep -qE '^halted_at=20[0-9]{2}-' || { echo "FAIL: halted_at missing/malformed" >&2; echo "$BODY" >&2; exit 1; }
echo "$BODY" | grep -qE '^reason=ctrl-c by user$' || { echo "FAIL: reason mismatch" >&2; echo "$BODY" >&2; exit 1; }
pass "1. abort.sh halt.flag has halted_by + halted_at + reason keys"

echo "test_deep_research_halt_flag_format_abort: 1 case passed"
