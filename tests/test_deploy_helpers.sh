#!/usr/bin/env bash
# tests/test_deploy_helpers.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/log.sh
source ../lib/state.sh
source ../lib/deploy.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

# 1. topic_dir + art_dir return absolute paths under $CLONE_WARS_HOME/state/.
RH=$(cw_repo_hash)
got=$(cw_deploy_topic_dir my-topic)
assert_eq "$got" "$CLONE_WARS_HOME/state/$RH/my-topic" "topic_dir"
got=$(cw_deploy_art_dir my-topic)
assert_eq "$got" "$CLONE_WARS_HOME/state/$RH/my-topic/_deploy" "art_dir"
pass "topic_dir + art_dir"

# 2. assert_topic accepts valid slugs, rejects invalid.
( cw_deploy_assert_topic my-topic ) || { echo "FAIL: valid slug rejected" >&2; exit 1; }
out=$( cw_deploy_assert_topic "../bad" 2>&1 ) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: path-traversal accepted" >&2; exit 1; }
out=$( cw_deploy_assert_topic "Bad-Topic" 2>&1 ) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: uppercase accepted" >&2; exit 1; }
pass "assert_topic"

# 3. derive_topic strips date prefix + -design.md suffix.
got=$(cw_deploy_derive_topic "docs/superpowers/specs/2026-05-02-foo-bar-design.md")
assert_eq "$got" "foo-bar" "derive_topic strips prefix+suffix"
got=$(cw_deploy_derive_topic "/abs/path/2026-04-29-x-design.md")
assert_eq "$got" "x" "derive_topic abs path"
# Filename without date prefix → return basename minus -design.md (caller decides)
got=$(cw_deploy_derive_topic "anything-design.md")
assert_eq "$got" "anything" "derive_topic missing date prefix"
# Filename without -design.md suffix → return basename minus extension
got=$(cw_deploy_derive_topic "raw.md")
assert_eq "$got" "raw" "derive_topic missing -design suffix"
# Empty / no-extension → empty string (caller refuses)
got=$(cw_deploy_derive_topic "")
assert_eq "$got" "" "derive_topic empty input"
pass "derive_topic"

# 4. audit_doc — PASS for a complete spec, FAIL for one with TBDs and missing sections.
GOOD="$TMP/good.md"
cat > "$GOOD" <<'MD'
# Foo Spec
**Status:** Design
## Goal
Build foo.
## Architecture
Use bar pattern.
## Testing strategy
Unit tests under tests/test_foo.sh; integration via fixtures/.
## Success criteria
1. tests pass
2. medic OK
MD
out=$(cw_deploy_audit_doc "$GOOD") && rc=0 || rc=$?
[[ "$rc" -eq 0 ]] || { echo "FAIL: good spec scored FAIL: $out" >&2; exit 1; }
echo "$out" | grep -q '^VERDICT=PASS' || { echo "FAIL: missing VERDICT=PASS in: $out" >&2; exit 1; }
pass "audit_doc PASS on complete spec"

BAD="$TMP/bad.md"
cat > "$BAD" <<'MD'
# Bad Spec
## Goal
TBD
## Architecture
fill in later
MD
out=$(cw_deploy_audit_doc "$BAD") && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: bad spec scored PASS: $out" >&2; exit 1; }
echo "$out" | grep -q '^VERDICT=FAIL' || { echo "FAIL: missing VERDICT=FAIL in: $out" >&2; exit 1; }
echo "$out" | grep -q 'no_testing_section'   || { echo "FAIL: testing section not flagged" >&2; exit 1; }
echo "$out" | grep -q 'no_success_section'   || { echo "FAIL: success criteria not flagged" >&2; exit 1; }
echo "$out" | grep -q 'tbd_marker'           || { echo "FAIL: TBD not flagged" >&2; exit 1; }
echo "$out" | grep -q 'fill_in_later_marker' || { echo "FAIL: 'fill in later' not flagged" >&2; exit 1; }
pass "audit_doc FAIL on incomplete spec with structured issues"

# 5. Missing file → exit 2 with usage-style error.
out=$(cw_deploy_audit_doc "$TMP/nope.md" 2>&1) && rc=0 || rc=$?
[[ "$rc" -eq 2 ]] || { echo "FAIL: missing file did not exit 2: rc=$rc out=$out" >&2; exit 1; }
pass "audit_doc rc=2 on missing file"

# 6. branch_create — happy path: clean tree, branch doesn't exist.
REPO="$TMP/repo"
git -C "$TMP" init --quiet --initial-branch=main "$REPO"
cd "$REPO"
git config user.email t@t; git config user.name t
echo init > a.txt; git add a.txt; git commit --quiet -m init

out=$(cw_deploy_branch_create my-topic) && rc=0 || rc=$?
[[ "$rc" -eq 0 ]] || { echo "FAIL: branch_create happy-path rc=$rc out=$out" >&2; exit 1; }
[[ "$out" == "feat/deploy-my-topic" ]] || { echo "FAIL: bad branch name printed: $out" >&2; exit 1; }
got=$(git rev-parse --abbrev-ref HEAD)
assert_eq "$got" "feat/deploy-my-topic" "branch checked out"
pass "branch_create happy path"

