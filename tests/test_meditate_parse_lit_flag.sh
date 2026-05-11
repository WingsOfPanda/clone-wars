#!/usr/bin/env bash
# tests/test_meditate_parse_lit_flag.sh — --lit / --no-lit token-aware parsing
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/meditate.sh"

# --lit token strips and emits lit=force-on
out=$(cw_meditate_parse_lit_flag "--lit explore SOTA scheduling")
[[ "$out" == "force-on	explore SOTA scheduling" ]] \
  || { echo "FAIL: --lit case got '$out'" >&2; exit 1; }
pass "--lit case strips token, emits force-on"

# --no-lit token strips and emits force-off
out=$(cw_meditate_parse_lit_flag "explore --no-lit Postgres replication")
[[ "$out" == "force-off	explore Postgres replication" ]] \
  || { echo "FAIL: --no-lit case got '$out'" >&2; exit 1; }
pass "--no-lit case strips token, emits force-off"

# No flag → auto
out=$(cw_meditate_parse_lit_flag "explore SOTA scheduling")
[[ "$out" == "auto	explore SOTA scheduling" ]] \
  || { echo "FAIL: no-flag case got '$out'" >&2; exit 1; }
pass "no-flag case emits auto"

# Substring is NOT a match (--litmus shouldn't trigger --lit)
out=$(cw_meditate_parse_lit_flag "explore --litmus paper")
[[ "$out" == "auto	explore --litmus paper" ]] \
  || { echo "FAIL: substring '--litmus' incorrectly matched '--lit': got '$out'" >&2; exit 1; }
pass "--litmus does not match --lit (token-aware)"

# Both flags → last one wins (consistent with --use-force pattern)
out=$(cw_meditate_parse_lit_flag "--lit foo --no-lit bar")
[[ "$out" == "force-off	foo bar" ]] \
  || { echo "FAIL: --lit then --no-lit got '$out'; expected force-off" >&2; exit 1; }
pass "--lit + --no-lit: last wins (force-off)"

pass "flag parser correct across 5 cases"
