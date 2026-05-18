#!/usr/bin/env bash
# tests/test_deploy_pre_snapshot_not_a_repo.sh
# v0.42.0: target dir without .git → rc=2 abort with explicit error.
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
# Not a git repo (no git init)

BASELINE="$SANDBOX/baseline.tsv"
set +e
out=$(cw_deploy_pre_snapshot "$SANDBOX" demo-topic main "$BASELINE" 2>&1); rc=$?
set -e
[[ "$rc" -eq 2 ]] || { echo "FAIL: not-a-repo should rc=2; got $rc" >&2; echo "$out" >&2; exit 1; }
assert_contains "$out" "not a git repository" "error message names the failure"
[[ ! -e "$BASELINE" ]] || { echo "FAIL: baseline file should NOT exist on rc=2" >&2; exit 1; }
pass "1. not-a-repo: pre_snapshot rc=2, no baseline file written"

echo "test_deploy_pre_snapshot_not_a_repo: 1 case passed"
