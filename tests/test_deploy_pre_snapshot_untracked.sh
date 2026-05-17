#!/usr/bin/env bash
# tests/test_deploy_pre_snapshot_untracked.sh
# v0.42.0: only untracked files (no modified tracked files) → still committed.
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
echo new > untracked.txt   # untracked only

BASELINE="$SANDBOX/baseline.tsv"
cw_deploy_pre_snapshot "$SANDBOX" demo-topic main "$BASELINE"
grep -qE '^state=wip-committed$' "$BASELINE" || { echo "FAIL: untracked-only should commit" >&2; cat "$BASELINE" >&2; exit 1; }
NEW_SHA=$(git rev-parse HEAD)
[[ "$NEW_SHA" != "$PRE_SHA" ]] || { echo "FAIL: HEAD did not advance for untracked-only" >&2; exit 1; }
git ls-files --others --exclude-standard | grep -q '^untracked\.txt$' \
  && { echo "FAIL: untracked.txt should now be tracked" >&2; exit 1; }
pass "1. untracked-only: pre_snapshot commits + state=wip-committed"

echo "test_deploy_pre_snapshot_untracked: 1 case passed"
