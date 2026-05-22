#!/usr/bin/env bash
# tests/test_deep_research_prune_intermediate.sh — v0.52.0 #19
# Validates cw_deep_research_prune_intermediate_checkpoints: keeps the
# file pointed to by result.json:checkpoint_path; prunes other *.pt;
# skips dirs without a non-null checkpoint_path.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Build fixture art-dir with 4 experiment dirs (one per case).
ART="$TMP/_deep-research"
mkdir -p "$ART/troopers/rex/experiments/exp-001"   # case 1: prune intermediates
mkdir -p "$ART/troopers/rex/experiments/exp-002"   # case 2: no result.json
mkdir -p "$ART/troopers/rex/experiments/exp-003"   # case 3: checkpoint_path null
mkdir -p "$ART/troopers/rex/experiments/exp-004"   # case 4: escape path

# Case 1: result.json points to final.pt; intermediates should be deleted.
cat > "$ART/troopers/rex/experiments/exp-001/result.json" <<'EOF'
{"checkpoint_path":"./final.pt","status":"ok","metric_value":100.0}
EOF
touch "$ART/troopers/rex/experiments/exp-001/final.pt"
touch "$ART/troopers/rex/experiments/exp-001/mid-001.pt"
touch "$ART/troopers/rex/experiments/exp-001/mid-002.pt"

# Case 2: no result.json — all *.pt survive.
touch "$ART/troopers/rex/experiments/exp-002/run-001.pt"
touch "$ART/troopers/rex/experiments/exp-002/run-002.pt"

# Case 3: result.json has checkpoint_path: null — all *.pt survive.
cat > "$ART/troopers/rex/experiments/exp-003/result.json" <<'EOF'
{"checkpoint_path":null,"status":"fail","metric_value":null}
EOF
touch "$ART/troopers/rex/experiments/exp-003/abandoned.pt"

# Case 4: result.json points outside the dir — skip with warn.
cat > "$ART/troopers/rex/experiments/exp-004/result.json" <<'EOF'
{"checkpoint_path":"../../escape.pt","status":"ok","metric_value":50.0}
EOF
touch "$ART/troopers/rex/experiments/exp-004/local.pt"

# Run the helper.
cw_deep_research_prune_intermediate_checkpoints "$ART" >"$TMP/prune-out.log" 2>&1
out=$(cat "$TMP/prune-out.log")

# Case 1 assertions
assert_file_exists "$ART/troopers/rex/experiments/exp-001/final.pt" "case1: final.pt preserved"
[[ ! -e "$ART/troopers/rex/experiments/exp-001/mid-001.pt" ]] \
  || { echo "FAIL case1: mid-001.pt should have been pruned" >&2; exit 1; }
[[ ! -e "$ART/troopers/rex/experiments/exp-001/mid-002.pt" ]] \
  || { echo "FAIL case1: mid-002.pt should have been pruned" >&2; exit 1; }
pass "case1: intermediates pruned, final.pt kept"

# Case 2 assertions
assert_file_exists "$ART/troopers/rex/experiments/exp-002/run-001.pt" "case2: no result.json — pt preserved"
assert_file_exists "$ART/troopers/rex/experiments/exp-002/run-002.pt" "case2: pt 2 preserved"
pass "case2: no result.json skipped"

# Case 3 assertions
assert_file_exists "$ART/troopers/rex/experiments/exp-003/abandoned.pt" "case3: checkpoint_path=null — pt preserved"
pass "case3: checkpoint_path=null skipped"

# Case 4 assertions
assert_file_exists "$ART/troopers/rex/experiments/exp-004/local.pt" "case4: escape path — pt preserved"
assert_contains "$out" "escape" "case4: log warns about escape path"
pass "case4: escape path rejected"

# Case 5: CW_DEEP_RESEARCH_KEEP_INTERMEDIATE=1 short-circuits.
touch "$ART/troopers/rex/experiments/exp-001/mid-003.pt"
CW_DEEP_RESEARCH_KEEP_INTERMEDIATE=1 \
  cw_deep_research_prune_intermediate_checkpoints "$ART" >"$TMP/prune-keep.log" 2>&1
keep_out=$(cat "$TMP/prune-keep.log")
assert_file_exists "$ART/troopers/rex/experiments/exp-001/mid-003.pt" "case5: keep-intermediate preserves new mid file"
assert_contains "$keep_out" "keep_intermediate" "case5: log line emitted"
pass "case5: CW_DEEP_RESEARCH_KEEP_INTERMEDIATE=1 short-circuits"

echo "ALL: ok"
