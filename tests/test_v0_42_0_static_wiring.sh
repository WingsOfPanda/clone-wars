#!/usr/bin/env bash
# tests/test_v0_42_0_static_wiring.sh
# Version-stamped static-wiring lock for v0.42.0. Skip-guards when
# plugin.json is not at 0.42.0 (so it passes via skip during v0.41.x
# work). Activates and locks 8 invariants when version matches.
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib/assert.sh

PLUGIN_JSON=".claude-plugin/plugin.json"
[[ -f "$PLUGIN_JSON" ]] || { echo "FAIL: $PLUGIN_JSON missing" >&2; exit 1; }

CURRENT_VERSION=$(grep -E '"version"' "$PLUGIN_JSON" | head -1 \
  | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')

if [[ "$CURRENT_VERSION" != "0.42.0" ]]; then
  echo "SKIP: plugin.json version $CURRENT_VERSION != 0.42.0 (v0.42.0 invariants inactive)"
  exit 0
fi

# Invariant 1: marketplace.json both version lines = 0.42.0
MKT=".claude-plugin/marketplace.json"
MKT_HITS=$(grep -cE '"version"[[:space:]]*:[[:space:]]*"0\.42\.0"' "$MKT")
[[ "$MKT_HITS" -ge 2 ]] \
  || { echo "FAIL: marketplace.json should have ≥2 lines reading version 0.42.0 (got $MKT_HITS)" >&2; exit 1; }
pass "1. plugin.json + marketplace.json both at 0.42.0"

# Invariant 2: lib/deploy.sh exports all 4 new helpers
LIB="lib/deploy.sh"
for fn in cw_deploy_iter_targets cw_deploy_pre_snapshot cw_deploy_post_sweep cw_deploy_format_summary_block; do
  grep -qE "^$fn\(\)[[:space:]]*\{" "$LIB" \
    || { echo "FAIL: $LIB missing helper $fn" >&2; exit 1; }
done
pass "2. lib/deploy.sh exports iter_targets + pre_snapshot + post_sweep + format_summary_block"

# Invariant 3: BRANCH DISCIPLINE stanza in all 3 prompt builders
# (covered by test_deploy_branch_pin_lint too — duplicated here for static lock)
for fn in cw_deploy_build_turn_prompt_round1 cw_deploy_build_turn_prompt_fix cw_deploy_build_dag_unit_prompt; do
  body=$(awk -v fn="$fn" '
    $0 ~ "^"fn"\\(\\) \\{" { p=1 }
    p && /^# cw_deploy_/ && !/^# cw_deploy_build/ { exit }
    p && /^cw_deploy_/ && $0 !~ "^"fn"\\(\\) \\{" { exit }
    p
  ' "$LIB")
  echo "$body" | grep -qE 'BRANCH DISCIPLINE' \
    || { echo "FAIL: $fn missing BRANCH DISCIPLINE stanza" >&2; exit 1; }
done
pass "3. all 3 prompt builders carry BRANCH DISCIPLINE stanza"

# Invariant 4: commands/deploy.md invokes deploy-pre-snapshot.sh exactly once in Step 0
DIRECTIVE="commands/deploy.md"
STEP0=$(awk '/^### Step 0/,/^### Step 1/' "$DIRECTIVE")
PRE_HITS=$(echo "$STEP0" | grep -cE 'deploy-pre-snapshot\.sh')
[[ "$PRE_HITS" -eq 1 ]] \
  || { echo "FAIL: Step 0 should invoke deploy-pre-snapshot.sh exactly once (got $PRE_HITS)" >&2; exit 1; }
pass "4. commands/deploy.md Step 0 invokes deploy-pre-snapshot.sh exactly once"

# Invariant 5: commands/deploy.md invokes deploy-summary.sh exactly once in Step 4 (before archive)
STEP4=$(awk '/^### Step 4/,0' "$DIRECTIVE")
SUM_HITS=$(echo "$STEP4" | grep -cE 'deploy-summary\.sh')
[[ "$SUM_HITS" -eq 1 ]] \
  || { echo "FAIL: Step 4 should invoke deploy-summary.sh exactly once (got $SUM_HITS)" >&2; exit 1; }
pass "5. commands/deploy.md Step 4 invokes deploy-summary.sh exactly once"

# Invariant 6: legacy 5a AskUserQuestion options must NOT appear anywhere in directive
! grep -qE 'Stash and continue' "$DIRECTIVE" \
  || { echo "FAIL: directive still references 'Stash and continue' (v0.42.0 removed sub-step 5a)" >&2; exit 1; }
! grep -qE 'pre-deploy-stash\.txt' "$DIRECTIVE" \
  || { echo "FAIL: directive still references pre-deploy-stash.txt (v0.42.0 dropped stash machinery)" >&2; exit 1; }
pass "6. commands/deploy.md does NOT contain legacy 5a AskUserQuestion options"

# Invariant 7: bin/deploy-init.sh gates rc=7 behind --branch flag (BRANCH_OVERRIDE)
INIT="bin/deploy-init.sh"
grep -qE 'NO_BRANCH == 0.*BRANCH_OVERRIDE|BRANCH_OVERRIDE.*NO_BRANCH == 0' "$INIT" \
  || { echo "FAIL: bin/deploy-init.sh should gate branch_create behind BRANCH_OVERRIDE presence" >&2; exit 1; }
pass "7. bin/deploy-init.sh gates auto-branch path behind --branch flag"

# Invariant 8: CLAUDE.md Current focus names v0.42.0
grep -qE 'Most recent merge:.*v0\.42\.0' CLAUDE.md \
  || { echo "FAIL: CLAUDE.md Current focus should name v0.42.0" >&2; exit 1; }
pass "8. CLAUDE.md Current focus names v0.42.0"

pass "test_v0_42_0_static_wiring: 8 invariants locked"
