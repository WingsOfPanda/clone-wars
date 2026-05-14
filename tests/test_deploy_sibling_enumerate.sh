#!/usr/bin/env bash
# tests/test_deploy_sibling_enumerate.sh — v0.30.0 item 2
# Locks cw_deploy_enumerate_siblings: emits one slug per line for first-level
# subdirs of hub-cwd that contain .git/ AND are not in declared targets.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/deploy-sibling.sh"

declare -F cw_deploy_enumerate_siblings >/dev/null \
  || { echo "FAIL: cw_deploy_enumerate_siblings not defined" >&2; exit 1; }
pass "helper defined"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/repo-a" "$SANDBOX/repo-b" "$SANDBOX/repo-c" "$SANDBOX/plain-dir" "$SANDBOX/.hidden"
for r in repo-a repo-b repo-c; do
  ( cd "$SANDBOX/$r" && git init -q )
done

# Case 1: empty declared targets → all 3 git repos returned
out=$(cw_deploy_enumerate_siblings "$SANDBOX" "")
expected=$'repo-a\nrepo-b\nrepo-c'
[[ "$out" == "$expected" ]] || { echo "FAIL: empty-targets enumeration mismatch" >&2; echo "  got:      $out"; echo "  expected: $expected"; exit 1; }
pass "1. empty declared targets: 3 git-repo siblings returned in sorted order"

# Case 2: one target excluded → 2 returned
out=$(cw_deploy_enumerate_siblings "$SANDBOX" "repo-a")
expected=$'repo-b\nrepo-c'
[[ "$out" == "$expected" ]] || { echo "FAIL: 1-target exclusion mismatch" >&2; echo "  got:      $out"; echo "  expected: $expected"; exit 1; }
pass "2. one target excluded: 2 siblings returned"

# Case 3: multiple targets CSV → remaining returned
out=$(cw_deploy_enumerate_siblings "$SANDBOX" "repo-a,repo-c")
[[ "$out" == "repo-b" ]] || { echo "FAIL: 2-target CSV exclusion mismatch (got: $out, expected: repo-b)" >&2; exit 1; }
pass "3. CSV targets excluded: only non-target sibling returned"

# Case 4: plain dir (no .git/) skipped
[[ "$out" != *"plain-dir"* ]] || { echo "FAIL: plain-dir leaked in (no .git, should be skipped)" >&2; exit 1; }
pass "4. plain dir (no .git/) skipped"

# Case 5: hidden dir skipped
[[ "$out" != *".hidden"* ]] || { echo "FAIL: .hidden dir leaked in" >&2; exit 1; }
pass "5. hidden dir (.hidden) skipped"

# Case 6: submodule gitlink (.git is a file) skipped
mkdir -p "$SANDBOX/submodule-style"
echo "gitdir: ../actual-repo/.git/modules/submodule-style" > "$SANDBOX/submodule-style/.git"
out=$(cw_deploy_enumerate_siblings "$SANDBOX" "repo-a,repo-c")
[[ "$out" != *"submodule-style"* ]] || { echo "FAIL: submodule gitlink leaked in" >&2; exit 1; }
pass "6. submodule gitlink (.git is a file) skipped"

# Case 7: hub doesn't exist → rc=1
set +e
out=$(cw_deploy_enumerate_siblings "$SANDBOX/nonexistent" "" 2>&1); rc=$?
set -e
[[ "$rc" == "1" ]] || { echo "FAIL: nonexistent hub: expected rc=1, got $rc" >&2; exit 1; }
pass "7. rc=1 on missing hub directory"

# Case 8: missing arg → rc=2
set +e
out=$(cw_deploy_enumerate_siblings 2>&1); rc=$?
set -e
[[ "$rc" == "2" ]] || { echo "FAIL: missing arg: expected rc=2, got $rc" >&2; exit 1; }
pass "8. rc=2 on missing arg"

echo "test_deploy_sibling_enumerate: 8 cases passed"
