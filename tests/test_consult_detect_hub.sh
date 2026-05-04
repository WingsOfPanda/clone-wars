#!/usr/bin/env bash
# tests/test_consult_detect_hub.sh — coverage for cw_consult_detect_hub.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/log.sh
source ../lib/consult.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Case 1: hub fixture (parent + 2 child .git dirs) → rc=0 + lists 2 sub-repos.
mkdir -p "$TMP/hub/.git" "$TMP/hub/sub-a/.git" "$TMP/hub/sub-b/.git"
out=$(cw_consult_detect_hub "$TMP/hub") && rc=0 || rc=$?
[[ "$rc" -eq 0 ]] || { echo "FAIL: hub fixture should rc=0 (got $rc)" >&2; exit 1; }
echo "$out" | grep -q '^sub-a$' && echo "$out" | grep -q '^sub-b$' \
  || { echo "FAIL: hub fixture should list sub-a + sub-b (got: $out)" >&2; exit 1; }
pass "detect_hub returns sub-repos when hub structure present"

# Case 2: single-repo (parent .git only, no children) → rc=1 + empty.
mkdir -p "$TMP/single/.git" "$TMP/single/srcdir"
out=$(cw_consult_detect_hub "$TMP/single") && rc=0 || rc=$?
[[ "$rc" -eq 1 ]] || { echo "FAIL: single-repo should rc=1 (got $rc)" >&2; exit 1; }
[[ -z "$out" ]] || { echo "FAIL: single-repo should print empty (got: $out)" >&2; exit 1; }
pass "detect_hub returns rc=1 for single-repo cwd"

# Case 3: nested non-git child dirs → rc=1.
mkdir -p "$TMP/nested-no-git/.git" "$TMP/nested-no-git/childA" "$TMP/nested-no-git/childB"
out=$(cw_consult_detect_hub "$TMP/nested-no-git") && rc=0 || rc=$?
[[ "$rc" -eq 1 ]] || { echo "FAIL: nested-no-git should rc=1 (got $rc)" >&2; exit 1; }
pass "detect_hub returns rc=1 when children have no .git"

# Case 4: cwd is not a git repo (no .git in parent) → rc=1.
mkdir -p "$TMP/not-git/sub-a/.git"
out=$(cw_consult_detect_hub "$TMP/not-git") && rc=0 || rc=$?
[[ "$rc" -eq 1 ]] || { echo "FAIL: cwd-not-git should rc=1 (got $rc)" >&2; exit 1; }
pass "detect_hub returns rc=1 when cwd itself is not a git repo"

echo "ALL: ok"
