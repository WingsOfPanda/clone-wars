#!/usr/bin/env bash
# tests/test_deep_research_check_stagnation.sh — 5-exp <1% stagnation logic
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Helper to write a scoreboard. Rows go in (exp-id, metric, status) tuples
# in chronological order (we write them that way; helper re-sorts internally
# based on exp-NNN).
write_sb() {
  local path="$1"; shift
  printf '# Scoreboard\n\n| Rank | Experiment | Metric | Status |\n|---|---|---|---|\n' > "$path"
  local rank=1
  for row in "$@"; do
    IFS=: read -r e m s <<<"$row"
    printf '| %d | %s | %s | %s |\n' "$rank" "$e" "$m" "$s" >> "$path"
    rank=$((rank + 1))
  done
}

# Case 1: only 4 experiments → floor, rc!=0
SB="$TMP/sb1.md"
write_sb "$SB" "exp-001:0.99:ok" "exp-002:0.989:ok" "exp-003:0.988:ok" "exp-004:0.99:ok"
echo 0 > "$TMP/cursor1.txt"
if cw_deep_research_check_stagnation "$SB" "$TMP/cursor1.txt"; then
  echo "FAIL: rc=0 on only 4 exps (floor violated)" >&2; exit 1
fi
pass "floor at exp<5 — does not fire"

# Case 2: 5 stagnant experiments → rc=0 (fires)
SB="$TMP/sb2.md"
write_sb "$SB" "exp-001:0.99:ok" "exp-002:0.989:ok" "exp-003:0.991:ok" \
               "exp-004:0.988:ok" "exp-005:0.990:ok"
echo 0 > "$TMP/cursor2.txt"
if ! cw_deep_research_check_stagnation "$SB" "$TMP/cursor2.txt"; then
  echo "FAIL: rc!=0 on 5 stagnant exps" >&2; exit 1
fi
pass "5 stagnant exps — fires"

# Case 3: 5 exps where last exp is a >2% improvement → rc!=0
SB="$TMP/sb3.md"
write_sb "$SB" "exp-001:0.95:ok" "exp-002:0.94:ok" "exp-003:0.949:ok" \
               "exp-004:0.93:ok" "exp-005:0.97:ok"
echo 0 > "$TMP/cursor3.txt"
if cw_deep_research_check_stagnation "$SB" "$TMP/cursor3.txt"; then
  echo "FAIL: rc=0 even though recent >1% improvement" >&2; exit 1
fi
pass "recent >1% improvement — does not fire"

# Case 4: cursor=2, only 4 post-cursor exps → floor → rc!=0
SB="$TMP/sb4.md"
write_sb "$SB" "exp-001:0.99:ok" "exp-002:0.98:ok" "exp-003:0.99:ok" \
               "exp-004:0.98:ok" "exp-005:0.99:ok" "exp-006:0.98:ok"
echo 2 > "$TMP/cursor4.txt"
if cw_deep_research_check_stagnation "$SB" "$TMP/cursor4.txt"; then
  echo "FAIL: rc=0 even with cursor=2 leaving only 4 post-cursor exps" >&2; exit 1
fi
pass "cursor=2 reduces window below floor — does not fire"

# Case 5: cursor=2, 5 stagnant post-cursor exps → rc=0
SB="$TMP/sb5.md"
write_sb "$SB" "exp-001:0.99:ok" "exp-002:0.98:ok" "exp-003:0.99:ok" \
               "exp-004:0.989:ok" "exp-005:0.991:ok" "exp-006:0.989:ok" \
               "exp-007:0.99:ok"
echo 2 > "$TMP/cursor5.txt"
if ! cw_deep_research_check_stagnation "$SB" "$TMP/cursor5.txt"; then
  echo "FAIL: rc!=0 with 5 stagnant post-cursor exps" >&2; exit 1
fi
pass "cursor=2 + 5 stagnant post-cursor — fires"

# Case 6: missing cursor file → treat as cursor=0
SB="$TMP/sb6.md"
write_sb "$SB" "exp-001:0.99:ok" "exp-002:0.989:ok" "exp-003:0.991:ok" \
               "exp-004:0.988:ok" "exp-005:0.990:ok"
if ! cw_deep_research_check_stagnation "$SB" "$TMP/nope.txt"; then
  echo "FAIL: rc!=0 when cursor file missing" >&2; exit 1
fi
pass "missing cursor file — treated as 0"

echo "test_deep_research_check_stagnation: 6 assertions green"
