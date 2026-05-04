#!/usr/bin/env bash
# tests/test_deploy_init.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

# Resolve repo paths once so subshells/`bash -c` quoting can't lose them.
TESTS_DIR="$PWD"
REPO_ROOT="$(cd .. && pwd)"
BIN="$REPO_ROOT/bin/deploy-init.sh"
LIB_STATE="$REPO_ROOT/lib/state.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

# Stage a tmp git repo so branch creation works.
REPO="$TMP/repo"
mkdir -p "$REPO"
( cd "$REPO" && git init --quiet --initial-branch=main \
    && git config user.email t@t && git config user.name t \
    && echo seed > seed.txt && git add seed.txt && git commit --quiet -m init )

# Stage a sample design doc.
DDOC="$REPO/docs/superpowers/specs/2026-05-02-foo-bar-design.md"
mkdir -p "$(dirname "$DDOC")"
cat > "$DDOC" <<'MD'
# Foo
## Goal
Build foo.
## Architecture
Use bar.
## Testing strategy
Unit tests.
## Success criteria
1. tests pass
MD
( cd "$REPO" && git add . && git commit --quiet -m "spec: foo-bar" )

# 1. Happy path — derives slug, creates _deploy/, copies design.md, creates branch.
( cd "$REPO" && bash "$BIN" "$DDOC" ) > "$TMP/topic.txt" 2>"$TMP/err.log"
TOPIC=$(cat "$TMP/topic.txt" | tr -d '\r\n')
assert_eq "$TOPIC" "foo-bar" "init prints derived slug"
RH=$(bash -c "cd $REPO && source $LIB_STATE && cw_repo_hash")
ART="$CLONE_WARS_HOME/state/$RH/foo-bar/_deploy"
assert_file_exists "$ART/design.md" "design.md copied into _deploy/"
assert_file_exists "$ART/topic.txt" "topic.txt written"
got=$(cat "$ART/topic.txt"); assert_eq "$got" "foo-bar" "topic.txt content"
got=$( cd "$REPO" && git rev-parse --abbrev-ref HEAD )
assert_eq "$got" "feat/deploy-foo-bar" "branch created"
pass "init happy path"

# 2. --no-branch skips branch creation.
( cd "$REPO" && git checkout --quiet main && git branch -D feat/deploy-foo-bar >/dev/null )
rm -rf "$ART"
( cd "$REPO" && bash "$BIN" --no-branch "$DDOC" ) >/dev/null
got=$( cd "$REPO" && git rev-parse --abbrev-ref HEAD )
assert_eq "$got" "main" "no-branch keeps main"
pass "init --no-branch keeps current branch"

# 3. Refuses if design doc unreadable.
out=$( cd "$REPO" && bash "$BIN" "$REPO/no-such.md" 2>&1 ) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: missing design accepted" >&2; exit 1; }
pass "init refuses missing design"

# 4. --topic <slug> overrides derived slug.
rm -rf "$CLONE_WARS_HOME/state/$RH/explicit-slug"
( cd "$REPO" && git checkout --quiet main )
( cd "$REPO" && bash "$BIN" --no-branch --topic explicit-slug "$DDOC" ) > "$TMP/topic2.txt"
TOPIC2=$(cat "$TMP/topic2.txt" | tr -d '\r\n')
assert_eq "$TOPIC2" "explicit-slug" "--topic overrides"
assert_file_exists "$CLONE_WARS_HOME/state/$RH/explicit-slug/_deploy/design.md" "explicit slug got dir"
pass "init --topic override"

# 5. Refuses if topic dir already exists (no implicit overwrite).
out=$( cd "$REPO" && bash "$BIN" --no-branch --topic explicit-slug "$DDOC" 2>&1 ) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: dup topic accepted" >&2; exit 1; }
echo "$out" | grep -q 'already exists' || { echo "FAIL: error msg missing 'already exists': $out" >&2; exit 1; }
pass "init refuses duplicate topic"

