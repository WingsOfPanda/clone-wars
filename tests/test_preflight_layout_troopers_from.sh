#!/usr/bin/env bash
# tests/test_preflight_layout_troopers_from.sh
# Locks v0.22.0 --troopers-from flag for bin/preflight-layout.sh.
# Tests are tmux-independent — they exercise the flag-parse + file-resolve
# path. Real preflight allocation (which needs tmux) is covered by the
# v0.22.0 e2e test (tests/test_deploy_multi_repo_e2e.sh).
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
SANDBOX=$(mktemp -d)
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
export CLONE_WARS_HOME="$SANDBOX/.clone-wars"
mkdir -p "$CLONE_WARS_HOME"
trap 'rm -rf "$SANDBOX"' EXIT

# Test A: --troopers-from with non-existent path → rc=1, clear error
ART="$SANDBOX/art"
mkdir -p "$ART"
err=$( "$PLUGIN_ROOT/bin/preflight-layout.sh" \
  --art-dir "$ART" \
  --troopers-from "$SANDBOX/no-such-file.txt" \
  topic-test 2 2>&1 ) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: missing --troopers-from path should rc!=0" >&2; exit 1; }
echo "$err" | grep -qiE 'troopers-from.*not found' \
  || { echo "FAIL: error should mention --troopers-from not found: $err" >&2; exit 1; }
pass "preflight-layout --troopers-from missing-path rejects with clear error"

# Test B: usage line mentions --troopers-from
help_out=$( "$PLUGIN_ROOT/bin/preflight-layout.sh" 2>&1 ) || true
echo "$help_out" | grep -qE 'troopers-from' \
  || { echo "FAIL: usage line missing --troopers-from: $help_out" >&2; exit 1; }
pass "preflight-layout usage advertises --troopers-from"

# Test C: default behavior reads $ART_DIR/troopers.txt — byte-equal v0.21.0
ART2="$SANDBOX/art2"
mkdir -p "$ART2"
err2=$( "$PLUGIN_ROOT/bin/preflight-layout.sh" --art-dir "$ART2" topic-test 2 2>&1 ) && rc2=0 || rc2=$?
[[ "$rc2" -ne 0 ]] || { echo "FAIL: missing default troopers.txt should rc!=0" >&2; exit 1; }
# When --troopers-from is OMITTED, the error message must reference the
# DEFAULT path (troopers.txt under $ART_DIR), NOT a --troopers-from path.
echo "$err2" | grep -q 'troopers-from' \
  && { echo "FAIL: default-path error should NOT mention --troopers-from: $err2" >&2; exit 1; }
echo "$err2" | grep -qE 'troopers\.txt' \
  || { echo "FAIL: default-path error should mention troopers.txt: $err2" >&2; exit 1; }
pass "preflight-layout default behavior reads \$ART_DIR/troopers.txt (byte-equal v0.21.0)"

# Note: positive-path test (--troopers-from override accepted, panes
# allocated in correct cwds) is covered by tests/test_deploy_multi_repo_e2e.sh
# (Task 7) which has proper tmux pane cleanup. Adding it here would leak
# orphan panes when run inside a tmux session.

pass "v0.22.0 preflight-layout --troopers-from flag locked (3 cases)"
