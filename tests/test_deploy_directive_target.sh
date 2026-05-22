#!/usr/bin/env bash
# tests/test_deploy_directive_target.sh — static-wiring assertions
# for the v0.10 sub-repo redirect directive flow.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

D=../commands/deploy.md

# Auto file (target) is read.
grep -q 'target_cwd.txt' "$D" \
  || { echo "FAIL: directive must reference target_cwd.txt" >&2; exit 1; }
pass "directive reads target_cwd.txt"

# TARGET_CWD is exported from Step 0.
grep -q 'TARGET_CWD=' "$D" \
  || { echo "FAIL: directive must set TARGET_CWD variable" >&2; exit 1; }
pass "directive sets TARGET_CWD"

# Step 1.1 spawn passes --cwd "$TARGET_CWD".
grep -qE 'spawn\.sh.*cody.*\-\-cwd[ ]+"?\$TARGET_CWD' "$D" \
  || { echo "FAIL: Step 1.1 spawn line must pass --cwd \$TARGET_CWD" >&2; exit 1; }
pass "directive's spawn line passes --cwd \$TARGET_CWD"

# Step 2 cross-verify uses git -C "$TARGET_CWD".
grep -qE 'git -C "?\$TARGET_CWD"?' "$D" \
  || { echo "FAIL: Step 2 cross-verify must use git -C \$TARGET_CWD" >&2; exit 1; }
pass "directive's cross-verify uses git -C \$TARGET_CWD"

# No leftover bare 'git checkout -b' / 'git log/diff' WITHOUT git -C in the directive.
BARE_GIT=$(mktemp); trap 'rm -f "$BARE_GIT"' EXIT
if grep -nE '^\s*git (log|diff|checkout)' "$D" | grep -v 'git -C' > "$BARE_GIT"; then
  if [[ -s "$BARE_GIT" ]]; then
    cat "$BARE_GIT" >&2
    echo "FAIL: leftover bare git invocation in directive (must use git -C)" >&2; exit 1
  fi
fi
pass "no leftover bare git invocations in directive"

# v0.31.0: directive MUST NOT export CW_TOPIC_REPO_CWD. State is project-local;
# downstream bin scripts read $ART_DIR/target_cwd.txt directly for the sub-repo
# path. Asserting absence rather than presence makes the invariant legible —
# future contributors who re-add the export will fail this test.
grep -qE 'export[ ]+CW_TOPIC_REPO_CWD' "$D" \
  && { echo "FAIL: directive must NOT export CW_TOPIC_REPO_CWD in v0.31.0 (removed in favor of target_cwd.txt direct read)" >&2; exit 1; }
pass "directive does NOT export CW_TOPIC_REPO_CWD (v0.31.0 invariant)"

echo "ALL: ok"
