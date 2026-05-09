#!/usr/bin/env bash
# tests/test_deploy_multi_init.sh
# Tests bin/deploy-multi-init.sh — commander assignment + per-repo provider.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
SANDBOX=$(mktemp -d)
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
export CLONE_WARS_HOME="$SANDBOX/.clone-wars"
mkdir -p "$CLONE_WARS_HOME"
trap 'rm -rf "$SANDBOX"' EXIT

source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deploy.sh"

# --- Test A: 3 codex sub-repos, deterministic assignment, cody skipped
# Note: cw_repo_hash hashes $PWD; the script runs with `cd $SANDBOX`, so
# REPO_HASH must be computed from $SANDBOX (not the test's cwd).
TOPIC="cmi-a-$$"
REPO_HASH=$(cd "$SANDBOX" && cw_repo_hash)
ART_DIR="$CLONE_WARS_HOME/state/$REPO_HASH/$TOPIC/_deploy"
mkdir -p "$ART_DIR"

mkdir -p "$SANDBOX/auth" "$SANDBOX/api" "$SANDBOX/ui"
echo "# auth" > "$SANDBOX/auth/CLAUDE.md"
echo "# api"  > "$SANDBOX/api/CLAUDE.md"
echo "# ui"   > "$SANDBOX/ui/CLAUDE.md"
# v0.20.1: multi-init now captures per-cmdr branch-base.sha via git
# rev-parse HEAD on each sub-repo. Initialize git repos so the capture
# step has something to read.
for r in auth api ui; do
  ( cd "$SANDBOX/$r" && git init -q && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m "init" )
done

cat > "$ART_DIR/dag-waves.txt" <<EOF
1	1	auth	set up auth
2	2	api	build api
3	3	ui	wire frontend
EOF

( cd "$SANDBOX" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLONE_WARS_HOME="$CLONE_WARS_HOME" \
  "$PLUGIN_ROOT/bin/deploy-multi-init.sh" "$TOPIC" )

assert_file_exists "$ART_DIR/troopers.txt" "troopers.txt written"
mapfile -t LINES < "$ART_DIR/troopers.txt"
[[ ${#LINES[@]} -eq 3 ]] || { echo "FAIL: expected 3 trooper rows (got ${#LINES[@]})" >&2; exit 1; }
# pool order: rex, cody, wolffe, bly, ... ; cody is skipped for codex; so:
# auth → rex, api → wolffe, ui → bly
assert_eq "${LINES[0]}" "rex	$SANDBOX/auth	codex" "first commander = rex"
assert_eq "${LINES[1]}" "wolffe	$SANDBOX/api	codex" "second commander = wolffe (cody skipped)"
assert_eq "${LINES[2]}" "bly	$SANDBOX/ui	codex" "third commander = bly"
pass "deploy-multi-init: deterministic codex assignment + cody skip"

# --- Test B: plugin sub-repo → cody/claude
TOPIC2="cmi-b-$$"
# REPO_HASH already computed from $SANDBOX above; reuse.
ART2="$CLONE_WARS_HOME/state/$REPO_HASH/$TOPIC2/_deploy"
mkdir -p "$ART2"
mkdir -p "$SANDBOX/lib-a" "$SANDBOX/lib-b/.claude-plugin"
echo "# a" > "$SANDBOX/lib-a/CLAUDE.md"
echo "# b" > "$SANDBOX/lib-b/CLAUDE.md"
echo '{}' > "$SANDBOX/lib-b/.claude-plugin/plugin.json"
# v0.20.1: branch-base capture requires git repos in each sub-repo.
for r in lib-a lib-b; do
  ( cd "$SANDBOX/$r" && git init -q && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m "init" )
done
cat > "$ART2/dag-waves.txt" <<EOF
1	1	lib-a	x
1	2	lib-b	y
EOF
( cd "$SANDBOX" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLONE_WARS_HOME="$CLONE_WARS_HOME" \
  "$PLUGIN_ROOT/bin/deploy-multi-init.sh" "$TOPIC2" )
mapfile -t LINES2 < "$ART2/troopers.txt"
assert_eq "${LINES2[0]}" "rex	$SANDBOX/lib-a	codex" "lib-a → codex/rex"
assert_eq "${LINES2[1]}" "cody	$SANDBOX/lib-b	claude" "lib-b → cody/claude (plugin)"
pass "deploy-multi-init: plugin sub-repo → cody/claude"

# --- Test C: missing sub-repo → rc=1
TOPIC3="cmi-c-$$"
ART3="$CLONE_WARS_HOME/state/$REPO_HASH/$TOPIC3/_deploy"
mkdir -p "$ART3"
cat > "$ART3/dag-waves.txt" <<EOF
1	1	does-not-exist	x
EOF
err=$( cd "$SANDBOX" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLONE_WARS_HOME="$CLONE_WARS_HOME" \
  "$PLUGIN_ROOT/bin/deploy-multi-init.sh" "$TOPIC3" 2>&1 ) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: missing sub-repo should rc!=0" >&2; exit 1; }
echo "$err" | grep -qi 'not found\|does not exist' || { echo "FAIL: error msg unclear: $err" >&2; exit 1; }
pass "deploy-multi-init: missing sub-repo rejects"
