#!/usr/bin/env bash
# tests/test_v0_23_1_static_wiring.sh
# Locks v0.23.1 invariants:
#   1. cw_cmdr_rank function exists in lib/commanders.sh and ranks
#      rex/cody/wolffe/hunter/thorn/echo correctly
#   2. commands/deploy.md upfront task table OMITS the legacy
#      "3b  DAG wave dispatch (multi-repo)" row (replaced by per-trooper
#      sub-rows created at runtime)
#   3. commands/deploy.md Step 3b sources lib/commanders.sh
#   4. commands/deploy.md Step 3b prose contains the per-(wave,repo)
#      TaskCreate directive with subject pattern "3b.<step> <Rank>
#      <Cmdr> on <repo> [wave <w>]"
#   5. REPO_TO_TASK_ID associative-array declaration + at least one
#      TaskUpdate(taskId=...) reference
#   6. plugin.json semver-shape (loosened per v0.20.2 lesson)
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"

# 1. cw_cmdr_rank lookup behavior
COMMANDERS_SH="$PLUGIN_ROOT/lib/commanders.sh"
grep -qE '^cw_cmdr_rank\(\)' "$COMMANDERS_SH" \
  || { echo "FAIL: cw_cmdr_rank() function not defined in lib/commanders.sh" >&2; exit 1; }
# Functional smoke: source + invoke + assert known mappings
RANK_REX=$(bash -c "source '$COMMANDERS_SH'; cw_cmdr_rank rex")
RANK_CODY=$(bash -c "source '$COMMANDERS_SH'; cw_cmdr_rank cody")
RANK_WOLFFE=$(bash -c "source '$COMMANDERS_SH'; cw_cmdr_rank wolffe")
RANK_HUNTER=$(bash -c "source '$COMMANDERS_SH'; cw_cmdr_rank hunter")
RANK_THORN=$(bash -c "source '$COMMANDERS_SH'; cw_cmdr_rank thorn")
RANK_ECHO=$(bash -c "source '$COMMANDERS_SH'; cw_cmdr_rank echo")
[[ "$RANK_REX"    == "Captain"    ]] || { echo "FAIL: cw_cmdr_rank rex != Captain (got '$RANK_REX')" >&2; exit 1; }
[[ "$RANK_CODY"   == "Commander"  ]] || { echo "FAIL: cw_cmdr_rank cody != Commander (got '$RANK_CODY')" >&2; exit 1; }
[[ "$RANK_WOLFFE" == "Commander"  ]] || { echo "FAIL: cw_cmdr_rank wolffe != Commander (got '$RANK_WOLFFE')" >&2; exit 1; }
[[ "$RANK_HUNTER" == "Sergeant"   ]] || { echo "FAIL: cw_cmdr_rank hunter != Sergeant (got '$RANK_HUNTER')" >&2; exit 1; }
[[ "$RANK_THORN"  == "Lieutenant" ]] || { echo "FAIL: cw_cmdr_rank thorn != Lieutenant (got '$RANK_THORN')" >&2; exit 1; }
[[ "$RANK_ECHO"   == "Trooper"    ]] || { echo "FAIL: cw_cmdr_rank echo != Trooper (got '$RANK_ECHO')" >&2; exit 1; }
pass "cw_cmdr_rank exists + ranks rex/cody/wolffe/hunter/thorn/echo correctly"

DEPLOY_MD="$PLUGIN_ROOT/commands/deploy.md"

# 2. Upfront task table OMITS the legacy 3b row
# The table is bounded by '## Task list' and the next '## ' heading. Capture
# into a variable to avoid SIGPIPE under pipefail (per v0.21.0 lesson).
TABLE=$(awk '/^## Task list/,/^### Step 0/' "$DEPLOY_MD")
[[ -n "$TABLE" ]] \
  || { echo "FAIL: Upfront task table not located" >&2; exit 1; }
