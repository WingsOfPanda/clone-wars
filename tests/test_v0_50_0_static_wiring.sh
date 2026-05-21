#!/usr/bin/env bash
# tests/test_v0_50_0_static_wiring.sh — v0.50 static-wiring lock.
# Skip-guarded: passes via SKIP until plugin.json version reaches 0.50.0,
# then activates and enforces all 7 invariants.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
PLUGIN_JSON="$PLUGIN_ROOT/.claude-plugin/plugin.json"
MARKETPLACE_JSON="$PLUGIN_ROOT/.claude-plugin/marketplace.json"

CUR_VER=$(awk -F'"' '/"version":/ { print $4; exit }' "$PLUGIN_JSON")
if [[ "$CUR_VER" != "0.50.0" ]]; then
  pass "SKIP — plugin.json version is $CUR_VER (lock active only at 0.50.0)"
  echo "test_v0_50_0_static_wiring: skip-pass"
  exit 0
fi

# Invariant 1: plugin.json AND marketplace.json both at 0.50.0
mp_count=$(grep -c '"version": *"0\.50\.0"' "$MARKETPLACE_JSON")
assert_eq "$mp_count" "2" "INV1: marketplace.json has both version lines at 0.50.0"
pass "INV1. plugin.json + marketplace.json at 0.50.0"

# Invariant 2: lib/trooper-questions.sh defines cw_trooper_question_verify
grep -qE '^cw_trooper_question_verify\(\)' "$PLUGIN_ROOT/lib/trooper-questions.sh" \
  || { echo "FAIL INV2: cw_trooper_question_verify definition not found" >&2; exit 1; }
pass "INV2. cw_trooper_question_verify defined"

# Invariant 3: bin/deploy-turn-wait.sh lists "question" in the wait set
grep -qE 'cw_outbox_wait_since cody codex .* done error question ' "$PLUGIN_ROOT/bin/deploy-turn-wait.sh" \
  || { echo "FAIL INV3: question not in deploy-turn-wait wait set" >&2; exit 1; }
pass "INV3. deploy-turn-wait listens for question event"

# Invariant 4: cw_deploy_build_turn_prompt_round1 heredoc contains BLOCKERS / QUESTIONS
# Use awk to scope the search to the function body so a stray comment elsewhere
# in lib/deploy.sh doesn't false-positive.
awk '
  /^cw_deploy_build_turn_prompt_round1\(\)/ { in_fn=1 }
  in_fn && /^}/                              { in_fn=0 }
  in_fn                                      { print }
' "$PLUGIN_ROOT/lib/deploy.sh" | grep -q "BLOCKERS / QUESTIONS" \
  || { echo "FAIL INV4: BLOCKERS / QUESTIONS missing from cw_deploy_build_turn_prompt_round1" >&2; exit 1; }
pass "INV4. round1 prompt contains BLOCKERS / QUESTIONS"

# Invariant 5: cw_deploy_build_turn_prompt_fix heredoc contains BLOCKERS / QUESTIONS
awk '
  /^cw_deploy_build_turn_prompt_fix\(\)/ { in_fn=1 }
  in_fn && /^}/                          { in_fn=0 }
  in_fn                                  { print }
' "$PLUGIN_ROOT/lib/deploy.sh" | grep -q "BLOCKERS / QUESTIONS" \
  || { echo "FAIL INV5: BLOCKERS / QUESTIONS missing from cw_deploy_build_turn_prompt_fix" >&2; exit 1; }
pass "INV5. fix prompt contains BLOCKERS / QUESTIONS"

# Invariant 6: consult prompt templates reference bin/trooper-ask.sh
grep -q 'bin/trooper-ask.sh' "$PLUGIN_ROOT/config/prompt-templates/consult/research.md" \
  || { echo "FAIL INV6a: bin/trooper-ask.sh missing from consult/research.md" >&2; exit 1; }
grep -q 'bin/trooper-ask.sh' "$PLUGIN_ROOT/config/prompt-templates/consult/verify.md" \
  || { echo "FAIL INV6b: bin/trooper-ask.sh missing from consult/verify.md" >&2; exit 1; }
pass "INV6. consult research + verify templates reference trooper-ask.sh"

# Invariant 7: trooper-ask.sh and inbox-ack.sh exist and are executable
[[ -x "$PLUGIN_ROOT/bin/trooper-ask.sh" ]] \
  || { echo "FAIL INV7a: bin/trooper-ask.sh not executable" >&2; exit 1; }
[[ -x "$PLUGIN_ROOT/bin/inbox-ack.sh" ]] \
  || { echo "FAIL INV7b: bin/inbox-ack.sh not executable" >&2; exit 1; }
pass "INV7. trooper-ask.sh + inbox-ack.sh both exist + executable"

echo "test_v0_50_0_static_wiring: 7 invariants passed"