# 6. --branch without an arg is rejected with exit 2 + clean error.
out=$( cd "$REPO" && bash "$BIN" --no-branch --branch 2>&1 ) && rc=0 || rc=$?
assert_eq "$rc" "2" "--branch without arg exits 2"
echo "$out" | grep -q '\-\-branch requires a value' \
  || { echo "FAIL: --branch error msg missing: $out" >&2; exit 1; }
pass "--branch requires a value"

# 7. --topic without an arg is rejected with exit 2 + clean error.
out=$( cd "$REPO" && bash "$BIN" --no-branch --topic 2>&1 ) && rc=0 || rc=$?
assert_eq "$rc" "2" "--topic without arg exits 2"
echo "$out" | grep -q '\-\-topic requires a value' \
  || { echo "FAIL: --topic error msg missing: $out" >&2; exit 1; }
pass "--topic requires a value"

# 8. Branch-creation failure auto-rollbacks _deploy/.
# Stage a dirty tree to make branch_create refuse, then confirm _deploy/ is gone after exit.
( cd "$REPO" && git checkout --quiet main && echo dirt > scratch.txt )   # dirty tree
( cd "$REPO" && bash "$BIN" --topic rollback-test "$DDOC" 2>"$TMP/rb.err" ) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: dirty-tree should refuse" >&2; exit 1; }
[[ ! -d "$CLONE_WARS_HOME/state/$RH/rollback-test/_deploy" ]] \
  || { echo "FAIL: _deploy/ not rolled back after branch failure" >&2; exit 1; }
pass "branch failure auto-rollbacks _deploy/"
( cd "$REPO" && rm -f scratch.txt )   # clean up the dirty marker

# 9. auto_provider.txt: codex case (no .claude-plugin/plugin.json at repo root).
TMP_AP_CODEX=$(mktemp -d)
export CLONE_WARS_HOME="$TMP_AP_CODEX/cw"
mkdir -p "$TMP_AP_CODEX/repo"
( cd "$TMP_AP_CODEX/repo" && git init --quiet --initial-branch=main \
    && git config user.email t@t && git config user.name t \
    && git commit --quiet --allow-empty -m init )
echo "# fake spec" > "$TMP_AP_CODEX/spec.md"
TOPIC_CODEX=$( cd "$TMP_AP_CODEX/repo" \
    && bash "$BIN" --no-branch --topic ap-codex "$TMP_AP_CODEX/spec.md" 2>/dev/null \
    | tail -1 )
RH_CODEX=$(bash -c "cd $TMP_AP_CODEX/repo && source $LIB_STATE && cw_repo_hash")
ART_CODEX="$CLONE_WARS_HOME/state/$RH_CODEX/$TOPIC_CODEX/_deploy"
assert_file_exists "$ART_CODEX/auto_provider.txt" "codex case writes auto_provider.txt"
got=$(cat "$ART_CODEX/auto_provider.txt")
assert_eq "$got" "codex" "codex case auto_provider.txt content"
pass "deploy-init writes auto_provider.txt=codex when no .claude-plugin/plugin.json"
rm -rf "$TMP_AP_CODEX"

# 10. auto_provider.txt: claude case (.claude-plugin/plugin.json present).
TMP_AP_CLAUDE=$(mktemp -d)
export CLONE_WARS_HOME="$TMP_AP_CLAUDE/cw"
mkdir -p "$TMP_AP_CLAUDE/repo/.claude-plugin"
touch "$TMP_AP_CLAUDE/repo/.claude-plugin/plugin.json"
( cd "$TMP_AP_CLAUDE/repo" && git init --quiet --initial-branch=main \
    && git config user.email t@t && git config user.name t \
    && git add .claude-plugin/plugin.json \
    && git commit --quiet -m init )
