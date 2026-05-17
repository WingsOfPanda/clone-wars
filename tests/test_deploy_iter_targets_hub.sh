#!/usr/bin/env bash
# tests/test_deploy_iter_targets_hub.sh
# v0.42.0: hub-mode deploy emits one row per troopers.txt entry.
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
export CLONE_WARS_HOME="$SANDBOX/.clone-wars"

TOPIC=iter-hub
ART_DIR=$(cw_deploy_art_dir "$TOPIC")
mkdir -p "$ART_DIR"
printf 'rex\t/abs/path/repo-a\tcodex\n' >  "$ART_DIR/troopers.txt"
printf 'cody\t/abs/path/repo-b\tclaude\n' >> "$ART_DIR/troopers.txt"

OUT=$(cw_deploy_iter_targets "$TOPIC")
EXPECTED=$'rex\t/abs/path/repo-a\ncody\t/abs/path/repo-b'
assert_eq "$OUT" "$EXPECTED" "hub-mode iter_targets emits 2 rows from troopers.txt"
pass "1. hub-mode iter_targets emits one row per troopers.txt entry"

echo "test_deploy_iter_targets_hub: 1 case passed"
