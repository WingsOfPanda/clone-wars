#!/usr/bin/env bash
# tests/test_deploy_multi_init_preflight_sidecar.sh
# Locks v0.22.0 sidecar troopers-preflight.txt write — consult-shaped 2-col
# <provider>\t<commander> in DAG order. Read by bin/preflight-layout.sh
# when invoked with --troopers-from from the deploy path.
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

TOPIC="dmips-$$"
HUB="$SANDBOX/hub"
mkdir -p "$HUB/auth" "$HUB/api" "$HUB/ui"
for r in auth api ui; do
  echo "# $r" > "$HUB/$r/CLAUDE.md"
  ( cd "$HUB/$r" && git init -q && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m init )
done

REPO_HASH=$(cd "$HUB" && cw_repo_hash)
ART_DIR="$CLONE_WARS_HOME/state/$REPO_HASH/$TOPIC/_deploy"
mkdir -p "$ART_DIR"

# Synthesize a 5-field dag-waves.txt (v0.21.0 shape: wave\tstep\trepo\tpath\tdesc)
cat > "$ART_DIR/dag-waves.txt" <<EOF
1	1	auth	none	set up auth
2	2	api	none	build api
3	3	ui	none	wire frontend
EOF

( cd "$HUB" \
  && "$PLUGIN_ROOT/bin/deploy-multi-init.sh" "$TOPIC" "$HUB" >/dev/null )

# Existing artifacts still produced
assert_file_exists "$ART_DIR/troopers.txt"          "troopers.txt written"
assert_file_exists "$ART_DIR/cmdr-cwd-map.txt"      "cmdr-cwd-map.txt written"

# v0.22.0: sidecar troopers-preflight.txt — consult-shaped 2-col, in DAG order
assert_file_exists "$ART_DIR/troopers-preflight.txt" "troopers-preflight.txt written (sidecar)"

# Filter out comment + blank lines for assertions
PFL_DATA=()
while IFS= read -r line; do
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  [[ -z "${line// }" ]] && continue
  PFL_DATA+=( "$line" )
done < "$ART_DIR/troopers-preflight.txt"

[[ ${#PFL_DATA[@]} -eq 3 ]] \
  || { echo "FAIL: expected 3 data rows, got ${#PFL_DATA[@]}: $(cat "$ART_DIR/troopers-preflight.txt")" >&2; exit 1; }

# DAG order maps to commander pool order (codex skips cody → rex, wolffe, bly)
assert_eq "${PFL_DATA[0]}" $'codex\trex'    "row 1: codex\\trex (auth)"
assert_eq "${PFL_DATA[1]}" $'codex\twolffe' "row 2: codex\\twolffe (api; cody skipped)"
assert_eq "${PFL_DATA[2]}" $'codex\tbly'    "row 3: codex\\tbly (ui)"

pass "v0.22.0 deploy-multi-init writes troopers-preflight.txt sidecar (2-col, DAG order)"
