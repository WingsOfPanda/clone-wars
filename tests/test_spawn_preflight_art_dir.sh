#!/usr/bin/env bash
# tests/test_spawn_preflight_art_dir.sh
# Locks v0.22.0 --preflight-art-dir flag for spawn's --target-pane validation.
# Tests are tmux-independent — they exercise the flag-parse + PFP-resolve path.
# Real respawn (which needs tmux) is covered by tests/test_deploy_multi_repo_e2e.sh.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
SANDBOX=$(mktemp -d)
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
export CLONE_WARS_HOME="$SANDBOX/.clone-wars"
mkdir -p "$CLONE_WARS_HOME"
trap 'rm -rf "$SANDBOX"' EXIT

# Test A: --preflight-art-dir with non-existent preflight-panes.txt → clear error
ART="$SANDBOX/art"
mkdir -p "$ART"
err=$( "$PLUGIN_ROOT/bin/spawn.sh" rex codex topicx \
  --target-pane "%999" \
  --preflight-art-dir "$ART" 2>&1 ) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: missing preflight-panes.txt should rc!=0" >&2; exit 1; }
echo "$err" | grep -qE "preflight-panes\.txt at: $ART" \
  || { echo "FAIL: error should reference --preflight-art-dir override path: $err" >&2; exit 1; }
pass "spawn --preflight-art-dir override path used in error message"

# Test B: --preflight-art-dir with valid preflight-panes.txt + matching pane
# passes the --target-pane validation (downstream tmux ops will fail, but the
# validation runs FIRST — we assert the validation block doesn't reject).
printf 'rex\t%s\n' "%999" > "$ART/preflight-panes.txt"
err2=$( "$PLUGIN_ROOT/bin/spawn.sh" rex codex topicx \
  --target-pane "%999" \
  --preflight-art-dir "$ART" 2>&1 ) && rc2=0 || rc2=$?
echo "$err2" | grep -q "not in preflight-panes.txt" \
  && { echo "FAIL: validation should pass when pane is in override file: $err2" >&2; exit 1; }
echo "$err2" | grep -q "requires preflight-panes.txt at:" \
  && { echo "FAIL: validation should NOT report missing preflight-panes.txt when override file exists: $err2" >&2; exit 1; }
pass "spawn --preflight-art-dir validates against override file (not consult default)"

# Test C: NO --preflight-art-dir flag → byte-equal v0.21.0 (uses cw_consult_art_dir)
# When the flag is absent, the resolved path must NOT equal $ART (the override).
err3=$( "$PLUGIN_ROOT/bin/spawn.sh" rex codex topicy \
  --target-pane "%999" 2>&1 ) && rc3=0 || rc3=$?
[[ "$rc3" -ne 0 ]] || { echo "FAIL: missing preflight-panes.txt (consult path) should rc!=0" >&2; exit 1; }
echo "$err3" | grep -q "$ART/preflight-panes.txt" \
  && { echo "FAIL: default behavior should NOT use --preflight-art-dir override path: $err3" >&2; exit 1; }
echo "$err3" | grep -qE "preflight-panes\.txt at:" \
  || { echo "FAIL: default-path error should still reference preflight-panes.txt: $err3" >&2; exit 1; }
pass "spawn --preflight-art-dir omitted = consult-art-dir default (byte-equal v0.21.0)"

# Test D: usage line mentions --preflight-art-dir
help_out=$( "$PLUGIN_ROOT/bin/spawn.sh" --help 2>&1 ) || true
echo "$help_out" | grep -qE 'preflight-art-dir' \
  || { echo "FAIL: usage block missing --preflight-art-dir: $help_out" >&2; exit 1; }
pass "spawn usage block advertises --preflight-art-dir"

pass "v0.22.0 spawn --preflight-art-dir flag locked (4 cases)"
