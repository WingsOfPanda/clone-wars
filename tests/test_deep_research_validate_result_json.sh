#!/usr/bin/env bash
# tests/test_deep_research_validate_result_json.sh — result.json schema check
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

BD="$TMPDIR/branch"
mkdir -p "$BD"
echo "stdout content" > "$BD/stdout.log"
echo "stderr content" > "$BD/stderr.log"

# 1. Valid result.json (status=ok with non-null metric)
cat >"$BD/result.json" <<'EOF'
{"branch_id":"rex-b1","approach_label":"AIDE","metric_name":"accuracy",
 "metric_value":0.95,"status":"ok","runtime_s":120,
 "log_paths":["./stdout.log","./stderr.log"],"notes":"ok"}
EOF
( cd "$BD" && cw_deep_research_validate_result_json result.json ) \
  || { echo "FAIL: valid rejected" >&2; exit 1; }
pass "valid result.json accepted"

# 2. status=fail with metric_value=null is valid
cat >"$BD/result.json" <<'EOF'
{"branch_id":"rex-b1","approach_label":"AIDE","metric_name":"accuracy",
 "metric_value":null,"status":"fail","runtime_s":12,
 "log_paths":["./stdout.log"],"notes":"crash"}
EOF
( cd "$BD" && cw_deep_research_validate_result_json result.json ) \
  || { echo "FAIL: fail+null rejected" >&2; exit 1; }
pass "status=fail with null metric accepted"

# 3. Missing required field → invalid
cat >"$BD/result.json" <<'EOF'
{"branch_id":"rex-b1","metric_value":0.5,"status":"ok"}
EOF
if ( cd "$BD" && cw_deep_research_validate_result_json result.json 2>/dev/null ); then
  echo "FAIL: missing fields accepted" >&2; exit 1
fi
pass "missing fields rejected"

# 4. status=ok with metric_value=null → invalid
cat >"$BD/result.json" <<'EOF'
{"branch_id":"rex-b1","approach_label":"AIDE","metric_name":"accuracy",
 "metric_value":null,"status":"ok","runtime_s":120,
 "log_paths":["./stdout.log"],"notes":""}
EOF
if ( cd "$BD" && cw_deep_research_validate_result_json result.json 2>/dev/null ); then
  echo "FAIL: status=ok with null metric accepted" >&2; exit 1
fi
pass "ok+null rejected"

# 5. log_paths references missing file → invalid
cat >"$BD/result.json" <<'EOF'
{"branch_id":"rex-b1","approach_label":"AIDE","metric_name":"accuracy",
 "metric_value":0.95,"status":"ok","runtime_s":120,
 "log_paths":["./missing.log"],"notes":""}
EOF
if ( cd "$BD" && cw_deep_research_validate_result_json result.json 2>/dev/null ); then
  echo "FAIL: missing log_path accepted" >&2; exit 1
fi
pass "missing log_path rejected"

# 6. Invalid status enum → invalid
cat >"$BD/result.json" <<'EOF'
{"branch_id":"rex-b1","approach_label":"AIDE","metric_name":"accuracy",
 "metric_value":0.95,"status":"weird","runtime_s":120,
 "log_paths":["./stdout.log"],"notes":""}
EOF
if ( cd "$BD" && cw_deep_research_validate_result_json result.json 2>/dev/null ); then
  echo "FAIL: bad status accepted" >&2; exit 1
fi
pass "bad status rejected"

# 7. Malformed JSON → invalid
echo "not valid json {{{" > "$BD/result.json"
if ( cd "$BD" && cw_deep_research_validate_result_json result.json 2>/dev/null ); then
  echo "FAIL: malformed JSON accepted" >&2; exit 1
fi
pass "malformed JSON rejected"

# 8. Missing file → invalid
if ( cd "$BD" && cw_deep_research_validate_result_json missing.json 2>/dev/null ); then
  echo "FAIL: missing file accepted" >&2; exit 1
fi
pass "missing file rejected"

# 9. status=timeout with metric_value=null is valid
cat >"$BD/result.json" <<'EOF'
{"branch_id":"rex-b1","approach_label":"AIDE","metric_name":"accuracy",
 "metric_value":null,"status":"timeout","runtime_s":600,
 "log_paths":["./stdout.log"],"notes":"killed at budget"}
EOF
( cd "$BD" && cw_deep_research_validate_result_json result.json ) \
  || { echo "FAIL: timeout+null rejected" >&2; exit 1; }
pass "status=timeout accepted"

echo "test_deep_research_validate_result_json: 9 assertions green"
