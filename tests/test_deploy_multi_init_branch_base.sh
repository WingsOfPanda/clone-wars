#!/usr/bin/env bash
# tests/test_deploy_multi_init_branch_base.sh
# Verifies bin/deploy-multi-init.sh writes per-cmdr <cmdr>-branch-base.sha
# files for each sub-repo (capturing pristine baseline before any spawn).
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

TOPIC="dpl-mi-bb-$$"
REPO_HASH=$(cd "$SANDBOX" && cw_repo_hash)
ART_DIR="$CLONE_WARS_HOME/state/$REPO_HASH/$TOPIC/_deploy"
mkdir -p "$ART_DIR"

for repo in auth api ui; do
  mkdir -p "$SANDBOX/$repo"
  echo "# $repo" > "$SANDBOX/$repo/CLAUDE.md"
  ( cd "$SANDBOX/$repo" && git init -q && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m "init" )
done

cat > "$ART_DIR/dag-waves.txt" <<EOF
1	1	auth	none	x
1	2	api	none	y
2	3	ui	none	z
EOF

( cd "$SANDBOX" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLONE_WARS_HOME="$CLONE_WARS_HOME" \
  "$PLUGIN_ROOT/bin/deploy-multi-init.sh" "$TOPIC" )

# pool order: rex, cody, wolffe, bly — codex skips cody → rex, wolffe, bly
for cmdr in rex wolffe bly; do
  BB="$ART_DIR/$cmdr-branch-base.sha"
  assert_file_exists "$BB" "$cmdr-branch-base.sha exists"
  sha=$(cat "$BB")
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "FAIL: $cmdr-branch-base.sha not a valid SHA1: $sha" >&2; exit 1; }
done

pass "deploy-multi-init: per-cmdr <cmdr>-branch-base.sha files written with valid SHA1s"
