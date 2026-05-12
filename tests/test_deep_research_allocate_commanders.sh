#!/usr/bin/env bash
# tests/test_deep_research_allocate_commanders.sh — codex-eligible commander rotation
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"

# Round 1, K=4 → 4 commanders, starts with rex
r1=$(cw_deep_research_allocate_commanders 1 4)
lines=$(echo "$r1" | wc -l | tr -d ' ')
[[ "$lines" == "4" ]] || { echo "FAIL: K=4 round 1 expected 4 lines, got $lines" >&2; exit 1; }
pass "round 1 K=4 returns 4 names"

# Unique within the round
uniq_count=$(echo "$r1" | sort -u | wc -l | tr -d ' ')
[[ "$uniq_count" == "4" ]] || { echo "FAIL: duplicates in round 1" >&2; exit 1; }
pass "round 1 names are unique"

# First commander is rex (canonical codex commander)
first=$(echo "$r1" | head -1)
[[ "$first" == "rex" ]] || { echo "FAIL: round 1 first should be rex, got '$first'" >&2; exit 1; }
pass "round 1 starts with rex"

# Round 2 disjoint from round 1
r2=$(cw_deep_research_allocate_commanders 2 4)
overlap=$(comm -12 <(echo "$r1" | sort) <(echo "$r2" | sort) | wc -l | tr -d ' ')
[[ "$overlap" == "0" ]] || { echo "FAIL: r1 ∩ r2 overlap=$overlap" >&2; exit 1; }
pass "round 1 ∩ round 2 = ∅ (mod-rotation)"

# K too large for one round → error
if cw_deep_research_allocate_commanders 1 50 2>/dev/null; then
  echo "FAIL: K=50 should error" >&2; exit 1
fi
pass "K=50 errors as expected"

# round * K > pool size → error
if cw_deep_research_allocate_commanders 5 5 2>/dev/null; then
  echo "FAIL: 5×5=25 should error (pool=17)" >&2; exit 1
fi
pass "rounds × K exceeding pool errors"

# Determinism: same args → same output
r1b=$(cw_deep_research_allocate_commanders 1 4)
[[ "$r1" == "$r1b" ]] || { echo "FAIL: non-deterministic" >&2; exit 1; }
pass "allocation is deterministic"

# Bad input validation
if cw_deep_research_allocate_commanders 0 4 2>/dev/null; then
  echo "FAIL: round=0 should error" >&2; exit 1
fi
pass "round=0 errors"

if cw_deep_research_allocate_commanders 1 abc 2>/dev/null; then
  echo "FAIL: K=abc should error" >&2; exit 1
fi
pass "K=non-integer errors"

echo "test_deep_research_allocate_commanders: 9 assertions green"
