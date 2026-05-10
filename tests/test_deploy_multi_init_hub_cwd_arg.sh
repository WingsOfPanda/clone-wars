#!/usr/bin/env bash
# tests/test_deploy_multi_init_hub_cwd_arg.sh
# Verifies bin/deploy-multi-init.sh accepts an optional <hub-cwd> 2nd
# arg and uses it for sub-repo lookup instead of $PWD.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
SANDBOX=$(mktemp -d)
HUB_DIR=$(mktemp -d)
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
export CLONE_WARS_HOME="$SANDBOX/.clone-wars"
mkdir -p "$CLONE_WARS_HOME"
trap 'rm -rf "$SANDBOX" "$HUB_DIR"' EXIT

source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deploy.sh"

TOPIC="dpl-mi-hub-$$"
REPO_HASH=$(cd "$HUB_DIR" && cw_repo_hash)
ART_DIR="$CLONE_WARS_HOME/state/$REPO_HASH/$TOPIC/_deploy"
mkdir -p "$ART_DIR"

mkdir -p "$HUB_DIR/auth" "$HUB_DIR/api"
echo "# auth" > "$HUB_DIR/auth/CLAUDE.md"
echo "# api"  > "$HUB_DIR/api/CLAUDE.md"
( cd "$HUB_DIR/auth" && git init -q && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m "init" )
( cd "$HUB_DIR/api"  && git init -q && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m "init" )

cat > "$ART_DIR/dag-waves.txt" <<EOF
1	1	auth	none	x
2	2	api	none	y
EOF

# Invoke from SANDBOX (conductor's $PWD), passing HUB_DIR as 2nd arg.
# Set CW_TOPIC_REPO_CWD=$HUB_DIR so cw_deploy_art_dir resolves the
# topic-state path against HUB_DIR's repo-hash (matching what the test
# pre-populated above). bin/deploy-init.sh sets this env var in the
# real flow before invoking multi-init.
( cd "$SANDBOX" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLONE_WARS_HOME="$CLONE_WARS_HOME" \
  CW_TOPIC_REPO_CWD="$HUB_DIR" \
  "$PLUGIN_ROOT/bin/deploy-multi-init.sh" "$TOPIC" "$HUB_DIR" )

mapfile -t LINES < "$ART_DIR/troopers.txt"
[[ ${#LINES[@]} -eq 2 ]] || { echo "FAIL: expected 2 trooper rows" >&2; exit 1; }
[[ "${LINES[0]}" == "rex"$'\t'"$HUB_DIR/auth"$'\t'"codex" ]] || { echo "FAIL: auth not under HUB_DIR: ${LINES[0]}" >&2; exit 1; }
[[ "${LINES[1]}" == "wolffe"$'\t'"$HUB_DIR/api"$'\t'"codex" ]] || { echo "FAIL: api not under HUB_DIR: ${LINES[1]}" >&2; exit 1; }

pass "deploy-multi-init: <hub-cwd> 2nd arg routes sub-repo lookup correctly"
