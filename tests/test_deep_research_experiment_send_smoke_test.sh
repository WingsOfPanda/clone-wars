#!/usr/bin/env bash
# tests/test_deep_research_experiment_send_smoke_test.sh
# v0.43.0 Lane C: --smoke-test handling for deep-research-experiment-send.sh.
# 4 cases: missing script, fail, pass, timeout (with CW_SMOKE_TEST_TIMEOUT_OVERRIDE=2).
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
cd "$SANDBOX"
export CLONE_WARS_HOME="$SANDBOX/.clone-wars"
export CW_DEEP_RESEARCH_DRY_RUN=1

# Seed one rex-codex topic per case (each case uses its own TOPIC so artifacts
# don't collide).
seed_topic() {
  local topic=$1
  local td art
  td="$(cw_topic_state_dir "$topic")"
  art="$td/_deep-research"
  mkdir -p "$art/troopers/rex" "$td/rex-codex"
  echo "$topic" > "$art/topic.txt"
  echo "rex" > "$art/troopers.txt"
  cat > "$art/metric.md" <<'M'
# Research goal

**Primary metric:** test_metric
**Direction:** maximize
M
  cw_deep_research_trooper_state_write "$art" rex \
    exp_counter=0 phase=idle current_exp_id= last_event=spawn
  : > "$td/rex-codex/outbox.jsonl"
  echo "$art"
}

# --- Case 1: missing smoke-test script → rc=2 before any state mutation ---
TOPIC=deep-research-smoke-missing
ART=$(seed_topic "$TOPIC")
set +e
out=$("$PLUGIN_ROOT/bin/deep-research-experiment-send.sh" \
        --smoke-test "$SANDBOX/does-not-exist.sh" \
        "$TOPIC" rex exp-001 dummy-approach "dummy brief" 2>&1)
rc=$?
set -e
assert_eq "$rc" "2" "missing smoke-test script should exit 2"
assert_contains "$out" "smoke-test" "missing case: error mentions smoke-test"
[[ ! -d "$ART/troopers/rex/experiments/exp-001" ]] \
  || { echo "FAIL: branch dir created before smoke-test validation" >&2; exit 1; }
pass "1. missing smoke-test script → rc=2 before any state mutation"

# --- Case 2: smoke-test fails → rc=2, .err captured, state preserved ---
TOPIC=deep-research-smoke-fail
ART=$(seed_topic "$TOPIC")
SCRIPT="$SANDBOX/smoke-fail.sh"
cat > "$SCRIPT" <<'EOF'
#!/usr/bin/env bash
echo "synthetic failure" >&2
exit 1
EOF
chmod +x "$SCRIPT"
set +e
out=$("$PLUGIN_ROOT/bin/deep-research-experiment-send.sh" \
        --smoke-test "$SCRIPT" \
        "$TOPIC" rex exp-001 dummy-approach "dummy brief" 2>&1)
rc=$?
set -e
assert_eq "$rc" "2" "fail case: smoke-test failure should exit 2"
BRANCH_DIR="$ART/troopers/rex/experiments/exp-001"
assert_file_exists "$BRANCH_DIR/smoke-test.err" "fail case: smoke-test.err captured"
ERR_BODY=$(cat "$BRANCH_DIR/smoke-test.err")
assert_contains "$ERR_BODY" "synthetic failure" "fail case: stderr captured in smoke-test.err"
cur_phase=$(cw_deep_research_trooper_state_field "$ART" rex phase)
assert_eq "$cur_phase" "idle" "fail case: trooper state unchanged"
pass "2. smoke-test fails → rc=2, .err captured, state preserved"

# --- Case 3: smoke-test passes → dispatch proceeds, prompt.md rendered ---
TOPIC=deep-research-smoke-pass
ART=$(seed_topic "$TOPIC")
SCRIPT="$SANDBOX/smoke-pass.sh"
cat > "$SCRIPT" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$SCRIPT"
"$PLUGIN_ROOT/bin/deep-research-experiment-send.sh" \
  --smoke-test "$SCRIPT" \
  "$TOPIC" rex exp-001 dummy-approach "dummy brief"
BRANCH_DIR="$ART/troopers/rex/experiments/exp-001"
assert_file_exists "$BRANCH_DIR/prompt.md" "pass case: prompt.md rendered"
[[ ! -f "$BRANCH_DIR/smoke-test.err" ]] \
  || { echo "FAIL: smoke-test.err present after successful smoke" >&2; exit 1; }
pass "3. smoke-test exits 0 → dispatch proceeds, prompt.md written"

# --- Case 4: smoke-test hangs → SIGKILLed via timeout override, rc=2 ---
TOPIC=deep-research-smoke-timeout
ART=$(seed_topic "$TOPIC")
export CW_SMOKE_TEST_TIMEOUT_OVERRIDE=2  # 2 seconds, not 60
SCRIPT="$SANDBOX/smoke-hang.sh"
cat > "$SCRIPT" <<'EOF'
#!/usr/bin/env bash
sleep 30
EOF
chmod +x "$SCRIPT"
set +e
START=$(date +%s)
out=$("$PLUGIN_ROOT/bin/deep-research-experiment-send.sh" \
        --smoke-test "$SCRIPT" \
        "$TOPIC" rex exp-001 dummy-approach "dummy brief" 2>&1)
rc=$?
END=$(date +%s)
ELAPSED=$(( END - START ))
set -e
assert_eq "$rc" "2" "timeout case: smoke-test timeout should exit 2"
[[ "$ELAPSED" -lt 10 ]] \
  || { echo "FAIL: timeout took ${ELAPSED}s; expected < 10s with 2s override" >&2; exit 1; }
assert_contains "$out" "smoke-test" "timeout case: error mentions smoke-test"
pass "4. smoke-test hang → SIGKILL after timeout, rc=2"

echo "test_deep_research_experiment_send_smoke_test: 4 cases passed"
