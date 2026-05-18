#!/usr/bin/env bash
# tests/test_deploy_pre_snapshot_hook_blocked.sh
# v0.42.0: pre-commit hook exits 1 → state=hook-blocked, baseline.sha=pre-attempt HEAD, no abort.
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
echo modified >> seed.txt
# Install blocking pre-commit hook
cat > .git/hooks/pre-commit <<'EOF'
#!/bin/sh
echo "pre-commit blocked by test hook" >&2
exit 1
EOF
chmod +x .git/hooks/pre-commit

BASELINE="$SANDBOX/baseline.tsv"
set +e
cw_deploy_pre_snapshot "$SANDBOX" demo-topic main "$BASELINE"; rc=$?
set -e
[[ "$rc" -eq 0 ]] || { echo "FAIL: hook-blocked should still rc=0 (warn + proceed); got $rc" >&2; exit 1; }
grep -qE '^state=hook-blocked$' "$BASELINE" || { echo "FAIL: state not 'hook-blocked'" >&2; cat "$BASELINE" >&2; exit 1; }
grep -qE "^baseline_sha=$PRE_SHA$" "$BASELINE" || { echo "FAIL: baseline_sha should be pre-attempt HEAD" >&2; cat "$BASELINE" >&2; exit 1; }
POST_SHA=$(git rev-parse HEAD)
assert_eq "$POST_SHA" "$PRE_SHA" "HEAD did not advance after blocked commit"
pass "1. hook-blocked: pre_snapshot rc=0, state=hook-blocked, baseline=pre-HEAD"

echo "test_deploy_pre_snapshot_hook_blocked: 1 case passed"
