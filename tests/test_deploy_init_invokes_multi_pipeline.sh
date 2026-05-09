#!/usr/bin/env bash
# tests/test_deploy_init_invokes_multi_pipeline.sh
# Verifies bin/deploy-init.sh invokes deploy-dag-parse.sh +
# deploy-multi-init.sh when the design doc routes to multi-repo.
# Asserts post-conditions: dag-waves.txt, dag-edges.txt, troopers.txt,
# per-cmdr branch-base.sha files all exist after init.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
SANDBOX=$(mktemp -d)
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
export CLONE_WARS_HOME="$SANDBOX/.clone-wars"
mkdir -p "$CLONE_WARS_HOME"
trap 'rm -rf "$SANDBOX"' EXIT

# Hub repo + 2 sub-repos
HUB="$SANDBOX/hub"
mkdir -p "$HUB"
( cd "$HUB" && git init -q && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m "init" )

for repo in auth api; do
  mkdir -p "$HUB/$repo"
  echo "# $repo" > "$HUB/$repo/CLAUDE.md"
  ( cd "$HUB/$repo" && git init -q && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m "init" )
done

DOC="$HUB/2026-05-09-multi-design.md"
cat > "$DOC" <<'EOF'
# Multi

**Target Sub-Project(s):** auth, api

## Goal
Do many things.

## Architecture
Approach.

## Execution DAG

1. auth — first
2. api — second (depends on 1)

## Testing
Tests.

## Success Criteria
- [ ] Done.
EOF

source "$PLUGIN_ROOT/lib/state.sh"

( cd "$HUB" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLONE_WARS_HOME="$CLONE_WARS_HOME" \
  "$PLUGIN_ROOT/bin/deploy-init.sh" --no-branch --topic mwiretest "$DOC" )

REPO_HASH=$(cd "$HUB" && cw_repo_hash)
ART="$CLONE_WARS_HOME/state/$REPO_HASH/mwiretest/_deploy"

routing=$(cat "$ART/routing.txt")
assert_eq "$routing" "multi-repo" "routing.txt = multi-repo"

assert_file_exists "$ART/dag-waves.txt" "dag-waves.txt written by init"
assert_file_exists "$ART/dag-edges.txt" "dag-edges.txt written by init"
assert_file_exists "$ART/troopers.txt"  "troopers.txt written by init"
assert_file_exists "$ART/rex-branch-base.sha"     "rex-branch-base.sha written"
assert_file_exists "$ART/wolffe-branch-base.sha"  "wolffe-branch-base.sha written"

mapfile -t WAVES < "$ART/dag-waves.txt"
[[ "${WAVES[0]}" == 1$'\t'1$'\t'auth* ]] || { echo "FAIL: dag-waves[0] not auth wave 1: ${WAVES[0]}" >&2; exit 1; }
[[ "${WAVES[1]}" == 2$'\t'2$'\t'api* ]]  || { echo "FAIL: dag-waves[1] not api wave 2: ${WAVES[1]}" >&2; exit 1; }

pass "deploy-init invokes deploy-dag-parse + deploy-multi-init for multi-repo doc"
