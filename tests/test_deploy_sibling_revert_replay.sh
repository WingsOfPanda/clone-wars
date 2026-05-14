#!/usr/bin/env bash
# tests/test_deploy_sibling_revert_replay.sh — v0.30.0 item 2c
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/deploy-sibling.sh"

declare -F cw_deploy_revert_and_replay >/dev/null \
  || { echo "FAIL: cw_deploy_revert_and_replay not defined" >&2; exit 1; }
pass "helper defined"

# Build a sibling with: baseline c0, then 2 rogue commits c1+c2 on main
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
cd "$SANDBOX"
git init -q -b main
git config user.email test@test
git config user.name Test
echo c0 > a.txt
git add a.txt
git commit -qm c0
BASELINE=$(git rev-parse HEAD)
echo c1 >> a.txt
git add a.txt
git commit -qm c1
SHA1=$(git rev-parse HEAD)
echo c2 >> a.txt
git add a.txt
git commit -qm c2
SHA2=$(git rev-parse HEAD)

# Case 1: clean revert+replay — main back to c0 content; rescue branch has c1+c2
TOPIC=foo-topic
set +e
out=$(cw_deploy_revert_and_replay "$SANDBOX" "$TOPIC" "$BASELINE" "main" "$SHA1 $SHA2" 2>&1); rc=$?
set -e
[[ "$rc" -eq 0 ]] || { echo "FAIL: clean revert_and_replay rc=$rc, expected 0" >&2; echo "$out"; exit 1; }

# After revert main's content should be back to c0
content=$(cat "$SANDBOX/a.txt")
[[ "$content" == "c0" ]] || { echo "FAIL: main content not back to c0 after revert (got: $content)" >&2; exit 1; }
git -C "$SANDBOX" rev-parse --verify -q refs/heads/feat/deploy-${TOPIC}-rescue >/dev/null \
  || { echo "FAIL: rescue branch feat/deploy-${TOPIC}-rescue not created" >&2; exit 1; }

# Rescue branch should preserve the original c1 + c2 work — assert by inspecting
# its full log (NOT log rescue ^main, since main contains the reverts on top of
# the same SHAs, making main a strict superset of rescue's history in this
# test setup; ^main would exclude everything).
rescue_log=$(git -C "$SANDBOX" log feat/deploy-${TOPIC}-rescue --oneline)
grep -q ' c1' <<<"$rescue_log" || { echo "FAIL: c1 not on rescue branch (log: $rescue_log)" >&2; exit 1; }
grep -q ' c2' <<<"$rescue_log" || { echo "FAIL: c2 not on rescue branch (log: $rescue_log)" >&2; exit 1; }

# Rescue branch tip should also have the trooper's full content (c0 + c1 + c2 lines)
rescue_content=$(git -C "$SANDBOX" show feat/deploy-${TOPIC}-rescue:a.txt)
[[ "$rescue_content" == $'c0\nc1\nc2' ]] \
  || { echo "FAIL: rescue branch tip content mismatch (got: $rescue_content)" >&2; exit 1; }
pass "1. clean revert_and_replay: main back to c0 content; rescue branch preserves c1+c2 work"

# Case 2: rescue branch already exists → rc=1
SANDBOX2=$(mktemp -d)
cd "$SANDBOX2"
git init -q -b main
git config user.email test@test
git config user.name Test
echo c0 > a.txt
git add a.txt
git commit -qm c0
BASELINE2=$(git rev-parse HEAD)
echo c1 >> a.txt
git commit -qam c1
SHA_R=$(git rev-parse HEAD)
git branch feat/deploy-bar-rescue main   # pre-existing rescue branch
set +e
out=$(cw_deploy_revert_and_replay "$SANDBOX2" "bar" "$BASELINE2" "main" "$SHA_R" 2>&1); rc=$?
set -e
[[ "$rc" == "1" ]] || { echo "FAIL: pre-existing rescue branch should fail with rc=1, got $rc" >&2; echo "$out"; exit 1; }
rm -rf "$SANDBOX2"
pass "2. rc=1 when rescue branch already exists"

# Case 3: revert conflict — c2 modifies a.txt after c1's change, reverting c1 alone conflicts with c2
SANDBOX3=$(mktemp -d)
cd "$SANDBOX3"
git init -q -b main
git config user.email test@test
git config user.name Test
echo a > a.txt
git add a.txt
git commit -qm c0
B3=$(git rev-parse HEAD)
echo b > a.txt
git commit -qam c1
SHA_C=$(git rev-parse HEAD)
echo c > a.txt
git commit -qam c2  # NOT in the revert list — reverting c1 conflicts because c2 changed the same line
set +e
out=$(cw_deploy_revert_and_replay "$SANDBOX3" "baz" "$B3" "main" "$SHA_C" 2>&1); rc=$?
set -e
[[ "$rc" == "1" ]] || { echo "FAIL: revert conflict should fail with rc=1, got $rc" >&2; echo "$out"; exit 1; }
rm -rf "$SANDBOX3"
pass "3. rc=1 on revert conflict (left for user to resolve)"

# Case 4: missing args → rc=2
set +e
out=$(cw_deploy_revert_and_replay 2>&1); rc=$?
set -e
[[ "$rc" == "2" ]] || { echo "FAIL: missing args: expected rc=2, got $rc" >&2; exit 1; }
pass "4. rc=2 on missing args"

echo "test_deploy_sibling_revert_replay: 4 cases passed"
