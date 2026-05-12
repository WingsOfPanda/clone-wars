#!/usr/bin/env bash
# tests/test_deep_research_compute_timeout.sh — ceiling-divide budget helper
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"

# total=3600, rounds=3, K=4 → ceil(3600/12) = 300
result=$(cw_deep_research_compute_per_branch_timeout 3600 3 4)
[[ "$result" == "300" ]] || { echo "FAIL: 3600/3/4 expected 300, got $result" >&2; exit 1; }
pass "3600/3/4 → 300"

# total=3600, rounds=2, K=3 → ceil(3600/6) = 600
result=$(cw_deep_research_compute_per_branch_timeout 3600 2 3)
[[ "$result" == "600" ]] || { echo "FAIL: 3600/2/3 expected 600, got $result" >&2; exit 1; }
pass "3600/2/3 → 600"

# total=1000, rounds=3, K=3 → ceil(1000/9) = 112
result=$(cw_deep_research_compute_per_branch_timeout 1000 3 3)
[[ "$result" == "112" ]] || { echo "FAIL: 1000/3/3 expected 112, got $result" >&2; exit 1; }
pass "1000/3/3 → 112 (ceiling division)"

# Guard: K=0 → rc=2
if cw_deep_research_compute_per_branch_timeout 1000 3 0 2>/dev/null; then
  echo "FAIL: K=0 should error" >&2; exit 1
fi
pass "K=0 errors as expected"

# Guard: rounds=0 → rc=2
if cw_deep_research_compute_per_branch_timeout 1000 0 3 2>/dev/null; then
  echo "FAIL: rounds=0 should error" >&2; exit 1
fi
pass "rounds=0 errors as expected"

# Guard: non-integer → rc=2
if cw_deep_research_compute_per_branch_timeout 1000 3 abc 2>/dev/null; then
  echo "FAIL: non-integer should error" >&2; exit 1
fi
pass "non-integer K errors as expected"

echo "test_deep_research_compute_timeout: 6 assertions green"
