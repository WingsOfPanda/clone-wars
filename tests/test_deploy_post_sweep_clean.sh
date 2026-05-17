#!/usr/bin/env bash
# tests/test_deploy_post_sweep_clean.sh
# v0.42.0: post-deploy clean tree → state=no-leftovers, no commit, no branch_changed.
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
echo c > seed.txt; git add seed.txt; git commit -qm seed
PRE_SHA=$(git rev-parse HEAD)

BASELINE="$SANDBOX/baseline.tsv"
cw_deploy_pre_snapshot "$SANDBOX" demo-topic main "$BASELINE"

POST="$SANDBOX/post.tsv"
cw_deploy_post_sweep "$BASELINE" demo-topic "$POST"
assert_file_exists "$POST"
grep -qE '^state=no-leftovers$' "$POST" || { echo "FAIL: state not 'no-leftovers'" >&2; cat "$POST" >&2; exit 1; }
grep -qE '^branch_changed=false$' "$POST" || { echo "FAIL: branch_changed not false" >&2; cat "$POST" >&2; exit 1; }
POST_SHA=$(git rev-parse HEAD)
assert_eq "$POST_SHA" "$PRE_SHA" "no commit added on clean post-deploy"
pass "1. clean post-deploy: post_sweep writes state=no-leftovers, branch_changed=false"

echo "test_deploy_post_sweep_clean: 1 case passed"
