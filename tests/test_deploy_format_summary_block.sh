#!/usr/bin/env bash
# tests/test_deploy_format_summary_block.sh
# v0.42.0: format_summary_block prints the documented per-repo block from baseline+post TSVs.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deploy.sh"

# Build a real sandbox repo so the commits/diff lines have real SHAs.
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
cd "$SANDBOX"
git init -q -b main
git config user.email t@t; git config user.name T
echo c > seed.txt; git add seed.txt; git commit -qm seed
BASE_SHA=$(git rev-parse HEAD)
echo c2 > seed2.txt; git add seed2.txt; git commit -qm "feat: add seed2"
POST_SHA=$(git rev-parse HEAD)

BASELINE="$SANDBOX/baseline.tsv"
cat > "$BASELINE" <<EOF
slug=main
cwd=$SANDBOX
branch=main
baseline_sha=$BASE_SHA
state=clean
snapshot_ts=2026-05-17T12:00:00Z
EOF

POST="$SANDBOX/post.tsv"
cat > "$POST" <<EOF
slug=main
cwd=$SANDBOX
branch=main
post_sha=$POST_SHA
state=no-leftovers
branch_changed=false
sweep_ts=2026-05-17T12:30:00Z
EOF

OUT=$(cw_deploy_format_summary_block "$BASELINE" "$POST")
assert_contains "$OUT" "═══ main [$SANDBOX] ═══" "block header"
assert_contains "$OUT" "branch:     main"        "branch line"
assert_contains "$OUT" "baseline:   $BASE_SHA"   "baseline sha"
assert_contains "$OUT" "HEAD:       $POST_SHA"   "post sha"
assert_contains "$OUT" "feat: add seed2"         "commit list includes feat commit"
pass "1. format_summary_block prints documented per-repo block"

echo "test_deploy_format_summary_block: 1 case passed"
