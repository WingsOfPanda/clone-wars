#!/usr/bin/env bash
# tests/test_deep_research_trooper_state_io.sh — v0.28.0 per-trooper state I/O
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
ART="$TMP/_deep-research"
mkdir -p "$ART/troopers/rex"

# Case A: write initial state
cw_deep_research_trooper_state_write "$ART" rex \
  exp_counter=0 phase=idle current_exp_id= last_event_ts=2026-05-13T08:00:00Z last_event=spawn probe_sent_ts=
[[ -f "$ART/troopers/rex/state.txt" ]] || { echo "FAIL: state.txt not created" >&2; exit 1; }
pass "write creates state.txt"

# Case B: read returns all KV pairs
OUT=$(cw_deep_research_trooper_state_read "$ART" rex)
assert_contains "$OUT" "exp_counter=0" "read returns exp_counter"
assert_contains "$OUT" "phase=idle" "read returns phase"
assert_contains "$OUT" "last_event=spawn" "read returns last_event"
pass "read returns KV pairs"

# Case C: partial update preserves other fields
cw_deep_research_trooper_state_write "$ART" rex phase=working exp_counter=1
OUT=$(cw_deep_research_trooper_state_read "$ART" rex)
assert_contains "$OUT" "phase=working" "partial update sets new value"
assert_contains "$OUT" "exp_counter=1" "partial update sets counter"
assert_contains "$OUT" "last_event=spawn" "partial update preserves other fields"
pass "partial update preserves untouched fields"

# Case D: atomic write (tmp+rename — no half-written file)
cw_deep_research_trooper_state_write "$ART" rex current_exp_id=exp-001
[[ -f "$ART/troopers/rex/state.txt.tmp" ]] && { echo "FAIL: tmp file left behind" >&2; exit 1; }
pass "atomic write removes tmp file"

# Case E: missing-art-dir errors with rc=2
rc=0; cw_deep_research_trooper_state_read "$TMP/does-not-exist" rex 2>/dev/null || rc=$?
[[ "$rc" == "2" ]] || { echo "FAIL: missing-dir should rc=2, got $rc" >&2; exit 1; }
pass "missing dir errors rc=2"

# Case F: missing-arg errors with rc=2
rc=0; cw_deep_research_trooper_state_write "$ART" 2>/dev/null || rc=$?
[[ "$rc" == "2" ]] || { echo "FAIL: missing commander arg should rc=2, got $rc" >&2; exit 1; }
pass "missing commander arg errors rc=2"
