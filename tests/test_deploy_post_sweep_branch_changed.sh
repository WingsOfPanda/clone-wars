#!/usr/bin/env bash
# tests/test_deploy_post_sweep_branch_changed.sh
# v0.42.0: branch differs at sweep time → branch_changed=true (WARNING in summary).
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
git init -q -b main
git config user.email t@t; git config user.name T
echo c > seed.txt; git add seed.txt; git commit -qm seed

BASELINE="$SANDBOX/baseline.tsv"
cw_deploy_pre_snapshot "$SANDBOX" demo-topic main "$BASELINE"
# Simulate a trooper violating branch discipline
git checkout -q -b rogue-branch

POST="$SANDBOX/post.tsv"
cw_deploy_post_sweep "$BASELINE" demo-topic "$POST"
grep -qE '^branch_changed=true$' "$POST" || { echo "FAIL: branch_changed not 'true'" >&2; cat "$POST" >&2; exit 1; }
grep -qE '^branch=rogue-branch$' "$POST" || { echo "FAIL: post branch not 'rogue-branch'" >&2; cat "$POST" >&2; exit 1; }
pass "1. branch changed: post_sweep records branch_changed=true and new branch name"

echo "test_deploy_post_sweep_branch_changed: 1 case passed"
