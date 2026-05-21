#!/usr/bin/env bash
# tests/test_deploy_question_extract.sh — 3 cases for
# cw_deploy_question_extract_to_payload.
set -uo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
# shellcheck disable=SC1091
source "$PLUGIN_ROOT/lib/state.sh"      # for cw_atomic_write
# shellcheck disable=SC1091
source "$PLUGIN_ROOT/lib/trooper-questions.sh"
# shellcheck disable=SC1091
source "$PLUGIN_ROOT/lib/deploy-questions.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PAYLOAD="$TMP/question-cody-1.txt"

# --- Case 1: well-formed event with claim → payload has TEXT/KIND/VALUE/ROUTE=verify
line='{"event":"question","text":"design doc cites X","claim":{"kind":"path","value":"/abs/foo"},"ts":"2026-05-21T10:00:00Z"}'
cw_deploy_question_extract_to_payload "$line" "$PAYLOAD"
assert_eq "$?" "0" "case1a: extract exit 0"
assert_file_exists "$PAYLOAD" "case1b: payload file created"
assert_contains "$(cat "$PAYLOAD")" "TEXT=design doc cites X" "case1c: TEXT field"
assert_contains "$(cat "$PAYLOAD")" "CLAIM_KIND=path"          "case1d: CLAIM_KIND"
assert_contains "$(cat "$PAYLOAD")" "CLAIM_VALUE=/abs/foo"     "case1e: CLAIM_VALUE"
assert_contains "$(cat "$PAYLOAD")" "ROUTE=verify"             "case1f: ROUTE=verify"

# --- Case 2: claimless event → ROUTE=escalate, KIND+VALUE empty
rm -f "$PAYLOAD"
line='{"event":"question","text":"opinion question","ts":"2026-05-21T10:00:00Z"}'
cw_deploy_question_extract_to_payload "$line" "$PAYLOAD"
assert_eq "$?" "0" "case2a: extract exit 0"
assert_contains "$(cat "$PAYLOAD")" "TEXT=opinion question" "case2b: TEXT field"
assert_contains "$(cat "$PAYLOAD")" "CLAIM_KIND="           "case2c: empty CLAIM_KIND"
assert_contains "$(cat "$PAYLOAD")" "CLAIM_VALUE="          "case2d: empty CLAIM_VALUE"
assert_contains "$(cat "$PAYLOAD")" "ROUTE=escalate"        "case2e: ROUTE=escalate"

# --- Case 3: malformed JSON → rc=1, no payload
rm -f "$PAYLOAD"
line='{"event":"question","text":""}'   # empty text — validator rejects
cw_deploy_question_extract_to_payload "$line" "$PAYLOAD" 2>/dev/null
assert_eq "$?" "1" "case3a: malformed → rc=1"
[[ ! -e "$PAYLOAD" ]] || { echo "FAIL case3b: payload written despite rejection" >&2; exit 1; }
pass "case3b: no payload on rejection"

echo "test_deploy_question_extract: 3 cases passed"
