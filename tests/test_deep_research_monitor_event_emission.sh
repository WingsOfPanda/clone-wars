#!/usr/bin/env bash
# tests/test_deep_research_monitor_event_emission.sh — v0.28.0
# Monitor watches outbox.jsonl and emits notification lines on stdout.
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
: > "$OUTBOX"

# Run monitor in background, capture stdout to a file
"$PLUGIN_ROOT/bin/deep-research-monitor.sh" "$ART" rex > "$TMP/monitor.out" 2>&1 &
MON_PID=$!
sleep 1

# Emit a done event
echo '{"event":"done","summary":"exp-001 metric=0.97 status=ok","ts":"2026-05-13T08:01:00Z"}' >> "$OUTBOX"
sleep 3

# Monitor should have printed a notification line containing "done"
grep -q 'done' "$TMP/monitor.out" \
  || { echo "FAIL: monitor didn't emit on done event:" >&2; cat "$TMP/monitor.out" >&2; exit 1; }
pass "monitor emits notification on done event"

# Emit error event
echo '{"event":"error","summary":"crash","ts":"2026-05-13T08:02:00Z"}' >> "$OUTBOX"
sleep 3
grep -q 'error' "$TMP/monitor.out" \
  || { echo "FAIL: monitor didn't emit on error event" >&2; cat "$TMP/monitor.out" >&2; exit 1; }
pass "monitor emits notification on error event"

# Cleanup
kill "$MON_PID" 2>/dev/null || true
wait "$MON_PID" 2>/dev/null || true