echo "# fake spec" > "$TMP_AP_CLAUDE/spec.md"
TOPIC_CLAUDE=$( cd "$TMP_AP_CLAUDE/repo" \
    && bash "$BIN" --no-branch --topic ap-claude "$TMP_AP_CLAUDE/spec.md" 2>/dev/null \
    | tail -1 )
RH_CLAUDE=$(bash -c "cd $TMP_AP_CLAUDE/repo && source $LIB_STATE && cw_repo_hash")
ART_CLAUDE="$CLONE_WARS_HOME/state/$RH_CLAUDE/$TOPIC_CLAUDE/_deploy"
assert_file_exists "$ART_CLAUDE/auto_provider.txt" "claude case writes auto_provider.txt"
got=$(cat "$ART_CLAUDE/auto_provider.txt")
assert_eq "$got" "claude" "claude case auto_provider.txt content"
pass "deploy-init writes auto_provider.txt=claude when .claude-plugin/plugin.json present"
rm -rf "$TMP_AP_CLAUDE"

# --- v0.10: sub-repo redirect ---
TMP_HUB=$(mktemp -d)
trap 'rm -rf "$TMP_HUB" "${TMP_AP_CODEX:-}" "${TMP_AP_CLAUDE:-}"' EXIT
export CLONE_WARS_HOME="$TMP_HUB/cw"

# Build hub fixture: hub/ has .git; hub/sub-a/ has .git + .claude-plugin/plugin.json (forces claude detect).
mkdir -p "$TMP_HUB/hub/sub-a/.claude-plugin"
touch "$TMP_HUB/hub/sub-a/.claude-plugin/plugin.json"
( cd "$TMP_HUB/hub" && git init -q . && git config user.email t@t && git config user.name t \
    && git commit -q --allow-empty -m hub-init )
( cd "$TMP_HUB/hub/sub-a" && git init -q . && git config user.email t@t && git config user.name t \
    && git commit -q --allow-empty -m sub-init )

cat > "$TMP_HUB/spec.md" <<'EOF'
# Hub Spec

**Target Sub-Project:** sub-a

## Goal
foo
## Architecture
foo
## Testing
foo
## Success
foo
EOF

BIN_INIT="$(cd .. && pwd)/bin/deploy-init.sh"
TOPIC=$( cd "$TMP_HUB/hub" && bash "$BIN_INIT" --no-branch --topic v10-redirect "$TMP_HUB/spec.md" 2>/dev/null | tail -1 )
[[ -n "$TOPIC" ]] || { echo "FAIL: deploy-init produced no topic" >&2; exit 1; }

SUB_HASH=$(bash -c 'source ../lib/state.sh; cw_repo_hash_for "'"$TMP_HUB/hub/sub-a"'"')
ART="$CLONE_WARS_HOME/state/$SUB_HASH/$TOPIC/_deploy"
[[ -f "$ART/target_cwd.txt" ]] \
  || { echo "FAIL: hub case missing target_cwd.txt at $ART" >&2; exit 1; }
[[ "$(cat "$ART/target_cwd.txt")" == "$TMP_HUB/hub/sub-a" ]] \
  || { echo "FAIL: target_cwd.txt should be sub-a path (got '$(cat "$ART/target_cwd.txt")')" >&2; exit 1; }
[[ "$(cat "$ART/auto_provider.txt")" == "claude" ]] \
  || { echo "FAIL: auto_provider should be 'claude' (sub-repo has plugin.json); got '$(cat "$ART/auto_provider.txt")'" >&2; exit 1; }
pass "deploy-init redirects state + provider into sub-repo when header present"

# Case 2: header points at missing sub-repo → rc!=0 + auto-rollback
cat > "$TMP_HUB/spec-bad.md" <<'EOF'
# Hub Spec

**Target Sub-Project:** sub-missing

## Goal
foo
## Architecture
foo
## Testing
foo
## Success
foo
EOF

