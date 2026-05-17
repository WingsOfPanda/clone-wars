#!/usr/bin/env bash
# tests/test_deploy_ceremony_e2e_single.sh
# v0.42.0: end-to-end snapshot → trooper-stub commit → sweep → summary on temp single-repo.
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
git init -q -b main
git config user.email t@t; git config user.name T
echo c > seed.txt; git add seed.txt; git commit -qm seed
echo wip >> seed.txt   # pre-deploy WIP
export CLONE_WARS_HOME="$SANDBOX/.clone-wars"

TOPIC=e2e-single
ART_DIR=$(cw_deploy_art_dir "$TOPIC")
mkdir -p "$ART_DIR"
printf '%s\n' "$SANDBOX" > "$ART_DIR/target_cwd.txt"

# Pre-deploy snapshot
"$PLUGIN_ROOT/bin/deploy-pre-snapshot.sh" "$TOPIC" >/dev/null
assert_file_exists "$ART_DIR/baselines/main.tsv" "baseline file created"
grep -qE '^state=wip-committed$' "$ART_DIR/baselines/main.tsv"

# Simulate trooper work
echo trooper > trooper.txt
git add trooper.txt
git commit -qm "feat: trooper added file"

# Post-deploy summary
OUT=$("$PLUGIN_ROOT/bin/deploy-summary.sh" "$TOPIC")
assert_file_exists "$ART_DIR/posts/main.tsv" "post file created"
assert_contains "$OUT" "═══ main [$SANDBOX] ═══" "summary block header"
assert_contains "$OUT" "feat: trooper added file"  "summary lists trooper commit"
pass "1. e2e single-repo: snapshot → trooper commit → summary roundtrip"

echo "test_deploy_ceremony_e2e_single: 1 case passed"
