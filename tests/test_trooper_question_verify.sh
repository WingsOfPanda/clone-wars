#!/usr/bin/env bash
# tests/test_trooper_question_verify.sh — 9 cases for cw_trooper_question_verify.
# Covers all 5 claim kinds (path/git/env/cmd/test) plus the kind=test soft-spot
# guard (run.sh ban, 30s timeout escalates to rc=2).
set -uo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
# shellcheck disable=SC1091
source "$PLUGIN_ROOT/lib/trooper-questions.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- Case 1: path exists + readable → rc=0
existing="$TMP/existing.txt"
printf 'hello\n' > "$existing"
cw_trooper_question_verify path "$existing" >/dev/null
assert_eq "$?" "0" "case1: path exists → rc=0"

# --- Case 2: path missing → rc=1
cw_trooper_question_verify path "$TMP/nope" >/dev/null
assert_eq "$?" "1" "case2: path missing → rc=1"

# --- Case 3: git ref valid → rc=0
# Use HEAD as a guaranteed-valid ref inside the plugin repo.
(cd "$PLUGIN_ROOT" && cw_trooper_question_verify git HEAD >/dev/null)
assert_eq "$?" "0" "case3: git HEAD → rc=0"

# --- Case 4: git ref invalid → rc=1
(cd "$PLUGIN_ROOT" && cw_trooper_question_verify git refs/heads/no-such-branch-xyz123 >/dev/null)
assert_eq "$?" "1" "case4: git bogus ref → rc=1"

# --- Case 5: env var set + non-empty → rc=0
export CW_TEST_VAR_SET=hello
cw_trooper_question_verify env CW_TEST_VAR_SET >/dev/null
assert_eq "$?" "0" "case5: env set → rc=0"

# --- Case 6: env var unset → rc=1
unset CW_TEST_VAR_UNSET 2>/dev/null || true
cw_trooper_question_verify env CW_TEST_VAR_UNSET >/dev/null
assert_eq "$?" "1" "case6: env unset → rc=1"

# --- Case 7: cmd on PATH → rc=0
cw_trooper_question_verify cmd bash >/dev/null
assert_eq "$?" "0" "case7: bash on PATH → rc=0"

# --- Case 8: cmd absent → rc=1
cw_trooper_question_verify cmd no-such-binary-xyz123 >/dev/null
assert_eq "$?" "1" "case8: cmd absent → rc=1"

# --- Case 9: kind=test runs command, captures stdout, returns its rc
out=$(cw_trooper_question_verify test 'echo evidence; exit 0' 2>/dev/null)
assert_eq "$?" "0" "case9a: test exit 0 → rc=0"
assert_contains "$out" "evidence" "case9b: test stdout captured"

# --- Case 10: kind=test exit non-zero → rc=1
cw_trooper_question_verify test 'exit 7' >/dev/null 2>&1
assert_eq "$?" "1" "case10: test exit 7 → rc=1"

# --- Case 11: kind=test rejected when value starts with tests/run.sh → rc=2
cw_trooper_question_verify test 'tests/run.sh --foo' >/dev/null 2>&1
assert_eq "$?" "2" "case11: test value 'tests/run.sh ...' → rc=2 (banned)"

# --- Case 12: kind=test rejected when value starts with 'bash tests/run.sh' → rc=2
cw_trooper_question_verify test 'bash tests/run.sh' >/dev/null 2>&1
assert_eq "$?" "2" "case12: test value 'bash tests/run.sh' → rc=2 (banned)"

# --- Case 13: unknown kind → rc=2
cw_trooper_question_verify nopekind value >/dev/null 2>&1
assert_eq "$?" "2" "case13: unknown kind → rc=2"

# --- Case 14: empty value → rc=2
cw_trooper_question_verify path '' >/dev/null 2>&1
assert_eq "$?" "2" "case14: empty value → rc=2"

echo "test_trooper_question_verify: 14 cases passed"
