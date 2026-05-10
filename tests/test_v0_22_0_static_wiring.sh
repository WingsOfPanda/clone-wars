#!/usr/bin/env bash
# tests/test_v0_22_0_static_wiring.sh
# Locks v0.22.0 invariants:
#   1. deploy-multi-init.sh writes troopers-preflight.txt sidecar
#   2. preflight-layout.sh accepts --troopers-from flag
#   3. spawn.sh accepts --preflight-art-dir flag
#   4. commands/deploy.md Step 3a passes --troopers-from
#   5. commands/deploy.md Step 3b dispatch shape uses bin/send.sh @file
#      (not bare cw_inbox_write — Bug 5 fix)
#   6. commands/deploy.md Step 3d fix-loop uses bin/send.sh @file
#      (Bug 5 surface at second site)
#   7. plugin.json semver-shape (loosened per v0.20.2 lesson)
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"

# 1. deploy-multi-init.sh writes troopers-preflight.txt
MULTI_INIT="$PLUGIN_ROOT/bin/deploy-multi-init.sh"
grep -qE 'troopers-preflight\.txt' "$MULTI_INIT" \
  || { echo "FAIL: deploy-multi-init.sh missing troopers-preflight.txt write" >&2; exit 1; }
pass "deploy-multi-init.sh writes troopers-preflight.txt sidecar"

# 2. preflight-layout.sh has --troopers-from flag
PREFLIGHT="$PLUGIN_ROOT/bin/preflight-layout.sh"
grep -qE -- '--troopers-from' "$PREFLIGHT" \
  || { echo "FAIL: preflight-layout.sh missing --troopers-from flag" >&2; exit 1; }
pass "preflight-layout.sh has --troopers-from flag"

# 3. spawn.sh has --preflight-art-dir flag
SPAWN="$PLUGIN_ROOT/bin/spawn.sh"
grep -qE -- '--preflight-art-dir' "$SPAWN" \
  || { echo "FAIL: spawn.sh missing --preflight-art-dir flag" >&2; exit 1; }
pass "spawn.sh has --preflight-art-dir flag"

# 4. Step 3a passes --troopers-from to preflight-layout
DEPLOY_MD="$PLUGIN_ROOT/commands/deploy.md"
STEP_3A_BODY=$(awk '/^### Step 3a /,/^### Step 3b /' "$DEPLOY_MD")
[[ "$STEP_3A_BODY" == *"--troopers-from"* ]] \
  || { echo "FAIL: Step 3a missing --troopers-from in preflight-layout invocation" >&2; exit 1; }
pass "Step 3a passes --troopers-from to preflight-layout"

# 5. Step 3b dispatch shape uses bin/send.sh @file (Bug 5 fix)
STEP_3B_BODY=$(awk '/^### Step 3b /,/^### Step 3c /' "$DEPLOY_MD")
[[ "$STEP_3B_BODY" == *"bin/send.sh"* ]] \
  || { echo "FAIL: Step 3b missing bin/send.sh @file dispatch (BUG 5 fix)" >&2; exit 1; }
# The dispatch-shape comment block (between "Per-repo dispatch shape" and
# "Per-repo wave-wait shape") must explicitly use bin/send.sh.
DISPATCH_SHAPE=$(awk '/Per-repo dispatch shape/,/Per-repo wave-wait shape/' "$DEPLOY_MD")
[[ "$DISPATCH_SHAPE" == *"bin/send.sh"* ]] \
  || { echo "FAIL: Step 3b dispatch shape comment block missing bin/send.sh" >&2; exit 1; }
pass "Step 3b dispatch shape uses bin/send.sh @file (Bug 5 closed)"

# 6. Step 3d fix-loop uses bin/send.sh @file (Bug 5 second site)
STEP_3D_BODY=$(awk '/^### Step 3d /,/^### Step 4 /' "$DEPLOY_MD")
[[ "$STEP_3D_BODY" == *"bin/send.sh"* ]] \
  || { echo "FAIL: Step 3d fix-loop missing bin/send.sh dispatch (Bug 5 second site)" >&2; exit 1; }
pass "Step 3d fix-loop uses bin/send.sh @file (Bug 5 closed at second site)"

# 7. plugin.json semver-shape (loosened from exact lock per v0.20.2 lesson)
PJ="$PLUGIN_ROOT/.claude-plugin/plugin.json"
grep -qE '"version": "0\.[0-9]+\.[0-9]+"' "$PJ" \
  || { echo "FAIL: plugin.json missing semver-shape version field" >&2; exit 1; }
pass "plugin.json version field present + semver-shaped"

pass "v0.22.0 static wiring complete (7 invariants locked)"
