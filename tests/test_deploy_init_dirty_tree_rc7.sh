#!/usr/bin/env bash
# tests/test_deploy_init_dirty_tree_rc7.sh — v0.30.0 item 3
# Locks the rc=7-on-dirty-tree convention from cw_deploy_branch_create
# through bin/deploy-init.sh propagation.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
cd "$SANDBOX"
git init -q
git config user.email test@test
git config user.name Test
echo content > tracked.txt
git add tracked.txt
git commit -qm initial

source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/deploy.sh"

# Case 1: clean tree → rc=0
set +e
out=$(cw_deploy_branch_create test-clean 2>&1); rc=$?
set -e
[[ "$rc" -eq 0 ]] || { echo "FAIL: clean-tree branch_create returned $rc, expected 0" >&2; echo "$out" >&2; exit 1; }
pass "1. clean tree: cw_deploy_branch_create rc=0"

# Reset
default_branch=$(git rev-parse --abbrev-ref HEAD)
case "$default_branch" in
  feat/deploy-test-clean)
    # We're on the just-created branch; go back to whatever was before
    git checkout -q HEAD~0 2>/dev/null || true
    git symbolic-ref HEAD "$(git for-each-ref --format='%(refname)' refs/heads/ | grep -v feat/deploy- | head -1)" 2>/dev/null || true
    ;;
esac
git branch -D feat/deploy-test-clean 2>/dev/null || true

# Case 2: dirty tree (uncommitted) → rc=7
echo modified >> tracked.txt
set +e
out=$(cw_deploy_branch_create test-dirty 2>&1); rc=$?
set -e
[[ "$rc" -eq 7 ]] || { echo "FAIL: dirty-tree branch_create returned $rc, expected 7" >&2; echo "$out" >&2; exit 1; }
pass "2. dirty tree (uncommitted): cw_deploy_branch_create rc=7"

# Case 3: untracked files → rc=7
git checkout -- tracked.txt
echo untracked > untracked.txt
set +e
out=$(cw_deploy_branch_create test-untracked 2>&1); rc=$?
set -e
[[ "$rc" -eq 7 ]] || { echo "FAIL: untracked-files branch_create returned $rc, expected 7" >&2; echo "$out" >&2; exit 1; }
pass "3. dirty tree (untracked): cw_deploy_branch_create rc=7"

# Case 4: pre-existing branch (clean tree) → rc=1 (NOT 7)
rm -f untracked.txt
git checkout -q -b feat/deploy-existing
git checkout -q -
set +e
out=$(cw_deploy_branch_create existing 2>&1); rc=$?
set -e
[[ "$rc" -eq 1 ]] || { echo "FAIL: pre-existing-branch branch_create returned $rc, expected 1 (not 7)" >&2; echo "$out" >&2; exit 1; }
pass "4. pre-existing branch: cw_deploy_branch_create rc=1"

# Case 5: not in git repo → rc=1
NONREPO=$(mktemp -d)
cd "$NONREPO"
set +e
out=$(cw_deploy_branch_create test-norepo 2>&1); rc=$?
set -e
[[ "$rc" -eq 1 ]] || { echo "FAIL: not-in-repo branch_create returned $rc, expected 1" >&2; exit 1; }
rm -rf "$NONREPO"
pass "5. not in git repo: cw_deploy_branch_create rc=1"

# Case 6: bin/deploy-init.sh propagates rc=7 from branch_create
cd "$SANDBOX"
git branch -D feat/deploy-existing 2>/dev/null || true
echo dirty-again >> tracked.txt
SPEC="$SANDBOX/spec.md"
cat > "$SPEC" <<'EOFSPEC'
# Test spec
## Goal
Test goal.
## Architecture
Test arch.
## Components
| File | Edit |
|------|------|
| `tracked.txt` | dummy |
## Testing
None.
## Success Criteria
- [ ] Pass
EOFSPEC
set +e
out=$("$PLUGIN_ROOT/bin/deploy-init.sh" --topic dirty-init "$SPEC" 2>&1); rc=$?
set -e
[[ "$rc" -eq 7 ]] || { echo "FAIL: bin/deploy-init.sh on dirty tree returned $rc, expected 7" >&2; echo "$out" >&2; exit 1; }
pass "6. bin/deploy-init.sh propagates rc=7 from branch_create"

echo "test_deploy_init_dirty_tree_rc7: 6 cases passed"
