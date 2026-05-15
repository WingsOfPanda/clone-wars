#!/usr/bin/env bash
# tests/test_deep_research_monitor_rescan.sh — v0.32.0 #2
# Locks: Monitor periodic rescan re-reads outbox and emits done/error/
# question events with (rescan) suffix, suppressing duplicates via
# liveness-rescan-emitted.txt. Heartbeats are ignored.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; kill %1 2>/dev/null || true' EXIT

ART="$TMP/_deep-research"
mkdir -p "$ART/troopers/rex"
TOPIC_DIR=$(dirname "$ART")
mkdir -p "$TOPIC_DIR/rex-codex"
OUTBOX="$TOPIC_DIR/rex-codex/outbox.jsonl"
: > "$OUTBOX"

cat > "$ART/troopers/rex/state.txt" <<EOF
exp_counter=1
phase=working
current_exp_id=exp-001
last_event_ts=2026-05-15T08:00:00Z
last_event=dispatched
probe_sent_ts=
EOF

# Disable byte-tail by pre-seeding cursor past end-of-file. This forces
# the test to rely entirely on the rescan loop for emission — proving the
# safety net works even when byte-tail misses every event.
echo 999999999 > "$ART/troopers/rex/liveness-cursor.txt"

# Fast rescan, disable liveness probes
export CW_DEEP_RESEARCH_RESCAN_EVERY_S=2
export CW_DEEP_RESEARCH_PROBE_S=600 CW_DEEP_RESEARCH_STUCK_S=1800

"$PLUGIN_ROOT/bin/deep-research-monitor.sh" "$ART" rex > "$TMP/monitor.out" 2>&1 &
MON_PID=$!
sleep 1

# Append a done event and a heartbeat
echo '{"event":"done","summary":"exp-001 metric=0.9","ts":"2026-05-15T08:01:00Z"}' >> "$OUTBOX"
echo '{"event":"heartbeat","summary":"epoch 5/10","ts":"2026-05-15T08:01:30Z"}' >> "$OUTBOX"
sleep 4   # past one rescan tick

grep -q '(rescan)' "$TMP/monitor.out" \
  || { echo "FAIL: rescan didn't fire within RESCAN_EVERY_S:" >&2; cat "$TMP/monitor.out" >&2; exit 1; }
grep -q '"event":"done".*rescan' "$TMP/monitor.out" \
  || { echo "FAIL: rescan emit didn't include done event with (rescan) suffix:" >&2; cat "$TMP/monitor.out" >&2; exit 1; }
pass "1. rescan emits done event with (rescan) suffix"

if grep -q '"event":"heartbeat".*rescan' "$TMP/monitor.out"; then
  echo "FAIL: rescan should NOT forward heartbeats:" >&2
  cat "$TMP/monitor.out" >&2
  exit 1
fi
pass "2. rescan does not forward heartbeat events"

# Wait for a second rescan tick — should NOT re-emit the already-rescanned done
PREV_COUNT=$(grep -c '"event":"done".*rescan' "$TMP/monitor.out" || echo 0)
sleep 4
NEW_COUNT=$(grep -c '"event":"done".*rescan' "$TMP/monitor.out" || echo 0)
[[ "$PREV_COUNT" == "$NEW_COUNT" ]] \
  || { echo "FAIL: rescan re-emitted already-rescanned event (PREV=$PREV_COUNT NEW=$NEW_COUNT):" >&2; cat "$TMP/monitor.out" >&2; exit 1; }
pass "3. liveness-rescan-emitted.txt suppresses duplicate rescan emits"

# Append a NEW done event — rescan should pick it up on next tick
echo '{"event":"done","summary":"exp-002 metric=0.95","ts":"2026-05-15T08:05:00Z"}' >> "$OUTBOX"
sleep 4
grep -q 'exp-002.*rescan' "$TMP/monitor.out" \
  || { echo "FAIL: rescan didn't pick up new done event:" >&2; cat "$TMP/monitor.out" >&2; exit 1; }
pass "4. rescan picks up new done events between ticks"

kill "$MON_PID" 2>/dev/null || true
wait "$MON_PID" 2>/dev/null || true
echo "test_deep_research_monitor_rescan: 4 cases passed"
