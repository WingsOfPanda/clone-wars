#!/usr/bin/env bash
# tests/test_deploy_pre_snapshot_detached.sh
# v0.42.0: detached HEAD → state captured normally, branch=(detached), no abort.
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
echo c2 > seed2.txt; git add seed2.txt; git commit -qm seed2
git checkout -q HEAD~1   # detached HEAD

BASELINE="$SANDBOX/baseline.tsv"
set +e
cw_deploy_pre_snapshot "$SANDBOX" demo-topic main "$BASELINE"; rc=$?
set -e
[[ "$rc" -eq 0 ]] || { echo "FAIL: detached HEAD should warn + proceed; got rc=$rc" >&2; exit 1; }
grep -qE '^branch=\(detached\)$' "$BASELINE" || { echo "FAIL: branch field not '(detached)'" >&2; cat "$BASELINE" >&2; exit 1; }
pass "1. detached HEAD: pre_snapshot rc=0, branch=(detached)"

echo "test_deploy_pre_snapshot_detached: 1 case passed"
