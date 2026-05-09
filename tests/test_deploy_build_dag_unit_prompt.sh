#!/usr/bin/env bash
# tests/test_deploy_build_dag_unit_prompt.sh
# Snapshot test for cw_deploy_build_dag_unit_prompt — verifies the
# heredoc resolves all placeholders for 3 canonical inputs.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/deploy.sh"

# --- Test A: root unit (no upstream)
result=$(cw_deploy_build_dag_unit_prompt "auth" "/path/design.md" "1" "3" "")
[[ "$result" == *'Your sub-repo is "auth"'* ]] || { echo "FAIL A: missing slug interp" >&2; exit 1; }
[[ "$result" == *"/path/design.md"* ]] || { echo "FAIL A: missing design path" >&2; exit 1; }
[[ "$result" == *"Step 1 of 3"* ]] || { echo "FAIL A: missing step/total" >&2; exit 1; }
[[ "$result" == *"none (this is a wave-1"* ]] || { echo "FAIL A: missing root-no-upstream sentinel" >&2; exit 1; }
! [[ "$result" == *'<slug>'* ]] || { echo "FAIL A: literal <slug> placeholder remains" >&2; exit 1; }
! [[ "$result" == *'<upstream-csv>'* ]] || { echo "FAIL A: literal <upstream-csv> placeholder remains" >&2; exit 1; }
pass "build_dag_unit_prompt: root unit fully interpolated"

# --- Test B: mid-DAG unit (single upstream)
result=$(cw_deploy_build_dag_unit_prompt "api" "/path/design.md" "2" "3" "auth")
[[ "$result" == *'Your sub-repo is "api"'* ]] || { echo "FAIL B: missing slug" >&2; exit 1; }
[[ "$result" == *"Step 2 of 3"* ]] || { echo "FAIL B: missing step/total" >&2; exit 1; }
[[ "$result" == *"you depend on: auth"* ]] || { echo "FAIL B: missing single upstream" >&2; exit 1; }
pass "build_dag_unit_prompt: single-upstream interpolated"

# --- Test C: join unit (multi-upstream)
result=$(cw_deploy_build_dag_unit_prompt "join" "/path/design.md" "4" "4" "auth,api,ui")
[[ "$result" == *'Your sub-repo is "join"'* ]] || { echo "FAIL C: missing slug" >&2; exit 1; }
[[ "$result" == *"Step 4 of 4"* ]] || { echo "FAIL C: missing step/total" >&2; exit 1; }
[[ "$result" == *"you depend on: auth, api, ui"* ]] || { echo "FAIL C: missing multi-upstream prettify" >&2; exit 1; }
pass "build_dag_unit_prompt: multi-upstream prettified"

# --- Test D: superpowers ceremony references all 3 skills
[[ "$result" == *"superpowers:writing-plans"* ]] || { echo "FAIL D: missing writing-plans" >&2; exit 1; }
[[ "$result" == *"superpowers:subagent-driven-development"* ]] || { echo "FAIL D: missing subagent-driven-development" >&2; exit 1; }
[[ "$result" == *"superpowers:verification-before-completion"* ]] || { echo "FAIL D: missing verification-before-completion" >&2; exit 1; }
pass "build_dag_unit_prompt: full superpowers ceremony in heredoc"

# --- Test E: missing arg → rc=2
err=$(cw_deploy_build_dag_unit_prompt 2>&1) && rc=0 || rc=$?
[[ "$rc" -eq 2 ]] || { echo "FAIL E: missing arg should rc=2 (got $rc)" >&2; exit 1; }
pass "build_dag_unit_prompt: missing arg rejects rc=2"

pass "all build_dag_unit_prompt tests green"
