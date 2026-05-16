#!/usr/bin/env bash
# v0.33.0 D4 — bin/deep-research-consensus.sh per-field agreement matrix
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP"

source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"

TOPIC=deep-research-v033cons
TOPIC_DIR="$(cw_topic_state_dir "$TOPIC")"
ART="$TOPIC_DIR/_deep-research"
mkdir -p "$ART/troopers/rex/experiments/exp-001"
mkdir -p "$ART/troopers/keeli/experiments/exp-001"
mkdir -p "$ART/troopers/colt/experiments/exp-001"

_w() {
  local path="$1" exp="$2" label="$3" mv="$4" status="$5" notes="${6:-ok}"
  cat > "$path" <<EOF
{
  "branch_id": "$exp",
  "approach_label": "$label",
  "metric_name": "accuracy",
  "metric_value": $mv,
  "status": "$status",
  "runtime_s": 10,
  "log_paths": [],
  "notes": "$notes"
}
EOF
}

# Case 1: 3 troopers, close metric_values within epsilon, same labels → ## Agreed populated
_w "$ART/troopers/rex/experiments/exp-001/result.json"   exp-001 resnet 0.970 ok
_w "$ART/troopers/keeli/experiments/exp-001/result.json" exp-001 resnet 0.971 ok
_w "$ART/troopers/colt/experiments/exp-001/result.json"  exp-001 resnet 0.972 ok

"$PLUGIN_ROOT/bin/deep-research-consensus.sh" "$TOPIC" 2>/dev/null
CON="$ART/consensus.md"
assert_file_exists "$CON" "case 1 consensus.md written"
grep -q '^## Agreed' "$CON" \
  || { echo "FAIL: case 1 missing ## Agreed section"; cat "$CON"; exit 1; }
grep -qE 'metric_name.*accuracy.*colt.*keeli.*rex|metric_name.*accuracy.*rex.*keeli.*colt' "$CON" \
  || { echo "FAIL: case 1 metric_name agreement row missing"; cat "$CON"; exit 1; }
grep -qE 'approach_label.*resnet' "$CON" \
  || { echo "FAIL: case 1 approach_label agreement row missing"; cat "$CON"; exit 1; }
pass "1. matching results populate ## Agreed"

# Case 2: 3 troopers, different metric_values > epsilon → ## Contested
_w "$ART/troopers/rex/experiments/exp-001/result.json"   exp-001 resnet 0.970 ok
_w "$ART/troopers/keeli/experiments/exp-001/result.json" exp-001 resnet 0.500 ok
_w "$ART/troopers/colt/experiments/exp-001/result.json"  exp-001 resnet 0.832 ok
"$PLUGIN_ROOT/bin/deep-research-consensus.sh" "$TOPIC" 2>/dev/null
grep -q '^## Contested' "$CON" \
  || { echo "FAIL: case 2 missing ## Contested section"; cat "$CON"; exit 1; }
# Find contested table row for metric_value
awk '/^## Contested/{c=1} c && /metric_value/{found=1} END{exit !found}' "$CON" \
  || { echo "FAIL: case 2 metric_value contested row missing"; cat "$CON"; exit 1; }
pass "2. mismatched metric_value populates ## Contested"

# Case 3: omit notes field from all troopers → notes appears in ## All-missing
for cmdr in rex keeli colt; do
  cat > "$ART/troopers/$cmdr/experiments/exp-001/result.json" <<EOF
{
  "branch_id": "exp-001",
  "approach_label": "resnet",
  "metric_name": "accuracy",
  "metric_value": 0.97,
  "status": "ok",
  "runtime_s": 10,
  "log_paths": []
}
EOF
done
"$PLUGIN_ROOT/bin/deep-research-consensus.sh" "$TOPIC" 2>/dev/null
grep -q '^## All-missing' "$CON" \
  || { echo "FAIL: case 3 missing ## All-missing section"; cat "$CON"; exit 1; }
awk '/^## All-missing/{c=1} c && /notes/{found=1} END{exit !found}' "$CON" \
  || { echo "FAIL: case 3 notes should be in ## All-missing"; cat "$CON"; exit 1; }
pass "3. fields absent across all troopers → ## All-missing"

# Case 4: no result.json files → rc=1
rm -rf "$ART/troopers"
mkdir -p "$ART/troopers/rex"
rc=0
"$PLUGIN_ROOT/bin/deep-research-consensus.sh" "$TOPIC" 2>/dev/null || rc=$?
[[ "$rc" == 1 ]] \
  || { echo "FAIL: case 4 empty corpus should rc=1 (got $rc)"; exit 1; }
pass "4. no result.json files → rc=1"

# Case 5: --epsilon override
mkdir -p "$ART/troopers/rex/experiments/exp-001" \
         "$ART/troopers/keeli/experiments/exp-001"
_w "$ART/troopers/rex/experiments/exp-001/result.json"   exp-001 resnet 0.9700 ok
_w "$ART/troopers/keeli/experiments/exp-001/result.json" exp-001 resnet 0.9705 ok
"$PLUGIN_ROOT/bin/deep-research-consensus.sh" "$TOPIC" 2>/dev/null
# default epsilon 0.01 → metric_value in Agreed
awk '/^## Agreed/{c=1} c && /metric_value/{found=1} END{exit !found}' "$CON" \
  || { echo "FAIL: case 5a default epsilon should put metric_value in Agreed"; cat "$CON"; exit 1; }
# tight epsilon → metric_value moves to Contested
"$PLUGIN_ROOT/bin/deep-research-consensus.sh" "$TOPIC" --epsilon=0.0001 2>/dev/null
awk '/^## Contested/{c=1} c && /metric_value/{found=1} END{exit !found}' "$CON" \
  || { echo "FAIL: case 5b --epsilon=0.0001 should put metric_value in Contested"; cat "$CON"; exit 1; }
pass "5. --epsilon override changes agreement boundary"

echo "test_deep_research_consensus: 5 cases passed"
