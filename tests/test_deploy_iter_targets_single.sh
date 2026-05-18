#!/usr/bin/env bash
# tests/test_deploy_iter_targets_single.sh
# v0.42.0: single-repo deploy synthesizes one row 'main\t<target_cwd>'.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deploy.sh"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
cd "$SANDBOX"
git init -q
git config user.email t@t; git config user.name T
echo content > seed.txt; git add seed.txt; git commit -qm seed
export CLONE_WARS_HOME="$SANDBOX/.clone-wars"

TOPIC=iter-single
ART_DIR=$(cw_deploy_art_dir "$TOPIC")
mkdir -p "$ART_DIR"
printf '%s\n' "$SANDBOX" > "$ART_DIR/target_cwd.txt"

OUT=$(cw_deploy_iter_targets "$TOPIC")
EXPECTED=$(printf 'main\t%s' "$SANDBOX")
assert_eq "$OUT" "$EXPECTED" "single-repo emits one row 'main\\t<cwd>'"
pass "1. single-repo iter_targets emits 'main\\t<target_cwd>'"

echo "test_deploy_iter_targets_single: 1 case passed"
