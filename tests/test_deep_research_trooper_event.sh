#!/usr/bin/env bash
# tests/test_deep_research_trooper_event.sh — v0.46.0 finding #9
# Locks: cw_deep_research_trooper_event(art_dir, commander, event_verb, [k=v...])
# is a thin wrapper over cw_deep_research_trooper_state_write that stamps
# last_event_ts (UTC ISO-8601) + last_event=<verb>, then forwards extra k=v.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
ART="$SANDBOX/_deep-research"
mkdir -p "$ART/troopers/rex"

# Case 1: bare verb stamps last_event + last_event_ts
cw_deep_research_trooper_event "$ART" rex spawn
got_event=$(cw_deep_research_trooper_state_field "$ART" rex last_event)
got_ts=$(cw_deep_research_trooper_state_field "$ART" rex last_event_ts)
assert_eq "$got_event" "spawn" "bare verb sets last_event"
[[ "$got_ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
  || { echo "FAIL: last_event_ts not ISO-8601 UTC: '$got_ts'" >&2; exit 1; }
pass "1. bare verb stamps last_event + ISO-8601 last_event_ts"

# Case 2: verb + extra k=v forwarded verbatim
cw_deep_research_trooper_event "$ART" rex dispatched \
  phase=working \
  current_exp_id=exp-002
got_event=$(cw_deep_research_trooper_state_field "$ART" rex last_event)
got_phase=$(cw_deep_research_trooper_state_field "$ART" rex phase)
got_exp=$(cw_deep_research_trooper_state_field "$ART" rex current_exp_id)
assert_eq "$got_event" "dispatched" "last_event updated"
assert_eq "$got_phase" "working" "extra k=v phase forwarded"
assert_eq "$got_exp" "exp-002" "extra k=v current_exp_id forwarded"
pass "2. verb + extra k=v forwarded to state.txt"

# Case 3: missing args → rc=2 with stderr message
set +e
out=$(cw_deep_research_trooper_event "$ART" rex 2>&1)
rc=$?
set -e
assert_eq "$rc" "2" "missing event_verb → rc=2"
[[ "$out" == *"usage"* || "$out" == *"required"* ]] \
  || { echo "FAIL: stderr should mention 'usage' or 'required', got: '$out'" >&2; exit 1; }
pass "3. missing args → rc=2 with usage/required message"

echo "test_deep_research_trooper_event: 3 cases passed"
