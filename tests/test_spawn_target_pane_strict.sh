#!/usr/bin/env bash
# tests/test_spawn_target_pane_strict.sh
# Verifies bin/spawn.sh --target-pane <id>:
#   (a) rejects when <id> is NOT in _consult/<topic>/preflight-panes.txt
#   (b) backwards compat: spawn.sh without --target-pane reaches the
#       legacy code path (verified by checking which check it fails on).
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"

# Test A: --target-pane with id NOT in preflight-panes.txt → rc!=0
SANDBOX_A=$(mktemp -d)
export CLONE_WARS_HOME="$SANDBOX_A/.clone-wars"
mkdir -p "$CLONE_WARS_HOME"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/consult.sh"

TOPIC="strict-test-$$"
REPO_HASH=$(cw_repo_hash)
ART_DIR="$CLONE_WARS_HOME/state/$REPO_HASH/$TOPIC/_consult"
mkdir -p "$ART_DIR"
cat > "$ART_DIR/preflight-panes.txt" <<EOF
rex	%99
cody	%100
EOF

# %42 is NOT in preflight-panes.txt
err=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" "$PLUGIN_ROOT/bin/spawn.sh" rex codex "$TOPIC" --target-pane '%42' 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: --target-pane %42 (not in preflight) should rc!=0" >&2; exit 1; }
echo "$err" | grep -qi 'not in preflight-panes.txt\|not allowed\|target-pane' \
  || { echo "FAIL: error message should mention preflight-panes.txt: $err" >&2; exit 1; }

pass "spawn.sh --target-pane rejects pane id not in preflight-panes.txt"

rm -rf "$SANDBOX_A"

# Test B: --target-pane absent — spawn.sh keeps legacy split-window arg shape.
# We don't run the full spawn (would need real tmux + provider binaries) but
# we verify the arg parser doesn't blow up. spawn.sh fails on a downstream
# check (tmux/state) rather than on --target-pane validation.
SANDBOX_B=$(mktemp -d)
err=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLONE_WARS_HOME="$SANDBOX_B" "$PLUGIN_ROOT/bin/spawn.sh" rex codex topic-no-tmux 2>&1) && rc=0 || rc=$?
rm -rf "$SANDBOX_B"
[[ "$rc" -ne 0 ]] || { echo "FAIL: spawn without tmux should rc!=0" >&2; exit 1; }
# Should fail on a downstream check (tmux / state / contracts) — NOT on
# --target-pane validation (which would say "preflight-panes.txt missing"
# or similar). Any of: tmux session check, state-dir check, contracts.yaml
# lookup, commander-pool resolution. The point is the arg parser accepted
# the call and we reached a downstream resolver.
echo "$err" | grep -qi 'tmux\|TMUX\|state\|provider\|contracts\|commander' \
  || { echo "FAIL: legacy path should fail on a downstream resolver, not arg parse: $err" >&2; exit 1; }
# Negative: must NOT have failed on --target-pane validation
echo "$err" | grep -qi 'target-pane\|preflight-panes' \
  && { echo "FAIL: legacy path should not mention --target-pane / preflight: $err" >&2; exit 1; }
true

pass "spawn.sh without --target-pane preserves legacy code path"
