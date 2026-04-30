#!/usr/bin/env bash
# tests/test_consult_flag_parse.sh — v0.4.2 token-based --design-doc parsing.
#
# Contract: cw_consult_parse_design_doc_flag <args> → echoes "<flag>\t<topic>"
# where <flag> ∈ {0,1} and <topic> is the input with all exact --design-doc
# tokens removed and surrounding whitespace collapsed.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/consult.sh

parse() {
  local raw="$1" out flag topic
  out=$(cw_consult_parse_design_doc_flag "$raw")
  flag="${out%%	*}"
  topic="${out#*	}"
  printf '%s\n' "FLAG=$flag"
  printf '%s\n' "TOPIC=$topic"
}

# Case 1: leading flag.
mapfile -t L < <(parse "--design-doc decide foo")
[[ "${L[0]}" == "FLAG=1" ]]                  || { echo "FAIL c1 flag: ${L[0]}"; exit 1; }
[[ "${L[1]}" == "TOPIC=decide foo" ]]        || { echo "FAIL c1 topic: ${L[1]}"; exit 1; }
pass "leading --design-doc → flag set, topic stripped"

# Case 2: --design-documentation must NOT match.
mapfile -t L < <(parse "--design-documentation foo")
[[ "${L[0]}" == "FLAG=0" ]]                            || { echo "FAIL c2 flag: ${L[0]}"; exit 1; }
[[ "${L[1]}" == "TOPIC=--design-documentation foo" ]]  || { echo "FAIL c2 topic: ${L[1]}"; exit 1; }
pass "--design-documentation does not match"

# Case 3: flag mid-string.
mapfile -t L < <(parse "decide --design-doc foo")
[[ "${L[0]}" == "FLAG=1" ]]                  || { echo "FAIL c3 flag: ${L[0]}"; exit 1; }
[[ "${L[1]}" == "TOPIC=decide foo" ]]        || { echo "FAIL c3 topic: ${L[1]}"; exit 1; }
pass "mid-string --design-doc"

# Case 4: --design-doc-please must NOT match.
mapfile -t L < <(parse "please --design-doc-please foo")
[[ "${L[0]}" == "FLAG=0" ]]                                  || { echo "FAIL c4 flag: ${L[0]}"; exit 1; }
[[ "${L[1]}" == "TOPIC=please --design-doc-please foo" ]]    || { echo "FAIL c4 topic: ${L[1]}"; exit 1; }
pass "--design-doc-please does not match"

# Case 5: multiple flags collapse.
mapfile -t L < <(parse "--design-doc --design-doc bar")
[[ "${L[0]}" == "FLAG=1" ]]                  || { echo "FAIL c5 flag: ${L[0]}"; exit 1; }
[[ "${L[1]}" == "TOPIC=bar" ]]               || { echo "FAIL c5 topic: ${L[1]}"; exit 1; }
pass "multiple --design-doc tokens collapse"

# Case 6: empty input.
mapfile -t L < <(parse "")
[[ "${L[0]}" == "FLAG=0" ]]                  || { echo "FAIL c6 flag: ${L[0]}"; exit 1; }
[[ "${L[1]}" == "TOPIC=" ]]                  || { echo "FAIL c6 topic: ${L[1]}"; exit 1; }
pass "empty input"

# Case 7: flag with trailing-only content.
mapfile -t L < <(parse "topic --design-doc")
[[ "${L[0]}" == "FLAG=1" ]]                  || { echo "FAIL c7 flag: ${L[0]}"; exit 1; }
[[ "${L[1]}" == "TOPIC=topic" ]]             || { echo "FAIL c7 topic: ${L[1]}"; exit 1; }
pass "trailing flag"
