#!/usr/bin/env bash
# tests/test_deploy_multi_init_path_field.sh
# Locks v0.21.0 path-field handling in bin/deploy-multi-init.sh:
# - row's path field used when not 'none' (nested CapWords case)
# - falls back to $HUB_CWD/$repo when path == 'none' (flat-monorepo case)
# - existing CLAUDE.md/AGENTS.md guard still fires either way
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
SANDBOX=$(mktemp -d)
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
export CLONE_WARS_HOME="$SANDBOX/.clone-wars"
mkdir -p "$CLONE_WARS_HOME"
trap 'rm -rf "$SANDBOX"' EXIT

source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deploy.sh"

# --- Test A: mixed flat (path='none') + nested (absolute path)
TOPIC="mipf-mixed-$$"
HUB="$SANDBOX/hub"
mkdir -p "$HUB"
REPO_HASH=$(cd "$HUB" && cw_repo_hash)
ART_DIR="$CLONE_WARS_HOME/state/$REPO_HASH/$TOPIC/_deploy"
mkdir -p "$ART_DIR"

# alpha sits at the flat-sibling location (HUB/alpha)
mkdir -p "$HUB/alpha"
echo "# alpha" > "$HUB/alpha/CLAUDE.md"
( cd "$HUB/alpha" && git init -q && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m "init" )

# Beta-Repo sits two levels deep at HUB/inner/Beta-Repo (CapWords + underscore-free)
mkdir -p "$HUB/inner/Beta-Repo"
echo "# beta" > "$HUB/inner/Beta-Repo/CLAUDE.md"
( cd "$HUB/inner/Beta-Repo" && git init -q && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m "init" )

# 5-field dag-waves.txt — alpha uses sentinel 'none' (flat-sibling fallback);
# Beta-Repo uses absolute path (v0.21.0 nested case).
cat > "$ART_DIR/dag-waves.txt" <<EOF
1	1	alpha	none	flat sibling case
2	2	Beta-Repo	$HUB/inner/Beta-Repo	nested abs path case
EOF

# Run multi-init from $SANDBOX (different cwd than $HUB) with hub-cwd arg.
( cd "$SANDBOX" && CW_TOPIC_REPO_CWD="$HUB" \
  "$PLUGIN_ROOT/bin/deploy-multi-init.sh" "$TOPIC" "$HUB" )

assert_file_exists "$ART_DIR/troopers.txt" "troopers.txt written"
mapfile -t LINES < "$ART_DIR/troopers.txt"
[[ ${#LINES[@]} -eq 2 ]] || { echo "FAIL: expected 2 trooper rows (got ${#LINES[@]})" >&2; exit 1; }

# alpha (no path field) must resolve via flat-sibling fallback to $HUB/alpha
assert_eq "${LINES[0]}" "rex"$'\t'"$HUB/alpha"$'\t'"codex" \
  "alpha (path='none') resolved via flat-sibling fallback ($HUB/alpha)"

# Beta-Repo (path field set) must resolve to $HUB/inner/Beta-Repo
# Note: pool order is rex, cody (skipped for codex), wolffe → so 2nd codex = wolffe
assert_eq "${LINES[1]}" "wolffe"$'\t'"$HUB/inner/Beta-Repo"$'\t'"codex" \
  "Beta-Repo (path field) resolved via row's path"
pass "multi-init: mixed flat/nested resolution works"

# --- Test B: bad path (path field points to non-existent dir) → rc=1
TOPIC2="mipf-bad-$$"
ART2="$CLONE_WARS_HOME/state/$REPO_HASH/$TOPIC2/_deploy"
mkdir -p "$ART2"
cat > "$ART2/dag-waves.txt" <<EOF
1	1	Phantom	$SANDBOX/does-not-exist/Phantom	doomed
EOF
err=$( cd "$SANDBOX" && CW_TOPIC_REPO_CWD="$HUB" \
  "$PLUGIN_ROOT/bin/deploy-multi-init.sh" "$TOPIC2" "$HUB" 2>&1 ) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: bad path-field should rc!=0" >&2; exit 1; }
echo "$err" | grep -qi 'not found' \
  || { echo "FAIL: bad path-field error should mention 'not found': $err" >&2; exit 1; }
pass "multi-init: bad path-field rejects with 'not found' error"

pass "v0.21.0 multi-init honors path field with flat-sibling fallback"
