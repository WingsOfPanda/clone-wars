#!/usr/bin/env bash
# tests/test_deep_research_monitor_cursor_persist.sh — v0.32.0 #3
# Locks: Monitor honors a pre-seeded liveness-cursor.txt on restart so
# pre-cursor events don't replay; falls back to current file size on
# corrupt or out-of-range cursors; writes cursor back after each tail pass.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
TMP=$(mktemp -d)
TMP2=$(mktemp -d)
trap 'rm -rf "$TMP" "$TMP2"; kill %1 %2 2>/dev/null || true' EXIT

ART="$TMP/_deep-research"
mkdir -p "$ART/troopers/rex"
TOPIC_DIR=$(dirname "$ART")
mkdir -p "$TOPIC_DIR/rex-codex"
OUTBOX="$TOPIC_DIR/rex-codex/outbox.jsonl"
CURSOR="$ART/troopers/rex/liveness-cursor.txt"

# Pre-populate outbox with 2 events
{
  echo '{"event":"ack","summary":"hello","ts":"2026-05-15T08:00:00Z"}'
  echo '{"event":"done","summary":"prior-exp-000 done","ts":"2026-05-15T08:01:00Z"}'
} > "$OUTBOX"

# Pre-seed cursor to the current byte size (i.e. all events are "previously seen")
PRE_SIZE=$(wc -c < "$OUTBOX" | tr -d ' ')
printf '%d' "$PRE_SIZE" > "$CURSOR"

# state.txt — phase=idle (we're not testing liveness here)
cat > "$ART/troopers/rex/state.txt" <<EOF
exp_counter=1
phase=idle
current_exp_id=
last_event_ts=
last_event=scored
probe_sent_ts=
EOF

export CW_DEEP_RESEARCH_PROBE_S=600 CW_DEEP_RESEARCH_STUCK_S=1800
export CW_DEEP_RESEARCH_RESCAN_EVERY_S=600   # disable rescan in this test

"$PLUGIN_ROOT/bin/deep-research-monitor.sh" "$ART" rex > "$TMP/monitor.out" 2>&1 &
MON_PID=$!
sleep 3

# Assert NO replay of pre-cursor events
if grep -q 'prior-exp-000' "$TMP/monitor.out"; then
  echo "FAIL: Monitor replayed pre-cursor event 'prior-exp-000':" >&2
  cat "$TMP/monitor.out" >&2
  exit 1
fi
pass "1. valid pre-seeded cursor → no replay of prior events"

# Append a fresh event AFTER startup — Monitor should emit it
echo '{"event":"done","summary":"new-exp-002","ts":"2026-05-15T08:02:00Z"}' >> "$OUTBOX"
sleep 3

if ! grep -q 'new-exp-002' "$TMP/monitor.out"; then
  echo "FAIL: Monitor didn't emit fresh event after restart:" >&2
  cat "$TMP/monitor.out" >&2
  exit 1
fi
pass "2. fresh events past restored cursor emit normally"

# Assert cursor has been written back (= post-emit byte position)
[[ -s "$CURSOR" ]] || { echo "FAIL: cursor file empty after tail pass" >&2; exit 1; }
NEW_VAL=$(cat "$CURSOR")
POST_SIZE=$(wc -c < "$OUTBOX" | tr -d ' ')
[[ "$NEW_VAL" =~ ^[0-9]+$ ]] || { echo "FAIL: cursor not numeric: $NEW_VAL" >&2; exit 1; }
[[ "$NEW_VAL" == "$POST_SIZE" ]] || { echo "FAIL: cursor=$NEW_VAL != post-size=$POST_SIZE" >&2; exit 1; }
pass "3. cursor file updated to current outbox size after emit"

kill "$MON_PID" 2>/dev/null || true
wait "$MON_PID" 2>/dev/null || true

# --- Restart with corrupt cursor → fallback to current size ---
ART2="$TMP2/_deep-research"
mkdir -p "$ART2/troopers/keeli"
mkdir -p "$(dirname "$ART2")/keeli-codex"
OUTBOX2="$(dirname "$ART2")/keeli-codex/outbox.jsonl"
CURSOR2="$ART2/troopers/keeli/liveness-cursor.txt"
echo '{"event":"done","summary":"should-skip","ts":"2026-05-15T08:00:00Z"}' > "$OUTBOX2"
printf 'garbage-not-a-number' > "$CURSOR2"
cat > "$ART2/troopers/keeli/state.txt" <<EOF
exp_counter=0
phase=idle
EOF
"$PLUGIN_ROOT/bin/deep-research-monitor.sh" "$ART2" keeli > "$TMP2/m.out" 2>&1 &
MP2=$!
sleep 2

if grep -q 'should-skip' "$TMP2/m.out"; then
  echo "FAIL: corrupt cursor should fall back to file-end (no replay), but emitted 'should-skip':" >&2
  cat "$TMP2/m.out" >&2
  kill "$MP2" 2>/dev/null || true
  exit 1
fi
pass "4. corrupt (non-numeric) cursor → fallback to file end (no replay)"

kill "$MP2" 2>/dev/null || true
wait "$MP2" 2>/dev/null || true

echo "test_deep_research_monitor_cursor_persist: 4 cases passed"
