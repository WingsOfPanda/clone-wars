#!/usr/bin/env bash
# tests/test_consult_load_prompt_migration.sh — v0.5.0 byte-equality regression
# guard: each refactored helper must produce identical output to the v0.4.2
# inline heredoc. Baseline files are captured from v0.4.2 git tag and committed
# alongside the test as fixtures.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/log.sh
source ../lib/state.sh
export CLAUDE_PLUGIN_ROOT="$(cd .. && pwd)"
PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT"
source ../lib/consult.sh

# Case 1: research prompt regression.
expected="$(cat fixtures/v0.4.2-research-prompt.txt)"
actual=$(cw_consult_build_research_prompt "decide between LRU and LFU" "/tmp/findings.md")
[[ "$actual" == "$expected" ]] || {
  diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") | head -20
  echo "FAIL c1: research prompt diverged from v0.4.2 baseline"
  exit 1
}
pass "research prompt byte-equal to v0.4.2 baseline"

# Case 2: verify prompt regression.
cat > /tmp/items.txt <<'EOF'
[src/auth/store.py:42] sessions are stored as plaintext
[https://example.com/rfc] RFC says X
EOF
expected="$(cat fixtures/v0.4.2-verify-prompt.txt)"
actual=$(cw_consult_build_verify_prompt /tmp/items.txt /tmp/verify.md)
[[ "$actual" == "$expected" ]] || {
  diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") | head -20
  echo "FAIL c2: verify prompt diverged from v0.4.2 baseline"
  exit 1
}
pass "verify prompt byte-equal to v0.4.2 baseline"

echo "ALL PASS"
