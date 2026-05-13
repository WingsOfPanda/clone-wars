#!/usr/bin/env bash
# tests/test_deep_research_check_completion.sh — v0.28.0 completion signal block
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Helper to build scoreboard.md in production schema (bin/deep-research-score.sh:77).
# Args: <out-path> <exp-id> <commander> <metric> <status> [<exp-id> <cmdr> <metric> <status>...]
build_sb() {
  local out="$1"; shift
  cat > "$out" <<'EOF'
# Scoreboard

| Rank | Experiment | Commander | Metric | Status | Runtime | Approach |
|---|---|---|---|---|---|---|
EOF
  local rank=1
  while (( $# >= 4 )); do
    printf '| %d | %s | %s | %s | %s | 100 | approach |\n' "$rank" "$1" "$2" "$3" "$4" >> "$out"
    shift 4
    rank=$((rank + 1))
  done
}

build_metric() {
  local out="$1" min="$2" tgt="$3" K="$4"
  cat > "$out" <<EOF
**Primary metric:** accuracy
**Direction:** maximize
**min_acceptable:** $min
**target:** $tgt
**K_corroboration:** $K
**plateau_window:** 5
**plateau_threshold:** 0.01
EOF
}

# Case A: floor met, target met, K=1 satisfied
build_sb "$TMP/sb.md" exp-001 rex 0.95 ok exp-002 rex 0.991 ok
build_metric "$TMP/m.md" ">= 0.90" ">= 0.99" 1
OUT=$(cw_deep_research_check_completion "$TMP/sb.md" "$TMP/m.md")
assert_contains "$OUT" "floor_met=yes" "floor met"
assert_contains "$OUT" "target_met=yes" "target met"
assert_contains "$OUT" "K_so_far=1" "K count 1"
assert_contains "$OUT" "K_required=1" "K required 1"
assert_contains "$OUT" "plateau=no" "no plateau on 2 rows"
pass "case A — floor + target + K=1 all met"

# Case B: floor met, target NOT met
build_sb "$TMP/sb.md" exp-001 rex 0.92 ok
build_metric "$TMP/m.md" ">= 0.90" ">= 0.99" 1
OUT=$(cw_deep_research_check_completion "$TMP/sb.md" "$TMP/m.md")
assert_contains "$OUT" "floor_met=yes" "floor met"
assert_contains "$OUT" "target_met=no" "target not met"
assert_contains "$OUT" "K_so_far=0" "K count 0"
pass "case B — floor met, target not met"

# Case C: floor NOT met
build_sb "$TMP/sb.md" exp-001 rex 0.85 ok
build_metric "$TMP/m.md" ">= 0.90" ">= 0.99" 1
OUT=$(cw_deep_research_check_completion "$TMP/sb.md" "$TMP/m.md")
assert_contains "$OUT" "floor_met=no" "floor not met"
pass "case C — floor not met"

# Case D: K_corroboration=3, only 2 satisfy target
build_sb "$TMP/sb.md" exp-001 rex 0.99 ok exp-002 rex 0.991 ok exp-003 rex 0.985 ok
build_metric "$TMP/m.md" ">= 0.90" ">= 0.99" 3
OUT=$(cw_deep_research_check_completion "$TMP/sb.md" "$TMP/m.md")
assert_contains "$OUT" "K_so_far=2" "K count 2 of 3"
assert_contains "$OUT" "K_required=3" "K required 3"
pass "case D — K underfilled"

# Case E: plateau detected (5 consecutive low spread)
build_sb "$TMP/sb.md" \
  exp-001 rex 0.971 ok \
  exp-002 rex 0.972 ok \
  exp-003 rex 0.973 ok \
  exp-004 rex 0.971 ok \
  exp-005 rex 0.972 ok
build_metric "$TMP/m.md" ">= 0.90" ">= 0.99" 1
OUT=$(cw_deep_research_check_completion "$TMP/sb.md" "$TMP/m.md")
assert_contains "$OUT" "plateau=yes" "plateau detected"
pass "case E — plateau on 5-row spread"

# Case F: ignore status=fail rows in K count
build_sb "$TMP/sb.md" exp-001 rex 0.991 ok exp-002 rex null fail exp-003 rex 0.99 ok
build_metric "$TMP/m.md" ">= 0.90" ">= 0.99" 1
OUT=$(cw_deep_research_check_completion "$TMP/sb.md" "$TMP/m.md")
assert_contains "$OUT" "K_so_far=1" "K excludes failed rows"
pass "case F — failed rows excluded"

# Case G: direction=minimize (latency-style)
build_sb "$TMP/sb.md" exp-001 rex 50 ok exp-002 rex 45 ok
build_metric "$TMP/m.md" "<= 100" "<= 50" 1
OUT=$(cw_deep_research_check_completion "$TMP/sb.md" "$TMP/m.md")
# Note: direction=minimize is captured in metric.md; comparison operator is in min/target value
assert_contains "$OUT" "floor_met=yes" "minimize floor"
assert_contains "$OUT" "target_met=yes" "minimize target"
pass "case G — minimize direction"
