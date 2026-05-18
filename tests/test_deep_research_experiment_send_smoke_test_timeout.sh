#!/usr/bin/env bash
# tests/test_deep_research_experiment_send_smoke_test_timeout.sh
# v0.43.0 Lane C: --smoke-test that hangs longer than the timeout is SIGKILLed
# and treated as failure (rc=2). Test uses CW_SMOKE_TEST_TIMEOUT_OVERRIDE=2
# to avoid waiting 60s.
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
export CW_SMOKE_TEST_TIMEOUT_OVERRIDE=2   # 2 seconds, not 60

TOPIC=deep-research-smoke-timeout
TD="$(cw_topic_state_dir "$TOPIC")"
ART="$TD/_deep-research"
mkdir -p "$ART/troopers/rex" "$TD/rex-codex"
echo "$TOPIC" > "$ART/topic.txt"
echo "rex" > "$ART/troopers.txt"
cat > "$ART/metric.md" <<'M'
# Research goal

**Primary metric:** test_metric
**Direction:** maximize
M
cw_deep_research_trooper_state_write "$ART" rex \
  exp_counter=0 phase=idle current_exp_id= last_event=spawn
: > "$TD/rex-codex/outbox.jsonl"

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

assert_eq "$rc" "2" "smoke-test timeout should exit 2"
[[ "$ELAPSED" -lt 10 ]] \
  || { echo "FAIL: timeout took ${ELAPSED}s; expected < 10s with 2s override" >&2; exit 1; }
assert_contains "$out" "smoke-test" "error mentions smoke-test"
pass "1. smoke-test hang → SIGKILL after timeout, rc=2"

echo "test_deep_research_experiment_send_smoke_test_timeout: 1 case passed"
