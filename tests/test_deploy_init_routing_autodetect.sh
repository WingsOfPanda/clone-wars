#!/usr/bin/env bash
# tests/test_deploy_init_routing_autodetect.sh
# Verifies bin/deploy-init.sh writes _deploy/<topic>/routing.txt with
# 'single-repo' or 'multi-repo' based on design-doc header form.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
SANDBOX=$(mktemp -d)
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
export CLONE_WARS_HOME="$SANDBOX/.clone-wars"
mkdir -p "$CLONE_WARS_HOME"
trap 'rm -rf "$SANDBOX"' EXIT

# Synthesize a minimal git repo so cw_deploy_branch_create has something to act on
GIT_DIR="$SANDBOX/repo"
mkdir -p "$GIT_DIR"
( cd "$GIT_DIR" && git init -q && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m "init" )

# Test A: single-repo design doc → routing.txt = single-repo
DOC_S="$GIT_DIR/2026-05-09-singlerepo-design.md"
cat > "$DOC_S" <<'EOF'
# Single

## Goal
Do a thing.

## Architecture
Approach: do it.

## Testing
Run tests.

## Success Criteria
- [ ] Tests pass.
EOF
( cd "$GIT_DIR" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLONE_WARS_HOME="$CLONE_WARS_HOME" \
  "$PLUGIN_ROOT/bin/deploy-init.sh" --no-branch --topic singlerepotest "$DOC_S" )

source "$PLUGIN_ROOT/lib/state.sh"
REPO_HASH=$(cd "$GIT_DIR" && cw_repo_hash)
ART_S="$CLONE_WARS_HOME/state/$REPO_HASH/singlerepotest/_deploy"
assert_file_exists "$ART_S/routing.txt" "single-repo: routing.txt written"
routing=$(cat "$ART_S/routing.txt")
assert_eq "$routing" "single-repo" "single-repo: routing = single-repo"

# Test B: multi-repo design doc → routing.txt = multi-repo
DOC_M="$GIT_DIR/2026-05-09-multirepo-design.md"
cat > "$DOC_M" <<'EOF'
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
( cd "$GIT_DIR" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLONE_WARS_HOME="$CLONE_WARS_HOME" \
  "$PLUGIN_ROOT/bin/deploy-init.sh" --no-branch --topic multirepotest "$DOC_M" )

ART_M="$CLONE_WARS_HOME/state/$REPO_HASH/multirepotest/_deploy"
assert_file_exists "$ART_M/routing.txt" "multi-repo: routing.txt written"
routing=$(cat "$ART_M/routing.txt")
assert_eq "$routing" "multi-repo" "multi-repo: routing = multi-repo"

pass "deploy-init routing auto-detect: single + multi both correct"
