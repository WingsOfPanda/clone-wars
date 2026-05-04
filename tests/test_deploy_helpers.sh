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

# Cleanup test cwd
cd "$TMP"
rm -rf "$REPO"

# --- cw_deploy_detect_provider ---
TMP_DETECT=$(mktemp -d); trap 'rm -rf "$TMP" "$TMP_DETECT"' EXIT

# Case 1: file present → claude
mkdir -p "$TMP_DETECT/yes/.claude-plugin"
touch "$TMP_DETECT/yes/.claude-plugin/plugin.json"
out=$(cw_deploy_detect_provider "$TMP_DETECT/yes")
[[ "$out" == "claude" ]] \
  || { echo "FAIL: detect with plugin.json should return 'claude' (got '$out')" >&2; exit 1; }
pass "detect_provider returns 'claude' when .claude-plugin/plugin.json exists"

# Case 2: file absent → codex
mkdir -p "$TMP_DETECT/no"
out=$(cw_deploy_detect_provider "$TMP_DETECT/no")
[[ "$out" == "codex" ]] \
  || { echo "FAIL: detect without plugin.json should return 'codex' (got '$out')" >&2; exit 1; }
pass "detect_provider returns 'codex' when .claude-plugin/plugin.json absent"

# Case 3: directory present but no file → codex (presence test must be on file)
mkdir -p "$TMP_DETECT/dir-only/.claude-plugin"
out=$(cw_deploy_detect_provider "$TMP_DETECT/dir-only")
[[ "$out" == "codex" ]] \
  || { echo "FAIL: empty .claude-plugin/ dir should return 'codex' (got '$out')" >&2; exit 1; }
pass "detect_provider returns 'codex' when .claude-plugin/ exists but plugin.json doesn't"

# Case 4: missing repo-root → codex (graceful no-signal case)
out=$(cw_deploy_detect_provider "$TMP_DETECT/does-not-exist")
[[ "$out" == "codex" ]] \
  || { echo "FAIL: missing repo-root should return 'codex' (got '$out')" >&2; exit 1; }
pass "detect_provider returns 'codex' when repo-root doesn't exist"

# Case 5: no arg → rc=2 with clear error
err=$(cw_deploy_detect_provider 2>&1) && rc=0 || rc=$?
[[ "$rc" -eq 2 ]] || { echo "FAIL: no arg should rc=2 (got $rc)" >&2; exit 1; }
echo "$err" | grep -qi 'missing.*repo-root\|repo-root.*missing\|repo-root arg' \
  || { echo "FAIL: no-arg error message unclear: $err" >&2; exit 1; }
pass "detect_provider rc=2 + clear error when no arg"

# --- cw_deploy_extract_target ---
TMP_ET=$(mktemp -d); trap 'rm -rf "$TMP_ET" "${TMP_DETECT:-}"' EXIT

# Case 1: no header → empty + rc=0
echo "# Spec
no header here.

## Goal
foo
" > "$TMP_ET/no-header.md"
out=$(cw_deploy_extract_target "$TMP_ET/no-header.md") && rc=0 || rc=$?
[[ "$rc" -eq 0 ]] || { echo "FAIL: no-header should rc=0 (got $rc)" >&2; exit 1; }
[[ -z "$out" ]] || { echo "FAIL: no-header should print empty (got '$out')" >&2; exit 1; }
pass "extract_target returns empty + rc=0 when no header"

# Case 2: valid header → slug + rc=0
echo "# Spec

**Target Sub-Project:** ARS-Perfusion

## Goal
foo
" > "$TMP_ET/valid.md"
out=$(cw_deploy_extract_target "$TMP_ET/valid.md")
[[ "$out" == "ARS-Perfusion" ]] || { echo "FAIL: expected 'ARS-Perfusion' (got '$out')" >&2; exit 1; }
pass "extract_target returns slug for valid header"

# Case 3: malformed (slug with /) → rc=1
echo "# Spec

**Target Sub-Project:** ../escape

## Goal
foo
" > "$TMP_ET/malformed.md"
err=$(cw_deploy_extract_target "$TMP_ET/malformed.md" 2>&1) && rc=0 || rc=$?
[[ "$rc" -eq 1 ]] || { echo "FAIL: malformed slug should rc=1 (got $rc)" >&2; exit 1; }
echo "$err" | grep -qi 'invalid\|malformed\|slug' \
  || { echo "FAIL: malformed error message unclear: $err" >&2; exit 1; }
pass "extract_target rc=1 + clear error on malformed slug"

# Case 4: missing arg → rc=2
err=$(cw_deploy_extract_target 2>&1) && rc=0 || rc=$?
[[ "$rc" -eq 2 ]] || { echo "FAIL: no arg should rc=2 (got $rc)" >&2; exit 1; }
pass "extract_target rc=2 on missing arg"

# Case 5: tolerates leading whitespace + double space after colon
echo "# Spec

   **Target Sub-Project:**   web-frontend

## Goal
foo
" > "$TMP_ET/whitespace.md"
out=$(cw_deploy_extract_target "$TMP_ET/whitespace.md")
[[ "$out" == "web-frontend" ]] || { echo "FAIL: whitespace-tolerance failed (got '$out')" >&2; exit 1; }
pass "extract_target tolerates leading/trailing whitespace"

