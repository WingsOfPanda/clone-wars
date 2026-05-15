#!/usr/bin/env bash
# tests/test_deep_research_monitor_liveness_thresholds.sh — v0.28.0
# Monitor emits 'stale' notification when outbox mtime crosses threshold.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"; kill %1 2>/dev/null || true' EXIT

ART="$TMP/_deep-research"
mkdir -p "$ART/troopers/rex"
TOPIC_DIR=$(dirname "$ART")
mkdir -p "$TOPIC_DIR/rex-codex"
OUTBOX="$TOPIC_DIR/rex-codex/outbox.jsonl"
echo '{"event":"ack","ts":"2026-05-13T08:00:00Z"}' > "$OUTBOX"

# v0.32.0 #1: Monitor is now phase-aware and emits stale/stuck only when
# phase=working. Pre-write state.txt so the existing assertion still holds.
cat > "$ART/troopers/rex/state.txt" <<EOF2
exp_counter=1
phase=working
current_exp_id=exp-001
last_event_ts=2026-05-13T08:00:00Z
last_event=dispatched
probe_sent_ts=
EOF2

# Short thresholds via env override for the test
export CW_DEEP_RESEARCH_PROBE_S=3 CW_DEEP_RESEARCH_STUCK_S=6

"$PLUGIN_ROOT/bin/deep-research-monitor.sh" "$ART" rex > "$TMP/monitor.out" 2>&1 &
MON_PID=$!
sleep 1

# Touch the outbox so we have a known recent mtime
touch "$OUTBOX"

# Wait past PROBE_S — should emit stale notification
sleep 5
grep -q 'stale' "$TMP/monitor.out" \
  || { echo "FAIL: monitor didn't emit stale on mtime crossing:" >&2; cat "$TMP/monitor.out" >&2; exit 1; }
pass "monitor emits stale when mtime crosses PROBE_S"

# Wait further past STUCK_S — should emit stuck notification
sleep 5
grep -q 'stuck' "$TMP/monitor.out" \
  || { echo "FAIL: monitor didn't emit stuck on second threshold:" >&2; cat "$TMP/monitor.out" >&2; exit 1; }
pass "monitor emits stuck when mtime crosses STUCK_S"

# Cleanup
kill "$MON_PID" 2>/dev/null || true
wait "$MON_PID" 2>/dev/null || true
