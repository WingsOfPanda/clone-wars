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
