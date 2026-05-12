#!/usr/bin/env bash
# tests/test_deep_research_score_flat.sh — flat scoreboard contract
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
TMPHOME=$(mktemp -d); trap 'rm -rf "$TMPHOME"' EXIT
export CLONE_WARS_HOME="$TMPHOME"
echo "codex" > "$TMPHOME/providers-available.txt"

slug=$("$PLUGIN_ROOT/bin/deep-research-init.sh" "score test")
source "$PLUGIN_ROOT/lib/state.sh"
REPO_HASH=$(cw_repo_hash)
art_dir="$TMPHOME/state/$REPO_HASH/$slug/_deep-research"
mkdir -p "$art_dir/experiments"

write_exp() {
  local exp="$1" cmdr="$2" metric="$3" status="$4" label="$5"
  local d="$art_dir/experiments/$exp-$cmdr"
  mkdir -p "$d"
  echo "log" > "$d/stdout.log"
  echo "log" > "$d/stderr.log"
  if [[ "$status" == "ok" ]]; then
    cat > "$d/result.json" <<EOF
{"branch_id":"$exp","approach_label":"$label","metric_name":"accuracy",
 "metric_value":$metric,"status":"$status","runtime_s":30.0,
 "log_paths":["./stdout.log","./stderr.log"],"notes":"n/a"}
EOF
  else
    cat > "$d/result.json" <<EOF
{"branch_id":"$exp","approach_label":"$label","metric_name":"accuracy",
 "metric_value":null,"status":"$status","runtime_s":30.0,
 "log_paths":["./stdout.log","./stderr.log"],"notes":"failed"}
EOF
  fi
}

write_exp exp-001 rex 0.9894 ok "Modern LeNet"
write_exp exp-002 keeli 0.7916 ok "Depthwise CNN"
write_exp exp-003 rex 0.9903 ok "Modern LeNet + aug"
write_exp exp-004 keeli null fail "Bad config"

"$PLUGIN_ROOT/bin/deep-research-score.sh" "$slug" \
  || { echo "FAIL: score rc!=0" >&2; exit 1; }
pass "score rc=0"

sb="$art_dir/scoreboard.md"
assert_file_exists "$sb"
pass "scoreboard.md written at flat path"

exp003_pos=$(awk '/exp-003/ { print NR; exit }' "$sb")
exp001_pos=$(awk '/exp-001/ { print NR; exit }' "$sb")
exp002_pos=$(awk '/exp-002/ { print NR; exit }' "$sb")
exp004_pos=$(awk '/exp-004/ { print NR; exit }' "$sb")

[[ -n "$exp003_pos" && -n "$exp001_pos" && -n "$exp002_pos" && -n "$exp004_pos" ]] \
  || { echo "FAIL: not all rows present" >&2; cat "$sb" >&2; exit 1; }
(( exp003_pos < exp001_pos )) || { echo "FAIL: exp-003 (0.99) should rank above exp-001 (0.98)" >&2; exit 1; }
(( exp001_pos < exp002_pos )) || { echo "FAIL: exp-001 (0.98) should rank above exp-002 (0.79)" >&2; exit 1; }
(( exp002_pos < exp004_pos )) || { echo "FAIL: ok rows should rank above failed rows" >&2; exit 1; }
pass "OK rows sorted desc by metric; failed rows at bottom"

write_exp exp-005 rex 0.9910 ok "Modern LeNet + aug + dropout"
"$PLUGIN_ROOT/bin/deep-research-score.sh" "$slug" || exit 1
exp005_pos=$(awk '/exp-005/ { print NR; exit }' "$sb")
exp003_pos2=$(awk '/exp-003/ { print NR; exit }' "$sb")
(( exp005_pos < exp003_pos2 )) || { echo "FAIL: exp-005 (0.991) should rank above exp-003 (0.99) on re-score" >&2; exit 1; }
pass "rolling scoreboard updates on re-run"

echo "test_deep_research_score_flat: 4 assertions green"
