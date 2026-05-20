#!/usr/bin/env bash
# tests/test_deep_research_json_field.sh — v0.47.0 finding #2
# Locks: cw_deep_research_json_field(file, key) extracts a JSON field
# (string / number / bool / null) from result.json. Empty + rc=0 on
# missing file or missing key. Promoted to public in v0.47.0.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

cat > "$SANDBOX/r.json" <<'EOJ'
{
  "branch_id": "exp-001",
  "approach_label": "Plain CNN",
  "metric_name": "accuracy",
  "metric_value": 0.9821,
  "status": "ok",
  "runtime_s": 12.3,
  "notes": "param-shrink to 96k worked"
}
EOJ

# Case 1: string field
out=$(cw_deep_research_json_field "$SANDBOX/r.json" approach_label)
assert_eq "$out" "Plain CNN" "string field"
pass "1. string field extracted"

# Case 2: numeric field (returned as the raw token, no quote stripping needed)
out=$(cw_deep_research_json_field "$SANDBOX/r.json" metric_value)
assert_eq "$out" "0.9821" "numeric field"
pass "2. numeric field extracted as-is"

# Case 3: another numeric (float with one decimal)
out=$(cw_deep_research_json_field "$SANDBOX/r.json" runtime_s)
assert_eq "$out" "12.3" "float field"
pass "3. float numeric field extracted as-is"

# Case 4: missing key → empty + rc=0 (NOT rc=1; verify the helper soft-fails)
set +e
out=$(cw_deep_research_json_field "$SANDBOX/r.json" nonexistent)
rc=$?
set -e
assert_eq "$out" "" "missing key → empty"
assert_eq "$rc" "0" "missing key from present file → rc=0"
pass "4. missing key from present file → empty + rc=0"

# Case 5: missing file → empty (rc may be 1, that's fine; callers don't check)
set +e
out=$(cw_deep_research_json_field "$SANDBOX/nope.json" any)
set -e
assert_eq "$out" "" "missing file → empty"
pass "5. missing file → empty"

echo "test_deep_research_json_field: 5 cases passed"