# 7. Refuses if branch exists.
git checkout --quiet main
out=$(cw_deploy_branch_create my-topic 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: existing branch accepted" >&2; exit 1; }
echo "$out" | grep -q 'already exists' || { echo "FAIL: error msg missing 'already exists': $out" >&2; exit 1; }
pass "branch_create refuses existing branch"

# 8. Refuses if working tree is dirty.
git checkout --quiet main
echo dirty > b.txt
out=$(cw_deploy_branch_create other-topic 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: dirty tree accepted" >&2; exit 1; }
echo "$out" | grep -q 'dirty\|uncommitted' || { echo "FAIL: error msg missing 'dirty': $out" >&2; exit 1; }
pass "branch_create refuses dirty tree"

# 8a. Refuses outside a git repo.
cd "$TMP"
export GIT_CEILING_DIRECTORIES="$TMP"
mkdir -p "$TMP/no-git" && cd "$TMP/no-git"
out=$(cw_deploy_branch_create some-topic 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: no-git accepted" >&2; exit 1; }
echo "$out" | grep -q 'not inside a git repository' \
  || { echo "FAIL: error msg missing 'not inside a git repository': $out" >&2; exit 1; }
pass "branch_create refuses outside git repo"

# 8b. Branch override is honored.
cd "$TMP"
git -C "$TMP" init --quiet --initial-branch=main "$TMP/repo2" >/dev/null
cd "$TMP/repo2"
git config user.email t@t; git config user.name t
echo seed > a.txt; git add a.txt; git commit --quiet -m init
out=$(cw_deploy_branch_create some-topic custom-branch-name) && rc=0 || rc=$?
[[ "$rc" -eq 0 ]] || { echo "FAIL: override happy-path rc=$rc" >&2; exit 1; }
[[ "$out" == "custom-branch-name" ]] || { echo "FAIL: override not honored: $out" >&2; exit 1; }
got=$(git rev-parse --abbrev-ref HEAD); assert_eq "$got" "custom-branch-name" "override branch checked out"
pass "branch_create override honored"

# 9. plan-prompt builder names the writing-plans skill + the design path.
out=$(cw_deploy_build_plan_prompt /abs/_deploy/design.md /abs/_deploy/plan.md)
echo "$out" | grep -q 'superpowers:writing-plans'    || { echo "FAIL: skill missing" >&2; exit 1; }
echo "$out" | grep -q '/abs/_deploy/design.md'      || { echo "FAIL: design path missing" >&2; exit 1; }
echo "$out" | grep -q '/abs/_deploy/plan.md'        || { echo "FAIL: plan path missing" >&2; exit 1; }
echo "$out" | grep -q 'END_OF_INSTRUCTION'           || { echo "FAIL: sentinel missing" >&2; exit 1; }
pass "plan-prompt builder"

# 10. implement-prompt names subagent-driven-development + plan path.
out=$(cw_deploy_build_implement_prompt /abs/_deploy/plan.md)
echo "$out" | grep -q 'superpowers:subagent-driven-development' \
  || { echo "FAIL: skill missing" >&2; exit 1; }
echo "$out" | grep -q '/abs/_deploy/plan.md'        || { echo "FAIL: plan path missing" >&2; exit 1; }
echo "$out" | grep -q 'commit per task'              || { echo "FAIL: commit guidance missing" >&2; exit 1; }
echo "$out" | grep -q 'END_OF_INSTRUCTION'           || { echo "FAIL: sentinel missing" >&2; exit 1; }
pass "implement-prompt builder"

# 11. verify-prompt names verification-before-completion + per-round paths.
out=$(cw_deploy_build_verify_prompt /abs/_deploy/design.md 1 /abs/_deploy/verify-report-1.md /abs/_deploy/test-output-1.log)
echo "$out" | grep -q 'superpowers:verification-before-completion' \
  || { echo "FAIL: skill missing" >&2; exit 1; }
echo "$out" | grep -q '/abs/_deploy/design.md'             || { echo "FAIL: design path missing" >&2; exit 1; }
echo "$out" | grep -q '/abs/_deploy/verify-report-1.md'    || { echo "FAIL: report path missing" >&2; exit 1; }
echo "$out" | grep -q '/abs/_deploy/test-output-1.log'     || { echo "FAIL: test-output path missing" >&2; exit 1; }
echo "$out" | grep -q 'END_OF_INSTRUCTION'                  || { echo "FAIL: sentinel missing" >&2; exit 1; }
pass "verify-prompt builder"

# 12. fix-prompt names the fix-prompt path; the directive selects the skill.
out=$(cw_deploy_build_fix_prompt /abs/_deploy/fix-prompt-1.md)
echo "$out" | grep -q '/abs/_deploy/fix-prompt-1.md'       || { echo "FAIL: fix-prompt path missing" >&2; exit 1; }
echo "$out" | grep -q 'preamble'                            || { echo "FAIL: preamble guidance missing" >&2; exit 1; }
echo "$out" | grep -q 'commit per fix'                      || { echo "FAIL: commit guidance missing" >&2; exit 1; }
echo "$out" | grep -q 'END_OF_INSTRUCTION'                  || { echo "FAIL: sentinel missing" >&2; exit 1; }
pass "fix-prompt builder"

# Cleanup test cwd
cd "$TMP"
rm -rf "$REPO"
