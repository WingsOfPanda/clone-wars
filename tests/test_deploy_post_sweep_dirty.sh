#!/usr/bin/env bash
# tests/test_deploy_post_sweep_dirty.sh
# v0.42.0: post-deploy leftover files → commit + state=swept.
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

BASELINE="$SANDBOX/baseline.tsv"
cw_deploy_pre_snapshot "$SANDBOX" demo-topic main "$BASELINE"
BASE_SHA=$(git rev-parse HEAD)

# Simulate a trooper leaving leftover work uncommitted
echo trooper-leftover > leftover.txt

POST="$SANDBOX/post.tsv"
cw_deploy_post_sweep "$BASELINE" demo-topic "$POST"
grep -qE '^state=swept$' "$POST" || { echo "FAIL: state not 'swept'" >&2; cat "$POST" >&2; exit 1; }
NEW_SHA=$(git rev-parse HEAD)
[[ "$NEW_SHA" != "$BASE_SHA" ]] || { echo "FAIL: sweep should have committed leftover" >&2; exit 1; }
MSG=$(git log -1 --format=%s)
assert_eq "$MSG" "chore: post-deploy leftovers for demo-topic" "sweep commit message"
pass "1. dirty post-deploy: post_sweep commits leftover + state=swept"

echo "test_deploy_post_sweep_dirty: 1 case passed"