err=$( cd "$TMP_HUB/hub" && bash "$BIN_INIT" --no-branch --topic v10-bad "$TMP_HUB/spec-bad.md" 2>&1 ) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: missing sub-repo should rc!=0 (got $rc; out: $err)" >&2; exit 1; }
echo "$err" | grep -qi 'not found\|missing' \
  || { echo "FAIL: missing-sub-repo error message unclear: $err" >&2; exit 1; }
# Auto-rollback: ART_DIR should NOT exist after the failure.
ART_BAD="$CLONE_WARS_HOME/state/$SUB_HASH/v10-bad/_deploy"
[[ ! -d "$ART_BAD" ]] || { echo "FAIL: missing-sub-repo case left orphan ART_DIR at $ART_BAD" >&2; exit 1; }
pass "deploy-init rejects + auto-rollbacks when header points at missing sub-repo"

# v0.10 integration: the path init writes to MUST match what downstream bin scripts
# resolve via cw_deploy_art_dir + CW_TOPIC_REPO_CWD env var.
# This catches the class of bug where init writes under SUB-hash but turn-send/archive
# read under HUB-hash.
TMP_INT=$(mktemp -d)
trap 'rm -rf "$TMP_INT" "$TMP_HUB" "${TMP_AP_CODEX:-}" "${TMP_AP_CLAUDE:-}"' EXIT
export CLONE_WARS_HOME="$TMP_INT/cw"
mkdir -p "$TMP_INT/hub/sub-x/.claude-plugin"
touch "$TMP_INT/hub/sub-x/.claude-plugin/plugin.json"
( cd "$TMP_INT/hub" && git init -q . && git config user.email t@t && git config user.name t \
    && git commit -q --allow-empty -m hub-init )
( cd "$TMP_INT/hub/sub-x" && git init -q . && git config user.email t@t && git config user.name t \
    && git commit -q --allow-empty -m sub-init )

cat > "$TMP_INT/spec.md" <<'EOF'
# Hub Spec
**Target Sub-Project:** sub-x
## Goal
foo
## Architecture
foo
## Testing
foo
## Success
foo
EOF

BIN_INIT="$(cd .. && pwd)/bin/deploy-init.sh"
TOPIC=$( cd "$TMP_INT/hub" && bash "$BIN_INIT" --no-branch --topic v10-int "$TMP_INT/spec.md" 2>/dev/null | tail -1 )

# Now simulate what downstream scripts do — set CW_TOPIC_REPO_CWD and resolve via cw_deploy_art_dir.
# Use absolute paths to lib/ so the subshell cwd doesn't matter.
LIB_STATE_ABS="$REPO_ROOT/lib/state.sh"
LIB_LOG_ABS="$REPO_ROOT/lib/log.sh"
LIB_DEPLOY_ABS="$REPO_ROOT/lib/deploy.sh"
DOWNSTREAM_ART=$(
  cd "$TMP_INT/hub" \
    && CW_TOPIC_REPO_CWD="$TMP_INT/hub/sub-x" \
       bash -c "source '$LIB_STATE_ABS'; source '$LIB_LOG_ABS'; source '$LIB_DEPLOY_ABS'; cw_deploy_art_dir \"\$1\"" _ "$TOPIC"
)
SUB_HASH=$(bash -c "source '$LIB_STATE_ABS'; cw_repo_hash_for '$TMP_INT/hub/sub-x'")
INIT_ART="$CLONE_WARS_HOME/state/$SUB_HASH/$TOPIC/_deploy"
[[ "$DOWNSTREAM_ART" == "$INIT_ART" ]] \
  || { echo "FAIL: downstream cw_deploy_art_dir ($DOWNSTREAM_ART) must equal init's ART_DIR ($INIT_ART)" >&2; exit 1; }
[[ -d "$DOWNSTREAM_ART" ]] \
  || { echo "FAIL: downstream-resolved ART_DIR ($DOWNSTREAM_ART) doesn't exist (init didn't write there)" >&2; exit 1; }
pass "init ART_DIR matches downstream cw_deploy_art_dir resolution under CW_TOPIC_REPO_CWD"
