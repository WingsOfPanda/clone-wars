#!/usr/bin/env bash
# tests/test_outbox_wait.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/state.sh
source ../lib/ipc.sh

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

DIR=$(cw_trooper_dir rex codex demo)
mkdir -p "$DIR"

# 1. Single-event API still works (backward compat with Phase 1's call sites).
#    Signature: cw_outbox_wait <commander> <model> <topic> <event> <timeout>
:> "$DIR/outbox.jsonl"
echo '{"event":"ready","ts":"2026-04-27T00:00:00Z"}' >> "$DIR/outbox.jsonl"
LINE=$(cw_outbox_wait rex codex demo ready 2)
assert_contains "$LINE" '"event":"ready"' "single-event call returns the line"
pass "single-event API preserved"

# 2. Multi-event varargs call: events are positional args between topic and
#    timeout (the locked spec shape). ready already in outbox → returned.
LINE=$(cw_outbox_wait rex codex demo ready error 2)
assert_contains "$LINE" '"event":"ready"' "multi-event varargs hits ready"
pass "multi-event varargs API hits ready"

# 3. Short-circuit: ONLY error in the outbox; multi-event call returns the
#    error line WITHIN the timeout window (not after exhausting it).
:> "$DIR/outbox.jsonl"
echo '{"event":"error","message":"bootstrap failed","fatal":true,"ts":"2026-04-27T00:00:00Z"}' >> "$DIR/outbox.jsonl"
START=$(date +%s)
LINE=$(cw_outbox_wait rex codex demo ready error 30)
END=$(date +%s)
ELAPSED=$((END - START))
assert_contains "$LINE" '"event":"error"' "short-circuit returns error line"
[[ "$ELAPSED" -lt 5 ]] || { echo "FAIL: short-circuit took ${ELAPSED}s — should be <5s, got full timeout" >&2; exit 1; }
pass "short-circuit on error within ${ELAPSED}s (timeout was 30s)"

# 4. Timeout case: empty outbox + 2s timeout → returns 1 with no output.
:> "$DIR/outbox.jsonl"
LINE=$(cw_outbox_wait rex codex demo ready error 2 2>/dev/null) && CODE=0 || CODE=$?
assert_eq "$CODE" "1" "timeout returns rc=1"
[[ -z "$LINE" ]] || { echo "FAIL: timeout produced output: '$LINE'" >&2; exit 1; }
pass "timeout returns rc=1 with no output"

# 5. False-positive immunity: outbox has a progress note containing the
#    literal text "event":"ready" — multi-event call should NOT short-circuit
#    on that, and DOES return when a real ready arrives.
cat > "$DIR/outbox.jsonl" <<'EOF'
{"event":"progress","note":"trooper said \"event\":\"ready\" in chat — but the protocol event hasn't fired","ts":"2026-04-27T00:00:00Z"}
{"event":"ready","ts":"2026-04-27T00:00:01Z"}
EOF
LINE=$(cw_outbox_wait rex codex demo ready error 2)
assert_contains "$LINE" '"ts":"2026-04-27T00:00:01Z"' "matched the real ready line, not the noisy progress note"
pass "false-positive immunity"

# 6. Three-event varargs (forward-compat for any future "done|error|ack" calls).
:> "$DIR/outbox.jsonl"
echo '{"event":"ack","task_summary":"ok","ts":"2026-04-27T00:00:00Z"}' >> "$DIR/outbox.jsonl"
LINE=$(cw_outbox_wait rex codex demo ready error ack 2)
assert_contains "$LINE" '"event":"ack"' "three-event varargs hits ack"
pass "three-event varargs"

echo "  ALL: ok"
