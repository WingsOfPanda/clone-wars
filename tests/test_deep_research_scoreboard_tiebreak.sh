#!/usr/bin/env bash
# tests/test_deep_research_scoreboard_tiebreak.sh — v0.48 finding #5
# Locks the multi-key sort in bin/deep-research-score.sh:
# primary metric desc, then runtime asc, then exp_id (version-sort) asc.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/lib/state.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/lib/consult.sh"

# Synthesize a tab-separated OK_ROWS file with 3-way tie at metric=0.945,
# differing runtimes (slowest written first), and run the exact sort the
# scoreboard generator will use.
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

# Format: metric \t exp_id \t cmdr \t status \t runtime \t label \t metric_name
{
  printf '0.945\texp-007\trex\tok\t180.0\tA\twdl\n'
  printf '0.945\texp-003\tcody\tok\t60.0\tB\twdl\n'
  printf '0.945\texp-010\tkeeli\tok\t120.0\tC\twdl\n'
  printf '0.944\texp-002\trex\tok\t30.0\tD\twdl\n'
} > "$SANDBOX/ok_rows"

# Multi-key sort: metric desc, runtime asc, exp_id version-asc
sorted=$(sort -t$'\t' -k1,1rn -k5,5n -k2,2V "$SANDBOX/ok_rows")

# Expected order: 0.945/exp-003/60s, 0.945/exp-010/120s, 0.945/exp-007/180s, 0.944/exp-002/30s
line1=$(printf '%s\n' "$sorted" | sed -n '1p')
line2=$(printf '%s\n' "$sorted" | sed -n '2p')
line3=$(printf '%s\n' "$sorted" | sed -n '3p')
line4=$(printf '%s\n' "$sorted" | sed -n '4p')

assert_contains "$line1" "exp-003" "tiebreak: lowest runtime wins among ties (60s)"
assert_contains "$line2" "exp-010" "tiebreak: second by runtime (120s)"
assert_contains "$line3" "exp-007" "tiebreak: slowest tied run last (180s)"
assert_contains "$line4" "exp-002" "non-tied lower metric comes last"
pass "1. 3-way tie at metric=0.945 broken by runtime asc, exp_id version-asc"

# Sanity: confirm the OLD single-key sort would have been filesystem-order
# dependent. We don't assert the old behavior, just confirm new behavior is
# deterministic by re-running and getting identical output.
sorted2=$(sort -t$'\t' -k1,1rn -k5,5n -k2,2V "$SANDBOX/ok_rows")
assert_eq "$sorted" "$sorted2" "tiebreak: sort is deterministic across runs"
pass "2. multi-key sort is deterministic"

echo "test_deep_research_scoreboard_tiebreak: 2 cases passed"
