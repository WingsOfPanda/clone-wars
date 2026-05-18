#!/usr/bin/env bash
# tests/test_deep_research_lane_abandon_helper.sh
# v0.43.0 Lane D: cw_deep_research_lane_abandon atomically updates state.txt
# with phase=abandoned + reason + timestamp.
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
ART="$SANDBOX/_deep-research"
mkdir -p "$ART/troopers/rex"
cw_deep_research_trooper_state_write "$ART" rex \
  exp_counter=6 phase=idle current_exp_id= last_event=scored

cw_deep_research_lane_abandon "$ART" rex "encoder lane retired after 3 sub-floor runs"

phase=$(cw_deep_research_trooper_state_field "$ART" rex phase)
reason=$(cw_deep_research_trooper_state_field "$ART" rex lane_abandon_reason)
ts=$(cw_deep_research_trooper_state_field "$ART" rex lane_abandon_ts)
exp_counter=$(cw_deep_research_trooper_state_field "$ART" rex exp_counter)

assert_eq "$phase" "abandoned" "phase=abandoned set"
assert_eq "$reason" "encoder lane retired after 3 sub-floor runs" "reason recorded verbatim"
[[ -n "$ts" ]] || { echo "FAIL: lane_abandon_ts empty" >&2; exit 1; }
[[ "$ts" =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}T ]] \
  || { echo "FAIL: lane_abandon_ts not ISO-8601: '$ts'" >&2; exit 1; }
assert_eq "$exp_counter" "6" "other keys preserved (exp_counter)"
pass "1. lane_abandon sets phase + reason + ts; preserves untouched keys"

# Bad-args path
set +e
out=$(cw_deep_research_lane_abandon "$ART" 2>&1); rc=$?
set -e
[[ "$rc" -ne 0 ]] || { echo "FAIL: missing args should non-zero" >&2; exit 1; }
pass "2. lane_abandon rejects missing args"

echo "test_deep_research_lane_abandon_helper: 2 cases passed"
