#!/usr/bin/env bash
# tests/test_deep_research_state_field_newline_escape.sh — v0.49 finding #9
# Locks the contract: state.txt writer escapes embedded \n in values; reader
# unescapes on extraction. Round-trip equality must hold for values containing
# both literal '\n' and '=' (e.g. lane_abandon_reason from Yoda's free-form
# directive prose).
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/lib/log.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/lib/state.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/lib/consult.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/lib/deep-research.sh"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/troopers/rex"

# Build a value with embedded newline + embedded '=' to mirror real
# lane_abandon_reason payloads. Use $'...' so the literal \n becomes a real
# newline byte in the variable.
REASON=$'last 3 experiments all below floor=0.88 (best=0.834);\nplateau_threshold breached vs leader rex/exp-005 metric=0.945'

# Write via the helper, including the multi-line REASON.
cw_deep_research_trooper_state_write "$SANDBOX" rex \
  phase=abandoned \
  lane_abandon_reason="$REASON" \
  lane_abandon_ts=2026-05-21T08:00:00Z

# Sanity: state.txt should be a single-line-per-key file (no raw newlines
# in the middle of a value record).
line_count=$(wc -l < "$SANDBOX/troopers/rex/state.txt")
[[ "$line_count" -eq 3 ]] \
  || { echo "FAIL: expected 3 lines (one per key), got $line_count" >&2; cat "$SANDBOX/troopers/rex/state.txt" >&2; exit 1; }
pass "writer keeps one record per key even when value contains \\n"

# Round-trip: reader must return the value with the real newline restored.
got=$(cw_deep_research_trooper_state_field "$SANDBOX" rex lane_abandon_reason)
assert_eq "$got" "$REASON" "lane_abandon_reason round-trips through writer + reader"
pass "round-trip equality with embedded newline + ="

# Sibling fields are untouched (no cross-key bleed)
got_phase=$(cw_deep_research_trooper_state_field "$SANDBOX" rex phase)
assert_eq "$got_phase" "abandoned" "phase preserved alongside multi-line value"
got_ts=$(cw_deep_research_trooper_state_field "$SANDBOX" rex lane_abandon_ts)
assert_eq "$got_ts" "2026-05-21T08:00:00Z" "lane_abandon_ts preserved alongside multi-line value"
pass "sibling fields untouched"

echo "test_deep_research_state_field_newline_escape: 3 cases passed"
