#!/usr/bin/env bash
# tests/test_consult_use_force_flag_parse.sh — v0.16.0 token-based --use-force parsing.
#
# Contract: cw_consult_parse_use_force_flag <args> → echoes "<flag>\t<topic>"
# where <flag> ∈ {0,1} and <topic> is the input with all exact --use-force
# tokens removed and surrounding whitespace collapsed.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/consult.sh

parse() {
  local raw="$1" out flag topic
  out=$(cw_consult_parse_use_force_flag "$raw")
  flag="${out%%	*}"
  topic="${out#*	}"
  printf '%s\n' "FLAG=$flag"
  printf '%s\n' "TOPIC=$topic"
}

# Case 1: leading flag.
mapfile -t L < <(parse "--use-force decide foo")
[[ "${L[0]}" == "FLAG=1" ]]                  || { echo "FAIL c1 flag: ${L[0]}"; exit 1; }
[[ "${L[1]}" == "TOPIC=decide foo" ]]        || { echo "FAIL c1 topic: ${L[1]}"; exit 1; }
pass "leading --use-force → flag set, topic stripped"

# Case 2: --use-force-please must NOT match (substring of similar shape).
mapfile -t L < <(parse "--use-force-please foo")
[[ "${L[0]}" == "FLAG=0" ]]                            || { echo "FAIL c2 flag: ${L[0]}"; exit 1; }
[[ "${L[1]}" == "TOPIC=--use-force-please foo" ]]      || { echo "FAIL c2 topic: ${L[1]}"; exit 1; }
pass "--use-force-please does not match"

# Case 3: flag mid-string.
mapfile -t L < <(parse "decide --use-force foo")
[[ "${L[0]}" == "FLAG=1" ]]                  || { echo "FAIL c3 flag: ${L[0]}"; exit 1; }
[[ "${L[1]}" == "TOPIC=decide foo" ]]        || { echo "FAIL c3 topic: ${L[1]}"; exit 1; }
pass "mid-string --use-force"

# Case 4: --use-forced (different word) must NOT match.
mapfile -t L < <(parse "please --use-forced foo")
[[ "${L[0]}" == "FLAG=0" ]]                              || { echo "FAIL c4 flag: ${L[0]}"; exit 1; }
[[ "${L[1]}" == "TOPIC=please --use-forced foo" ]]       || { echo "FAIL c4 topic: ${L[1]}"; exit 1; }
pass "--use-forced does not match"

# Case 5: multiple flags collapse.
mapfile -t L < <(parse "--use-force --use-force bar")
[[ "${L[0]}" == "FLAG=1" ]]                  || { echo "FAIL c5 flag: ${L[0]}"; exit 1; }
[[ "${L[1]}" == "TOPIC=bar" ]]               || { echo "FAIL c5 topic: ${L[1]}"; exit 1; }
pass "multiple --use-force tokens collapse"

# Case 6: empty input.
mapfile -t L < <(parse "")
[[ "${L[0]}" == "FLAG=0" ]]                  || { echo "FAIL c6 flag: ${L[0]}"; exit 1; }
[[ "${L[1]}" == "TOPIC=" ]]                  || { echo "FAIL c6 topic: ${L[1]}"; exit 1; }
pass "empty input"

# Case 7: flag with trailing-only content.
mapfile -t L < <(parse "topic --use-force")
[[ "${L[0]}" == "FLAG=1" ]]                  || { echo "FAIL c7 flag: ${L[0]}"; exit 1; }
[[ "${L[1]}" == "TOPIC=topic" ]]             || { echo "FAIL c7 topic: ${L[1]}"; exit 1; }
pass "trailing flag"

# Case 8: --use-force coexisting with --design-doc — they must not interfere.
# (We only call cw_consult_parse_use_force_flag here; the directive layers both helpers.)
mapfile -t L < <(parse "--design-doc topic --use-force")
[[ "${L[0]}" == "FLAG=1" ]]                              || { echo "FAIL c8 flag: ${L[0]}"; exit 1; }
[[ "${L[1]}" == "TOPIC=--design-doc topic" ]]            || { echo "FAIL c8 topic: ${L[1]}"; exit 1; }
pass "--design-doc preserved when only --use-force is parsed"
