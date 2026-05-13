#!/usr/bin/env bash
# tests/test_deep_research_check_completion_empty_scoreboard.sh — edge case
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
SB="$TMP/sb.md"
M="$TMP/m.md"
cat > "$SB" <<'EOF'
| Exp | Commander | Metric | Status | Runtime | Notes |
|---|---|---|---|---|---|
EOF
cat > "$M" <<'EOF'
**Primary metric:** accuracy
**Direction:** maximize
**min_acceptable:** >= 0.90
**target:** >= 0.99
**K_corroboration:** 1
**plateau_window:** 5
**plateau_threshold:** 0.01
EOF
OUT=$(cw_deep_research_check_completion "$SB" "$M")
assert_contains "$OUT" "floor_met=no" "empty floor=no"
assert_contains "$OUT" "target_met=no" "empty target=no"
assert_contains "$OUT" "K_so_far=0" "empty K=0"
assert_contains "$OUT" "plateau=no" "empty plateau=no"
pass "empty scoreboard returns all-no signals"

# Missing scoreboard.md errors rc=2
rc=0; cw_deep_research_check_completion "$TMP/missing.md" "$M" 2>/dev/null || rc=$?
[[ "$rc" == "2" ]] || { echo "FAIL: missing scoreboard should rc=2, got $rc" >&2; exit 1; }
pass "missing scoreboard rc=2"
