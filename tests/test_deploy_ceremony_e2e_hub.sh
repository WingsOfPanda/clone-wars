#!/usr/bin/env bash
# tests/test_deploy_ceremony_e2e_hub.sh
# v0.42.0: end-to-end ceremony on a hub with 2 sub-repos (one clean, one dirty).
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deploy.sh"

HUB=$(mktemp -d)
trap 'rm -rf "$HUB"' EXIT
mkdir -p "$HUB/repo-a" "$HUB/repo-b"
for r in repo-a repo-b; do
  ( cd "$HUB/$r"
    git init -q -b main
    git config user.email t@t; git config user.name T
    echo "$r seed" > seed.txt; git add seed.txt; git commit -qm seed )
done
# repo-a stays clean; repo-b has WIP
echo wip >> "$HUB/repo-b/seed.txt"

cd "$HUB"
export CLONE_WARS_HOME="$HUB/.clone-wars"

TOPIC=e2e-hub
ART_DIR=$(cw_deploy_art_dir "$TOPIC")
mkdir -p "$ART_DIR"
printf 'rex\t%s/repo-a\tcodex\n'  "$HUB" >  "$ART_DIR/troopers.txt"
printf 'cody\t%s/repo-b\tclaude\n' "$HUB" >> "$ART_DIR/troopers.txt"

# Pre-deploy snapshot
"$PLUGIN_ROOT/bin/deploy-pre-snapshot.sh" "$TOPIC" >/dev/null
assert_file_exists "$ART_DIR/baselines/rex.tsv"
assert_file_exists "$ART_DIR/baselines/cody.tsv"
grep -qE '^state=clean$'         "$ART_DIR/baselines/rex.tsv"
grep -qE '^state=wip-committed$' "$ART_DIR/baselines/cody.tsv"

# Simulate trooper work in each sub-repo
( cd "$HUB/repo-a"; echo work-a > w.txt; git add w.txt; git commit -qm "feat: rex work" )
( cd "$HUB/repo-b"; echo work-b > w.txt; git add w.txt; git commit -qm "feat: cody work" )

# Post-deploy summary
OUT=$("$PLUGIN_ROOT/bin/deploy-summary.sh" "$TOPIC")
assert_contains "$OUT" "═══ rex [$HUB/repo-a] ═══"  "rex block present"
assert_contains "$OUT" "═══ cody [$HUB/repo-b] ═══" "cody block present"
assert_contains "$OUT" "feat: rex work"   "rex commit listed"
assert_contains "$OUT" "feat: cody work"  "cody commit listed"
pass "1. e2e hub-mode: 2 sub-repos → 2 baselines → 2 summary blocks"

echo "test_deploy_ceremony_e2e_hub: 1 case passed"
