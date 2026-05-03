#!/usr/bin/env bash
# tests/test_deploy_turn_helpers.sh — unit coverage for new turn-prompt builders.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

# shellcheck disable=SC1091
source ../lib/log.sh
# shellcheck disable=SC1091
source ../lib/deploy.sh

# --- cw_deploy_build_turn_prompt_round1 ---
OUT=$(cw_deploy_build_turn_prompt_round1 "/abs/design.md" "/abs/plan.md" "/abs/verify-report-1.md")

echo "$OUT" | grep -q 'END_OF_INSTRUCTION' \
  || { echo "FAIL: round1 missing END_OF_INSTRUCTION sentinel" >&2; exit 1; }
pass "round1 prompt ends with END_OF_INSTRUCTION"

echo "$OUT" | grep -q 'superpowers:writing-plans' \
  || { echo "FAIL: round1 missing writing-plans skill mention" >&2; exit 1; }
pass "round1 names writing-plans skill"

echo "$OUT" | grep -q 'superpowers:subagent-driven-development' \
  || { echo "FAIL: round1 missing subagent-driven-development skill mention" >&2; exit 1; }
pass "round1 names subagent-driven-development skill"

echo "$OUT" | grep -q 'superpowers:verification-before-completion' \
  || { echo "FAIL: round1 missing verification-before-completion skill mention" >&2; exit 1; }
pass "round1 names verification-before-completion skill"

echo "$OUT" | grep -q '/abs/design.md' \
  || { echo "FAIL: round1 missing design path" >&2; exit 1; }
pass "round1 references design path"

echo "$OUT" | grep -q '/abs/plan.md' \
  || { echo "FAIL: round1 missing plan path" >&2; exit 1; }
pass "round1 references plan path"

echo "$OUT" | grep -q '/abs/verify-report-1.md' \
  || { echo "FAIL: round1 missing verify-report path" >&2; exit 1; }
pass "round1 references verify-report path"

echo "$OUT" | grep -qiE 'resume|already exists|skip' \
  || { echo "FAIL: round1 missing resume preamble" >&2; exit 1; }
pass "round1 includes resume preamble"

echo "$OUT" | grep -q 'VERDICT' \
  || { echo "FAIL: round1 missing VERDICT contract" >&2; exit 1; }
pass "round1 mentions VERDICT contract"

echo "ALL: ok"
