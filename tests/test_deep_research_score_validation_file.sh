#!/usr/bin/env bash
# v0.33.0 D2 — score.sh writes result-validation.txt on bad result.json
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP"

TOPIC=deep-research-v033t2
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
TOPIC_DIR="$(cw_topic_state_dir "$TOPIC")"
ART="$TOPIC_DIR/_deep-research"
mkdir -p "$ART/troopers/rex/experiments/exp-001"
mkdir -p "$ART/troopers/keeli/experiments/exp-002"

cat > "$ART/metric.md" <<'EOF'
# Research goal

**Primary metric:** accuracy
**Direction:** maximize
**min_acceptable:** >= 0.90
**K_corroboration:** 1
**plateau_window:** 5
**plateau_threshold:** 0.01
EOF

cat > "$ART/troopers/rex/experiments/exp-001/result.json" <<'EOF'
{
  "branch_id": "exp-001",
  "approach_label": "resnet-small",
  "metric_name": "field_agreement_rate",
  "metric_value": 0.97,
  "status": "ok",
  "runtime_s": 12,
  "log_paths": [],
  "notes": "wrong metric"
}
EOF
cat > "$ART/troopers/keeli/experiments/exp-002/result.json" <<'EOF'
{
  "branch_id": "exp-002",
  "approach_label": "vgg-small",
  "metric_name": "accuracy",
  "metric_value": 0.93,
  "status": "ok",
  "runtime_s": 15,
  "log_paths": [],
  "notes": "ok"
}
EOF
cat > "$ART/troopers/rex/state.txt" <<EOF
phase=working
current_exp_id=exp-001
exp_counter=1
last_event_ts=
last_event=
probe_sent_ts=
EOF
cat > "$ART/troopers/keeli/state.txt" <<EOF
phase=working
current_exp_id=exp-002
exp_counter=1
last_event_ts=
last_event=
probe_sent_ts=
EOF

# Case 1: bad rex → result-validation.txt written; rex absent from scoreboard
"$PLUGIN_ROOT/bin/deep-research-score.sh" "$TOPIC" 2>/dev/null

assert_file_exists "$ART/troopers/rex/experiments/exp-001/result-validation.txt" \
  "case 1: result-validation.txt should exist for bad rex"
grep -q "metric_name 'field_agreement_rate' != metric.md primary 'accuracy'" \
  "$ART/troopers/rex/experiments/exp-001/result-validation.txt" \
  || { echo "FAIL: case 1 reason not in audit file"; cat "$ART/troopers/rex/experiments/exp-001/result-validation.txt"; exit 1; }
grep -q 'exp-001.*rex' "$ART/scoreboard.md" \
  && { echo "FAIL: case 1 bad rex row should NOT be in scoreboard"; cat "$ART/scoreboard.md"; exit 1; }
grep -q 'exp-002.*keeli' "$ART/scoreboard.md" \
  || { echo "FAIL: case 1 good keeli row should be in scoreboard"; cat "$ART/scoreboard.md"; exit 1; }
pass "1. bad result.json writes result-validation.txt; row absent from scoreboard"

# Case 2: fix rex's result.json then re-score; result-validation.txt removed
cat > "$ART/troopers/rex/experiments/exp-001/result.json" <<'EOF'
{
  "branch_id": "exp-001",
  "approach_label": "resnet-small",
  "metric_name": "accuracy",
  "metric_value": 0.97,
  "status": "ok",
  "runtime_s": 12,
  "log_paths": [],
  "notes": "fixed"
}
EOF
"$PLUGIN_ROOT/bin/deep-research-score.sh" "$TOPIC" 2>/dev/null
[[ ! -f "$ART/troopers/rex/experiments/exp-001/result-validation.txt" ]] \
  || { echo "FAIL: case 2 result-validation.txt should be cleaned up on fix"; exit 1; }
grep -q 'exp-001.*rex' "$ART/scoreboard.md" \
  || { echo "FAIL: case 2 fixed rex row should now be in scoreboard"; exit 1; }
pass "2. fixed result.json clears result-validation.txt; row in scoreboard"

# Case 3: multiple invalid results → each gets its own file
cat > "$ART/troopers/rex/experiments/exp-001/result.json" <<'EOF'
{
  "branch_id": "exp-001",
  "approach_label": "resnet-small",
  "metric_name": "field_agreement_rate",
  "metric_value": 0.97,
  "status": "ok",
  "runtime_s": 12,
  "log_paths": [],
  "notes": "still wrong"
}
EOF
cat > "$ART/troopers/keeli/experiments/exp-002/result.json" <<'EOF'
{
  "branch_id": "exp-002",
  "approach_label": "vgg-small",
  "metric_name": "filled_count",
  "metric_value": 42,
  "status": "ok",
  "runtime_s": 15,
  "log_paths": [],
  "notes": "wrong metric"
}
EOF
"$PLUGIN_ROOT/bin/deep-research-score.sh" "$TOPIC" 2>/dev/null
assert_file_exists "$ART/troopers/rex/experiments/exp-001/result-validation.txt" \
  "case 3: rex audit file present"
assert_file_exists "$ART/troopers/keeli/experiments/exp-002/result-validation.txt" \
  "case 3: keeli audit file present"
pass "3. multiple invalid results → each gets its own audit file"

echo "test_deep_research_score_validation_file: 3 cases passed"
