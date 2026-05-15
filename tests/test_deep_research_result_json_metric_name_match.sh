#!/usr/bin/env bash
# v0.33.0 D1 — cw_deep_research_validate_result_json_v033
# Locks: metric_name match check, rc=1 with reason on mismatch.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"

# Case 1 — matching metric_name validates ok
cat > "$TMP/result.json" <<'EOF'
{
  "branch_id": "exp-001",
  "approach_label": "resnet-small",
  "metric_name": "accuracy",
  "metric_value": 0.97,
  "status": "ok",
  "runtime_s": 12,
  "log_paths": [],
  "notes": "ok"
}
EOF
( cd "$TMP" && cw_deep_research_validate_result_json_v033 result.json accuracy ) \
  || { echo "FAIL: case 1 matching metric_name should pass"; exit 1; }
pass "1. matching metric_name validates ok"

# Case 2 — mismatched metric_name fails rc=1 with reason
err=$( ( cd "$TMP" && cw_deep_research_validate_result_json_v033 result.json field_agreement_rate ) 2>&1 ) \
  && { echo "FAIL: case 2 mismatch should rc=1"; exit 1; }
echo "$err" | grep -q "metric_name 'accuracy' != metric.md primary 'field_agreement_rate'" \
  || { echo "FAIL: case 2 reason not matched. got: $err"; exit 1; }
pass "2. mismatched metric_name fails with specific reason"

# Case 3 — missing metric_name field fails
cat > "$TMP/no-metric-name.json" <<'EOF'
{
  "branch_id": "exp-001",
  "approach_label": "resnet-small",
  "metric_value": 0.97,
  "status": "ok",
  "runtime_s": 12,
  "log_paths": [],
  "notes": "ok"
}
EOF
( cd "$TMP" && cw_deep_research_validate_result_json_v033 no-metric-name.json accuracy ) 2>/dev/null \
  && { echo "FAIL: case 3 missing field should rc=1"; exit 1; }
pass "3. missing metric_name field rejected"

echo "test_deep_research_result_json_metric_name_match: 3 cases passed"