# --- cw_deploy_resolve_target ---
TMP_RT=$(mktemp -d); trap 'rm -rf "$TMP_RT" "$TMP_ET" "${TMP_DETECT:-}"' EXIT

# Build a hub-style fixture: hub/ has .git; hub/sub-a/ has .git; hub/sub-b/ exists but no .git.
mkdir -p "$TMP_RT/hub/.git" "$TMP_RT/hub/sub-a/.git" "$TMP_RT/hub/sub-b"

# Case 1: no header → returns conductor-cwd verbatim
echo "# spec, no header" > "$TMP_RT/no-header.md"
out=$(cw_deploy_resolve_target "$TMP_RT/no-header.md" "$TMP_RT/hub")
[[ "$out" == "$TMP_RT/hub" ]] || { echo "FAIL: no-header should return cwd verbatim (got '$out')" >&2; exit 1; }
pass "resolve_target returns cwd verbatim when no header"

# Case 2: header + valid sub-repo → returns sub-repo path
echo "# spec

**Target Sub-Project:** sub-a
" > "$TMP_RT/valid.md"
out=$(cw_deploy_resolve_target "$TMP_RT/valid.md" "$TMP_RT/hub")
[[ "$out" == "$TMP_RT/hub/sub-a" ]] || { echo "FAIL: valid header should return sub-repo path (got '$out')" >&2; exit 1; }
pass "resolve_target returns sub-repo path when header valid"

# Case 3: header + missing sub-repo → rc=1
echo "# spec

**Target Sub-Project:** sub-missing
" > "$TMP_RT/missing.md"
err=$(cw_deploy_resolve_target "$TMP_RT/missing.md" "$TMP_RT/hub" 2>&1) && rc=0 || rc=$?
[[ "$rc" -eq 1 ]] || { echo "FAIL: missing sub-repo should rc=1 (got $rc)" >&2; exit 1; }
echo "$err" | grep -qi 'not found\|missing' \
  || { echo "FAIL: missing-sub-repo error message unclear: $err" >&2; exit 1; }
pass "resolve_target rc=1 when sub-repo dir missing"

# Case 4: header + sub-repo dir exists but no .git → rc=1
echo "# spec

**Target Sub-Project:** sub-b
" > "$TMP_RT/no-git.md"
err=$(cw_deploy_resolve_target "$TMP_RT/no-git.md" "$TMP_RT/hub" 2>&1) && rc=0 || rc=$?
[[ "$rc" -eq 1 ]] || { echo "FAIL: no-.git sub-repo should rc=1 (got $rc)" >&2; exit 1; }
echo "$err" | grep -qi 'not a git repo' \
  || { echo "FAIL: no-.git error message unclear: $err" >&2; exit 1; }
pass "resolve_target rc=1 when sub-repo exists but not a git repo"

# --- audit gate target_subproject_when_invalid ---
TMP_AG=$(mktemp -d); trap 'rm -rf "$TMP_AG" "$TMP_RT" "$TMP_ET" "${TMP_DETECT:-}"' EXIT

# Case 1: invalid slug (path traversal) → audit RC=1 with the new ISSUE
cat > "$TMP_AG/invalid.md" <<'EOF'
# Spec

**Target Sub-Project:** ../escape

## Goal
foo
## Architecture
foo
## Testing
foo
## Success
foo
EOF
out=$(cw_deploy_audit_doc "$TMP_AG/invalid.md") && rc=0 || rc=$?
[[ "$rc" -eq 1 ]] || { echo "FAIL: invalid header should audit FAIL (got $rc)" >&2; exit 1; }
echo "$out" | grep -q 'ISSUE=target_subproject_when_invalid' \
  || { echo "FAIL: audit must emit target_subproject_when_invalid ISSUE; got: $out" >&2; exit 1; }
pass "audit emits target_subproject_when_invalid for malformed slug"

# Case 2: valid header → audit PASS
cat > "$TMP_AG/valid.md" <<'EOF'
# Spec

**Target Sub-Project:** ARS-Perfusion

## Goal
foo
## Architecture
foo
## Testing
foo
## Success
foo
EOF
out=$(cw_deploy_audit_doc "$TMP_AG/valid.md") && rc=0 || rc=$?
[[ "$rc" -eq 0 ]] || { echo "FAIL: valid header should PASS (got $rc; out: $out)" >&2; exit 1; }
pass "audit PASSes for valid Target Sub-Project header"

# Case 3: no header → audit PASS (single-repo case unchanged)
cat > "$TMP_AG/none.md" <<'EOF'
# Spec

## Goal
foo
## Architecture
foo
## Testing
foo
## Success
foo
EOF
out=$(cw_deploy_audit_doc "$TMP_AG/none.md") && rc=0 || rc=$?
[[ "$rc" -eq 0 ]] || { echo "FAIL: no-header should PASS (got $rc; out: $out)" >&2; exit 1; }
pass "audit PASSes when no Target Sub-Project header (single-repo case)"