# Negative-assert: the legacy "3b  DAG wave dispatch" row must NOT appear in
# the table (the v0.23.0 wording is "3b  DAG wave dispatch (multi-repo)").
[[ "$TABLE" != *'3b  DAG wave dispatch (multi-repo)'* ]] \
  || { echo "FAIL: Upfront table still contains legacy '3b  DAG wave dispatch (multi-repo)' row" >&2; exit 1; }
# Positive-assert: the explanatory note about runtime 3b creation appears
[[ "$TABLE" == *'3b'*'absent'*'runtime'* ]] \
  || { echo "FAIL: Upfront table missing explanatory note about runtime 3b creation" >&2; exit 1; }
pass "Upfront task table omits legacy 3b row + explains runtime creation"

# 3. Step 3b sources lib/commanders.sh
STEP_3B=$(awk '/^### Step 3b /,/^### Step 3c /' "$DEPLOY_MD")
[[ -n "$STEP_3B" ]] \
  || { echo "FAIL: Step 3b body not located" >&2; exit 1; }
[[ "$STEP_3B" == *'source "${CLAUDE_PLUGIN_ROOT}/lib/commanders.sh"'* ]] \
  || { echo "FAIL: Step 3b does not source lib/commanders.sh (expected braced \${CLAUDE_PLUGIN_ROOT} per v0.39.0 migration)" >&2; exit 1; }
pass "Step 3b sources lib/commanders.sh for cw_cmdr_rank"

# 4. Per-(wave,repo) TaskCreate directive with the canonical subject pattern
[[ "$STEP_3B" == *'TaskCreate'* ]] \
  || { echo "FAIL: Step 3b missing TaskCreate directive" >&2; exit 1; }
# Subject pattern check: the literal token "3b.\$step" or "3b.<step>" appears
# in the TaskCreate directive prose (the dollar-step form is what the
# directive literally instructs the conductor to use)
[[ "$STEP_3B" == *'3b.$step'* || "$STEP_3B" == *'3b.<step>'* ]] \
  || { echo "FAIL: Step 3b TaskCreate subject missing '3b.<step>' / '3b.\$step' pattern" >&2; exit 1; }
# activeForm pattern check
[[ "$STEP_3B" == *'implementing'* ]] \
  || { echo "FAIL: Step 3b TaskCreate activeForm missing 'implementing <repo>' pattern" >&2; exit 1; }
# cw_cmdr_rank invocation present in the directive prose
[[ "$STEP_3B" == *'cw_cmdr_rank'* ]] \
  || { echo "FAIL: Step 3b directive doesn't reference cw_cmdr_rank" >&2; exit 1; }
pass "Step 3b has per-(wave,repo) TaskCreate directive with canonical subject + activeForm patterns"

# 5. REPO_TO_TASK_ID associative-array + TaskUpdate references
[[ "$STEP_3B" == *'declare -A REPO_TO_TASK_ID'* ]] \
  || { echo "FAIL: Step 3b missing 'declare -A REPO_TO_TASK_ID'" >&2; exit 1; }
TASKUPDATE_COUNT=$(printf '%s' "$STEP_3B" | grep -cE 'TaskUpdate\(taskId=\$\{REPO_TO_TASK_ID')
[[ "$TASKUPDATE_COUNT" -ge 2 ]] \
  || { echo "FAIL: Step 3b expected ≥2 TaskUpdate(taskId=\${REPO_TO_TASK_ID...) references (in_progress + completed); got $TASKUPDATE_COUNT" >&2; exit 1; }
pass "REPO_TO_TASK_ID declared + ≥2 TaskUpdate(taskId=\${REPO_TO_TASK_ID[\$repo]}) transitions"

# 6. plugin.json semver-shape
PJ="$PLUGIN_ROOT/.claude-plugin/plugin.json"
grep -qE '"version": "0\.[0-9]+\.[0-9]+"' "$PJ" \
  || { echo "FAIL: plugin.json missing semver-shape version field" >&2; exit 1; }
pass "plugin.json version field present + semver-shaped"

pass "v0.23.1 static wiring complete (6 invariants locked)"
