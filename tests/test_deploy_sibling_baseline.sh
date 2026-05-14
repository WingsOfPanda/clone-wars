#!/usr/bin/env bash
# tests/test_deploy_sibling_baseline.sh — v0.30.0 item 2b
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/deploy-sibling.sh"

for fn in cw_deploy_capture_sibling_baseline cw_deploy_diff_sibling_against_baseline; do
  declare -F "$fn" >/dev/null \
    || { echo "FAIL: $fn not defined" >&2; exit 1; }
done
pass "helpers defined"

# Sandbox repo with 1 commit on default branch
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
cd "$SANDBOX"
git init -q -b main
git config user.email test@test
git config user.name Test
echo c1 > a.txt
git add a.txt
git commit -qm c1
SHA1=$(git rev-parse HEAD)

# Case 1: capture_sibling_baseline emits TSV
out=$(cw_deploy_capture_sibling_baseline "$SANDBOX")
expected=$(printf '%s\t%s\tmain' "$(basename "$SANDBOX")" "$SHA1")
[[ "$out" == "$expected" ]] || { echo "FAIL: baseline TSV mismatch — got: $out, expected: $expected" >&2; exit 1; }
pass "1. capture_sibling_baseline emits <slug>\\t<sha>\\tmain"

# Case 2: alternate default branch (master)
SANDBOX2=$(mktemp -d)
cd "$SANDBOX2"
git init -q -b master
git config user.email test@test
git config user.name Test
echo c1 > b.txt
git add b.txt
git commit -qm c1
SHA2=$(git rev-parse HEAD)
out=$(cw_deploy_capture_sibling_baseline "$SANDBOX2")
expected=$(printf '%s\t%s\tmaster' "$(basename "$SANDBOX2")" "$SHA2")
[[ "$out" == "$expected" ]] || { echo "FAIL: master-default TSV mismatch — got: $out, expected: $expected" >&2; exit 1; }
rm -rf "$SANDBOX2"
pass "2. capture_sibling_baseline honors non-main default branch"

# Case 3: not a git repo → rc=1
NONREPO=$(mktemp -d)
set +e
out=$(cw_deploy_capture_sibling_baseline "$NONREPO" 2>&1); rc=$?
set -e
[[ "$rc" == "1" ]] || { echo "FAIL: not-a-repo: expected rc=1, got $rc" >&2; exit 1; }
rm -rf "$NONREPO"
pass "3. capture_sibling_baseline rc=1 on non-git directory"

# Case 4: diff with no new commits → empty
cd "$SANDBOX"
out=$(cw_deploy_diff_sibling_against_baseline "$SANDBOX" "$SHA1" "main")
[[ -z "$out" ]] || { echo "FAIL: no-new-commits should print nothing, got: $out" >&2; exit 1; }
pass "4. diff_sibling_against_baseline: empty output when baseline == HEAD"

# Case 5: 2 new commits → 2 rows
echo c2 > a.txt
git add a.txt
git commit -qm c2
echo c3 > a.txt
git add a.txt
git commit -qm c3
out=$(cw_deploy_diff_sibling_against_baseline "$SANDBOX" "$SHA1" "main")
n_rows=$(printf '%s\n' "$out" | wc -l)
[[ "$n_rows" == "2" ]] || { echo "FAIL: expected 2 oneline rows, got $n_rows" >&2; echo "$out"; exit 1; }
grep -q ' c2$' <<<"$out" || { echo "FAIL: c2 commit missing" >&2; exit 1; }
grep -q ' c3$' <<<"$out" || { echo "FAIL: c3 commit missing" >&2; exit 1; }
pass "5. diff_sibling_against_baseline: 2 new commits surface in oneline form"

# Case 6: missing branch arg → rc=2
set +e
out=$(cw_deploy_diff_sibling_against_baseline "$SANDBOX" "$SHA1" 2>&1); rc=$?
set -e
[[ "$rc" == "2" ]] || { echo "FAIL: missing branch arg: expected rc=2, got $rc" >&2; exit 1; }
pass "6. diff_sibling_against_baseline rc=2 on missing branch arg"

echo "test_deploy_sibling_baseline: 6 cases passed"
