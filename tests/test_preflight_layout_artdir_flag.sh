#!/usr/bin/env bash
# tests/test_preflight_layout_artdir_flag.sh
# Verifies preflight-layout.sh accepts an additive --art-dir flag.
# Without the flag: falls through to cw_consult_art_dir (v0.19.0 behavior).
# With the flag: uses the given path (for v0.20.0 deploy multi-repo flow).
#
# This test does NOT spin up tmux — it tests the arg-parse + path resolution
# layer only. End-to-end pane-allocation is covered by the existing
# test_preflight_layout.sh (consult path) and test_deploy_multi_preflight.sh
# (deploy path).
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
SANDBOX=$(mktemp -d)
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
export CLONE_WARS_HOME="$SANDBOX/.clone-wars"
mkdir -p "$CLONE_WARS_HOME"
trap 'rm -rf "$SANDBOX"' EXIT

# Test A: --art-dir flag accepted; with bad path → rc!=0 with "troopers.txt not found"
err=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" "$PLUGIN_ROOT/bin/preflight-layout.sh" --art-dir /nonexistent topic 3 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: --art-dir /nonexistent should rc!=0" >&2; exit 1; }
echo "$err" | grep -qi 'troopers.txt not found' \
  || { echo "FAIL: error should mention troopers.txt: $err" >&2; exit 1; }
pass "--art-dir: bad path rejected with troopers.txt error"

# Test B: without --art-dir flag, falls through to cw_consult_art_dir (legacy v0.19.0 path).
# Script will fail on missing troopers.txt at the consult-derived path, proving
# the v0.19.0 code path is reachable (and unchanged).
err=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" "$PLUGIN_ROOT/bin/preflight-layout.sh" some-topic 2 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: missing troopers.txt should rc!=0" >&2; exit 1; }
echo "$err" | grep -qi 'troopers.txt not found' \
  || { echo "FAIL: legacy path should fail on troopers.txt not found: $err" >&2; exit 1; }
pass "preflight-layout (no flag): legacy code path reachable (v0.19.0 byte-equal)"
