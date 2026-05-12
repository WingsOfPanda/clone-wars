#!/usr/bin/env bash
# tests/test_deep_research_pick_roster.sh — N=2 / N=3 deterministic roster.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"

# N=2 → rex, keeli in order
got=$(cw_deep_research_pick_roster 2 | tr '\n' ' ')
[[ "$got" == "rex keeli " ]] \
  || { echo "FAIL: N=2 expected 'rex keeli ', got '$got'" >&2; exit 1; }
pass "N=2 returns rex, keeli"

# N=3 → rex, keeli, colt in order
got=$(cw_deep_research_pick_roster 3 | tr '\n' ' ')
[[ "$got" == "rex keeli colt " ]] \
  || { echo "FAIL: N=3 expected 'rex keeli colt ', got '$got'" >&2; exit 1; }
pass "N=3 returns rex, keeli, colt"

# Deterministic — re-run returns same
got1=$(cw_deep_research_pick_roster 3 | tr '\n' ' ')
got2=$(cw_deep_research_pick_roster 3 | tr '\n' ' ')
[[ "$got1" == "$got2" ]] || { echo "FAIL: not deterministic" >&2; exit 1; }
pass "deterministic across calls"

# N=1 rejected
if cw_deep_research_pick_roster 1 2>/dev/null; then
  echo "FAIL: N=1 should be rejected" >&2; exit 1
fi
pass "N=1 rejected (rc!=0)"

# N=4 rejected
if cw_deep_research_pick_roster 4 2>/dev/null; then
  echo "FAIL: N=4 should be rejected" >&2; exit 1
fi
pass "N=4 rejected (rc!=0)"

# Non-numeric rejected
if cw_deep_research_pick_roster abc 2>/dev/null; then
  echo "FAIL: non-numeric should be rejected" >&2; exit 1
fi
pass "non-numeric rejected"

# Missing arg rejected
if cw_deep_research_pick_roster 2>/dev/null; then
  echo "FAIL: missing arg should be rejected" >&2; exit 1
fi
pass "missing arg rejected"

echo "test_deep_research_pick_roster: 7 assertions green"
