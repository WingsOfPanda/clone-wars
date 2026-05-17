#!/usr/bin/env bash
# tests/test_deploy_pre_snapshot_clean.sh
# v0.42.0: clean tree → no commit, state=clean, baseline.sha = current HEAD.
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
assert_file_exists "$BASELINE" "baseline file written"
grep -qE '^state=clean$'           "$BASELINE" || { echo "FAIL: state not 'clean'" >&2; cat "$BASELINE" >&2; exit 1; }
grep -qE "^baseline_sha=$PRE_SHA$"  "$BASELINE" || { echo "FAIL: baseline_sha != PRE_SHA" >&2; cat "$BASELINE" >&2; exit 1; }
POST_SHA=$(git rev-parse HEAD)
assert_eq "$POST_SHA" "$PRE_SHA" "no commit added on clean tree"
pass "1. clean tree: pre_snapshot writes state=clean, baseline=HEAD, no commit"

echo "test_deploy_pre_snapshot_clean: 1 case passed"
