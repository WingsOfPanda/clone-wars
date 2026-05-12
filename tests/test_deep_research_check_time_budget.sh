#!/usr/bin/env bash
# tests/test_deep_research_check_time_budget.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Case 1: budget=none → never fires
echo "none" > "$TMP/budget1.txt"
date -u +%Y-%m-%dT%H:%M:%SZ > "$TMP/start1.txt"
if cw_deep_research_check_time_budget "$TMP/budget1.txt" "$TMP/start1.txt"; then
  echo "FAIL: 'none' budget fired" >&2; exit 1
fi
pass "budget='none' never fires"

# Case 2: budget=10s, session started 5s ago → does not fire
echo "10" > "$TMP/budget2.txt"
five_ago=$(date -u -d '5 seconds ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -v-5S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
echo "$five_ago" > "$TMP/start2.txt"
if cw_deep_research_check_time_budget "$TMP/budget2.txt" "$TMP/start2.txt"; then
  echo "FAIL: fired before budget" >&2; exit 1
fi
pass "elapsed < budget — does not fire"

# Case 3: budget=10s, session started 60s ago → fires
echo "10" > "$TMP/budget3.txt"
sixty_ago=$(date -u -d '60 seconds ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -v-60S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
echo "$sixty_ago" > "$TMP/start3.txt"
if ! cw_deep_research_check_time_budget "$TMP/budget3.txt" "$TMP/start3.txt"; then
  echo "FAIL: did not fire when over budget" >&2; exit 1
fi
pass "elapsed >= budget — fires"

# Case 4: missing budget file → rc=2 (error)
if cw_deep_research_check_time_budget "$TMP/missing-budget.txt" "$TMP/start3.txt" 2>/dev/null; then
  echo "FAIL: rc=0 on missing budget" >&2; exit 1
fi
pass "missing budget file — rc!=0"

# Case 5: missing session-start file → rc=2 (error)
if cw_deep_research_check_time_budget "$TMP/budget3.txt" "$TMP/missing-start.txt" 2>/dev/null; then
  echo "FAIL: rc=0 on missing session-start" >&2; exit 1
fi
pass "missing session-start file — rc!=0"

# Case 6: malformed budget content rejected
echo "abc" > "$TMP/bad-budget.txt"
if cw_deep_research_check_time_budget "$TMP/bad-budget.txt" "$TMP/start3.txt" 2>/dev/null; then
  echo "FAIL: rc=0 on malformed budget" >&2; exit 1
fi
pass "malformed budget rejected"

echo "test_deep_research_check_time_budget: 6 assertions green"
