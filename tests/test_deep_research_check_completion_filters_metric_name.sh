#!/usr/bin/env bash
# v0.33.0 D1 — check_completion ignores rows whose metric_name doesn't match metric.md
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"

cat > "$TMP/metric.md" <<'EOF'
# Research goal

**Primary metric:** accuracy
**Direction:** maximize
**min_acceptable:** >= 0.90
**target:** >= 0.99
**K_corroboration:** 1
**plateau_window:** 5
**plateau_threshold:** 0.01
EOF

# Case 1: only rex's matching-metric_name row counts toward K
cat > "$TMP/scoreboard.md" <<'EOF'
# Scoreboard

| Rank | Experiment | Commander | Metric | Status | Runtime | Approach | metric_name |
|---|---|---|---|---|---|---|---|
| 1 | exp-001 | rex | 0.995 | ok | 12s | resnet | accuracy |
| 2 | exp-002 | keeli | 0.997 | ok | 13s | vgg | field_agreement_rate |
EOF
out=$(cw_deep_research_check_completion "$TMP/scoreboard.md" "$TMP/metric.md")
echo "$out" | grep -q 'K_so_far=1' \
  || { echo "FAIL: case 1 K_so_far should be 1 (only rex matches metric_name)"; echo "$out"; exit 1; }
echo "$out" | grep -q 'target_met=yes' \
  || { echo "FAIL: case 1 target_met should be yes (rex hit target)"; echo "$out"; exit 1; }
pass "1. matching-metric_name row counts; mismatched row skipped"

# Case 2: all-mismatched scoreboard → no completion signal
cat > "$TMP/scoreboard.md" <<'EOF'
# Scoreboard

| Rank | Experiment | Commander | Metric | Status | Runtime | Approach | metric_name |
|---|---|---|---|---|---|---|---|
| 1 | exp-001 | rex | 0.995 | ok | 12s | resnet | field_agreement_rate |
| 2 | exp-002 | keeli | 0.997 | ok | 13s | vgg | filled_count |
EOF
out=$(cw_deep_research_check_completion "$TMP/scoreboard.md" "$TMP/metric.md")
echo "$out" | grep -q 'floor_met=no' \
  || { echo "FAIL: case 2 floor_met should be no"; echo "$out"; exit 1; }
echo "$out" | grep -q 'target_met=no' \
  || { echo "FAIL: case 2 target_met should be no"; echo "$out"; exit 1; }
echo "$out" | grep -q 'K_so_far=0' \
  || { echo "FAIL: case 2 K_so_far should be 0"; echo "$out"; exit 1; }
pass "2. all-mismatched scoreboard → no completion signal"

# Case 3: legacy scoreboard without metric_name column → filter is no-op (back-compat)
cat > "$TMP/scoreboard.md" <<'EOF'
# Scoreboard

| Rank | Experiment | Commander | Metric | Status | Runtime | Approach |
|---|---|---|---|---|---|---|
| 1 | exp-001 | rex | 0.995 | ok | 12s | resnet |
EOF
out=$(cw_deep_research_check_completion "$TMP/scoreboard.md" "$TMP/metric.md")
echo "$out" | grep -q 'K_so_far=1' \
  || { echo "FAIL: case 3 legacy scoreboard should count rows without metric_name (back-compat)"; echo "$out"; exit 1; }
pass "3. legacy scoreboard (no metric_name col) → filter is no-op"

echo "test_deep_research_check_completion_filters_metric_name: 3 cases passed"
