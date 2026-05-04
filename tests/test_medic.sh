#!/usr/bin/env bash
# tests/test_medic.sh — runs bin/medic.sh in a controlled $CLONE_WARS_HOME and inspects output.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

# Seed the state dir with shipped user-editable config so medic finds them.
# v0.5.2: identity-template.md is no longer copied to state-root — it's
# plugin-side-only now (medic validates $PLUGIN_ROOT/config/prompt-templates/
# directly).
mkdir -p "$CLONE_WARS_HOME"
cp ../config/contracts.yaml         "$CLONE_WARS_HOME/contracts.yaml"
cp ../config/commanders.yaml        "$CLONE_WARS_HOME/commanders.yaml"

# Run medic. Capture combined stdout+stderr; the exit code reflects medic's verdict.
out=$(bash ../bin/medic.sh 2>&1) || rc=$?
echo "--- medic output ---"
echo "$out"
echo "--- end ---"

# Test 1: tmux check appears in output.
assert_contains "$out" "tmux" "tmux check appears in output"
pass "tmux check present"

# Test 2: state-dir line shows the resolved CLONE_WARS_HOME.
assert_contains "$out" "$CLONE_WARS_HOME" "resolved state dir printed"
pass "state dir printed"

# Test 3: contracts.yaml line is mentioned.
assert_contains "$out" "contracts.yaml" "contracts.yaml line"
pass "contracts.yaml present"

# Test 4: at least one provider name appears.
[[ "$out" == *codex* || "$out" == *gemini* || "$out" == *claude* ]] \
  || { echo "FAIL: no provider mentioned" >&2; exit 1; }
pass "providers enumerated"

# Test 5: a Verdict line is present.
[[ "$out" == *"Verdict:"* ]] || { echo "FAIL: no Verdict line" >&2; exit 1; }
pass "verdict line present"

# --- legacy deploy env-var warnings (added with v0.8 single-turn refactor) ---
out=$(CW_DEPLOY_PLAN_TIMEOUT=999 bash ../bin/medic.sh 2>&1) || true
echo "$out" | grep -qi 'CW_DEPLOY_PLAN_TIMEOUT.*deprecated\|CW_DEPLOY_PLAN_TIMEOUT.*ignored' \
  || { echo "FAIL: medic should warn on CW_DEPLOY_PLAN_TIMEOUT" >&2; exit 1; }
pass "medic warns on legacy CW_DEPLOY_PLAN_TIMEOUT env var"

out=$(CW_DEPLOY_IMPLEMENT_TIMEOUT=999 bash ../bin/medic.sh 2>&1) || true
echo "$out" | grep -qi 'CW_DEPLOY_IMPLEMENT_TIMEOUT.*deprecated\|CW_DEPLOY_IMPLEMENT_TIMEOUT.*ignored' \
  || { echo "FAIL: medic should warn on CW_DEPLOY_IMPLEMENT_TIMEOUT" >&2; exit 1; }
pass "medic warns on legacy CW_DEPLOY_IMPLEMENT_TIMEOUT env var"

out=$(CW_DEPLOY_VERIFY_TIMEOUT=999 bash ../bin/medic.sh 2>&1) || true
echo "$out" | grep -qi 'CW_DEPLOY_VERIFY_TIMEOUT.*deprecated\|CW_DEPLOY_VERIFY_TIMEOUT.*ignored' \
  || { echo "FAIL: medic should warn on CW_DEPLOY_VERIFY_TIMEOUT" >&2; exit 1; }
pass "medic warns on legacy CW_DEPLOY_VERIFY_TIMEOUT env var"

out=$(CW_DEPLOY_FIX_TIMEOUT=999 bash ../bin/medic.sh 2>&1) || true
echo "$out" | grep -qi 'CW_DEPLOY_FIX_TIMEOUT.*deprecated\|CW_DEPLOY_FIX_TIMEOUT.*ignored' \
  || { echo "FAIL: medic should warn on CW_DEPLOY_FIX_TIMEOUT" >&2; exit 1; }
pass "medic warns on legacy CW_DEPLOY_FIX_TIMEOUT env var"

# Probe still passes after the refactor. As of v0.9 the probe ALSO
# smoke-tests cw_deploy_detect_provider; if that helper breaks, this
# assertion will catch it.
out=$(bash ../bin/medic.sh 2>&1) || true
echo "$out" | grep -q 'deploy helpers load clean' \
  || { echo "FAIL: medic deploy-helpers probe regressed" >&2; exit 1; }
pass "medic deploy-helpers probe still clean after refactor"
