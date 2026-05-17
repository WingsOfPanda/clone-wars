#!/usr/bin/env bash
# tests/test_deploy_pre_snapshot_dirty.sh
# v0.42.0: modified tracked file → commit + state=wip-committed.
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
echo modified >> seed.txt   # dirty (modified tracked file)

BASELINE="$SANDBOX/baseline.tsv"
cw_deploy_pre_snapshot "$SANDBOX" demo-topic main "$BASELINE"
assert_file_exists "$BASELINE"
grep -qE '^state=wip-committed$' "$BASELINE" || { echo "FAIL: state not 'wip-committed'" >&2; cat "$BASELINE" >&2; exit 1; }
NEW_SHA=$(git rev-parse HEAD)
[[ "$NEW_SHA" != "$PRE_SHA" ]] || { echo "FAIL: HEAD did not advance" >&2; exit 1; }
grep -qE "^baseline_sha=$NEW_SHA$" "$BASELINE" || { echo "FAIL: baseline_sha != new HEAD" >&2; exit 1; }
MSG=$(git log -1 --format=%s)
assert_eq "$MSG" "chore: WIP before deploy demo-topic" "commit message matches spec"
pass "1. dirty tree: pre_snapshot commits + state=wip-committed"

echo "test_deploy_pre_snapshot_dirty: 1 case passed"
