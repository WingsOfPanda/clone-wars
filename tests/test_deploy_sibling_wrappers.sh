#!/usr/bin/env bash
# tests/test_deploy_sibling_wrappers.sh — v0.30.0 item 2d
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

[[ -x "$PLUGIN_ROOT/bin/deploy-sibling-baseline.sh" ]] \
  || { echo "FAIL: bin/deploy-sibling-baseline.sh missing or not executable" >&2; exit 1; }
[[ -x "$PLUGIN_ROOT/bin/deploy-sibling-verify.sh" ]] \
  || { echo "FAIL: bin/deploy-sibling-verify.sh missing or not executable" >&2; exit 1; }
pass "wrappers exist + executable"

# Sandbox: 2 sibling repos under hub
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
HUB="$SANDBOX/hub"
ART_DIR="$SANDBOX/art"
mkdir -p "$HUB" "$ART_DIR"
for r in repo-a repo-b; do
  mkdir -p "$HUB/$r"
  ( cd "$HUB/$r"
    git init -q -b main
    git config user.email test@test
    git config user.name Test
    echo c0 > x.txt
    git add x.txt
    git commit -qm c0
  )
done

# baseline.sh writes _deploy/sibling-baseline.txt with 2 rows
"$PLUGIN_ROOT/bin/deploy-sibling-baseline.sh" "$ART_DIR" "$HUB" ""
[[ -f "$ART_DIR/sibling-baseline.txt" ]] \
  || { echo "FAIL: sibling-baseline.txt not written" >&2; exit 1; }
n_rows=$(wc -l < "$ART_DIR/sibling-baseline.txt")
[[ "$n_rows" == "2" ]] || { echo "FAIL: expected 2 baseline rows, got $n_rows" >&2; cat "$ART_DIR/sibling-baseline.txt"; exit 1; }
pass "1. baseline.sh writes 2-row TSV for 2 sibling repos"

# verify.sh: no rogue commits → sibling-rogue.txt empty
"$PLUGIN_ROOT/bin/deploy-sibling-verify.sh" "$ART_DIR" "$HUB"
if [[ -s "$ART_DIR/sibling-rogue.txt" ]]; then
  echo "FAIL: verify.sh wrote non-empty rogue file when nothing changed" >&2
  cat "$ART_DIR/sibling-rogue.txt"
  exit 1
fi
pass "2. verify.sh: empty sibling-rogue.txt when no rogue commits"

# Add a rogue commit to repo-a
( cd "$HUB/repo-a" && echo c1 > x.txt && git add x.txt && git commit -qm c1 )

# verify.sh now writes a rogue row
"$PLUGIN_ROOT/bin/deploy-sibling-verify.sh" "$ART_DIR" "$HUB"
[[ -s "$ART_DIR/sibling-rogue.txt" ]] \
  || { echo "FAIL: verify.sh missed the rogue commit on repo-a/main" >&2; exit 1; }
grep -q '^repo-a' "$ART_DIR/sibling-rogue.txt" \
  || { echo "FAIL: rogue file doesn't reference repo-a" >&2; cat "$ART_DIR/sibling-rogue.txt"; exit 1; }
grep -q 'c1$' "$ART_DIR/sibling-rogue.txt" \
  || { echo "FAIL: rogue file doesn't capture commit subject 'c1'" >&2; cat "$ART_DIR/sibling-rogue.txt"; exit 1; }
pass "3. verify.sh: writes sibling-rogue.txt row when sibling main moves"

# Declared targets exclusion: re-baseline excluding repo-a → only repo-b in baseline
rm -f "$ART_DIR/sibling-baseline.txt"
"$PLUGIN_ROOT/bin/deploy-sibling-baseline.sh" "$ART_DIR" "$HUB" "repo-a"
n_rows=$(wc -l < "$ART_DIR/sibling-baseline.txt")
[[ "$n_rows" == "1" ]] || { echo "FAIL: declared-target exclusion failed (expected 1 row, got $n_rows)" >&2; cat "$ART_DIR/sibling-baseline.txt"; exit 1; }
grep -q '^repo-b' "$ART_DIR/sibling-baseline.txt" \
  || { echo "FAIL: declared-target exclusion left wrong slug" >&2; exit 1; }
pass "4. declared-target CSV correctly excludes from baseline"

# Missing args → rc=2
set +e
"$PLUGIN_ROOT/bin/deploy-sibling-baseline.sh" 2>/dev/null; rc=$?
set -e
[[ "$rc" == "2" ]] || { echo "FAIL: baseline.sh missing-arg rc=$rc, expected 2" >&2; exit 1; }
set +e
"$PLUGIN_ROOT/bin/deploy-sibling-verify.sh" 2>/dev/null; rc=$?
set -e
[[ "$rc" == "2" ]] || { echo "FAIL: verify.sh missing-arg rc=$rc, expected 2" >&2; exit 1; }
pass "5. wrappers rc=2 on missing args"

echo "test_deploy_sibling_wrappers: 5 cases passed"
