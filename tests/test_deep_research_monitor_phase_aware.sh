#!/usr/bin/env bash
# tests/test_deep_research_monitor_phase_aware.sh — v0.32.0 #1
# Locks: bin/deep-research-monitor.sh emits stale/stuck only when phase=working.
# done/error/question events emit regardless of phase.
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
echo '{"event":"ack","ts":"2026-05-15T08:00:00Z"}' > "$OUTBOX"

# state.txt with phase=idle — Monitor should NOT emit stale/stuck even
# when mtime crosses thresholds
cat > "$ART/troopers/rex/state.txt" <<EOF
exp_counter=0
phase=idle
current_exp_id=
last_event_ts=
last_event=spawn
probe_sent_ts=
EOF

# Short thresholds via env override
export CW_DEEP_RESEARCH_PROBE_S=2 CW_DEEP_RESEARCH_STUCK_S=4
# Disable rescan in this test (T4 tests rescan separately)
export CW_DEEP_RESEARCH_RESCAN_EVERY_S=600

"$PLUGIN_ROOT/bin/deep-research-monitor.sh" "$ART" rex > "$TMP/monitor.out" 2>&1 &
MON_PID=$!
sleep 1
touch "$OUTBOX"     # force a recent mtime so the next sleep crosses threshold
sleep 5

if grep -q 'stale\|stuck' "$TMP/monitor.out"; then
  echo "FAIL: Monitor emitted stale/stuck on idle trooper (should be silent):" >&2
  cat "$TMP/monitor.out" >&2
  exit 1
fi
pass "1. phase=idle → no stale/stuck emitted past thresholds"

# Flip phase to working — Monitor should now fire stale within PROBE_S
cat > "$ART/troopers/rex/state.txt" <<EOF
exp_counter=1
phase=working
current_exp_id=exp-001
last_event_ts=2026-05-15T08:00:00Z
last_event=dispatched
probe_sent_ts=
EOF
touch "$OUTBOX"
sleep 4

if ! grep -q 'stale' "$TMP/monitor.out"; then
  echo "FAIL: Monitor didn't emit stale after phase flipped to working:" >&2
  cat "$TMP/monitor.out" >&2
  exit 1
fi
pass "2. phase=working → stale emitted past PROBE_S"

# done event must still emit regardless of phase — flip back to idle and
# append a done line
cat > "$ART/troopers/rex/state.txt" <<EOF
exp_counter=1
phase=idle
current_exp_id=
last_event_ts=
last_event=scored
probe_sent_ts=
EOF
echo '{"event":"done","summary":"exp-001 metric=0.97 status=ok","ts":"2026-05-15T08:05:00Z"}' >> "$OUTBOX"
sleep 3

if ! grep -q '"event":"done"' "$TMP/monitor.out"; then
  echo "FAIL: Monitor didn't emit done on phase=idle (events must be unconditional):" >&2
  cat "$TMP/monitor.out" >&2
  exit 1
fi
pass "3. done event emits even when phase=idle"

kill "$MON_PID" 2>/dev/null || true
wait "$MON_PID" 2>/dev/null || true
echo "test_deep_research_monitor_phase_aware: 3 cases passed"
