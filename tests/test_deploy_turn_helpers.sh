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

echo "$OUT" | grep -qF 'VERDICT: PASS|PARTIAL|FAIL' \
  || { echo "FAIL: round1 missing literal VERDICT: PASS|PARTIAL|FAIL contract" >&2; exit 1; }
pass "round1 mentions VERDICT contract"

echo "$OUT" | grep -q '/abs/test-output-1.log' \
  || { echo "FAIL: round1 must derive absolute test-output path from verify_out dir (expected /abs/test-output-1.log)" >&2; exit 1; }
pass "round1 references absolute test-output-1.log path (derived from verify_out)"

# --- cw_deploy_build_turn_prompt_fix ---
TMPF=$(mktemp); trap 'rm -f "$TMPF"' EXIT
cat > "$TMPF" <<'BUNDLE'
- [bug] foo bar baz
- [spec-gap] quux
BUNDLE

OUT=$(cw_deploy_build_turn_prompt_fix "$TMPF" "/abs/verify-report-3.md" 3)

echo "$OUT" | grep -q 'END_OF_INSTRUCTION' \
  || { echo "FAIL: fix missing END_OF_INSTRUCTION" >&2; exit 1; }
pass "fix prompt ends with END_OF_INSTRUCTION"

echo "$OUT" | grep -q 'ROUND 3' \
  || { echo "FAIL: fix missing round number" >&2; exit 1; }
pass "fix prompt names round number"

echo "$OUT" | grep -q 'superpowers:systematic-debugging' \
  || { echo "FAIL: fix missing systematic-debugging routing" >&2; exit 1; }
pass "fix routes to systematic-debugging for [bug]/[regression]"

echo "$OUT" | grep -q 'superpowers:writing-plans' \
  || { echo "FAIL: fix missing writing-plans routing" >&2; exit 1; }
pass "fix routes to writing-plans for [spec-gap]"

echo "$OUT" | grep -q 'foo bar baz' \
  || { echo "FAIL: fix did not embed bundle content" >&2; exit 1; }
pass "fix embeds the bundle issue text"

echo "$OUT" | grep -q '/abs/verify-report-3.md' \
  || { echo "FAIL: fix missing verify-report path" >&2; exit 1; }
pass "fix references verify-report path"

echo "$OUT" | grep -qiE 'resume|already|skip' \
  || { echo "FAIL: fix missing resume preamble" >&2; exit 1; }
pass "fix includes resume preamble"

# Missing-bundle path
err=$(cw_deploy_build_turn_prompt_fix "/no/such/path.md" "/abs/v.md" 2 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: missing bundle should rc!=0" >&2; exit 1; }
echo "$err" | grep -qi 'not found\|missing\|unreadable' \
  || { echo "FAIL: missing-bundle error message unclear: $err" >&2; exit 1; }
pass "fix prompt rc!=0 + clear error when bundle missing"

echo "ALL: ok"
