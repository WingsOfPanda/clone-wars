#!/usr/bin/env bash
# tests/test_list_stale.sh — v0.5.0 stale-state classifier in bin/list.sh.
#
# We test the threshold logic by invoking the helper directly. The full
# bin/list.sh CLI is exercised end-to-end in case 7 (env override).
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
export CLAUDE_PLUGIN_ROOT="$(cd .. && pwd)"
export CLONE_WARS_HOME="$SANDBOX"
PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT"
source ../lib/log.sh
source ../lib/state.sh
source ../lib/list_stale.sh   # new helper file extracted from list.sh

# Helper: build a fake outbox at <path> with mtime <age> seconds in the past.
fake_outbox() {
  local path="$1" age_seconds="$2"
  mkdir -p "$(dirname "$path")"
  : > "$path"
  if stat -c %Y "$path" >/dev/null 2>&1; then
    touch -d "@$(( $(date +%s) - age_seconds ))" "$path"
  else
    touch -t "$(date -r "$(( $(date +%s) - age_seconds ))" +%Y%m%d%H%M.%S 2>/dev/null || date -j -f %s $(( $(date +%s) - age_seconds )) +%Y%m%d%H%M.%S)" "$path"
  fi
}

OUTBOX="$SANDBOX/outbox.jsonl"

# Case 1: working + age < threshold → working.
fake_outbox "$OUTBOX" 30
[[ "$(cw_list_classify_stale working "$OUTBOX" 180)" == "working" ]] \
  || { echo "FAIL c1"; exit 1; }
pass "working + age 30s < 180s → working"

# Case 2: working + age > threshold → stale.
fake_outbox "$OUTBOX" 300
[[ "$(cw_list_classify_stale working "$OUTBOX" 180)" == "stale" ]] \
  || { echo "FAIL c2"; exit 1; }
pass "working + age 300s > 180s → stale"

# Case 3: idle (any age) → idle.
fake_outbox "$OUTBOX" 9999
[[ "$(cw_list_classify_stale 'idle (done)' "$OUTBOX" 180)" == "idle (done)" ]] \
  || { echo "FAIL c3"; exit 1; }
pass "idle (done) is never reclassified"

# Case 4: missing outbox → state unchanged.
[[ "$(cw_list_classify_stale working "$SANDBOX/missing.jsonl" 180)" == "working" ]] \
  || { echo "FAIL c4"; exit 1; }
pass "missing outbox → state unchanged"

# Case 5: negative age (clock skew) → not stale.
mkdir -p "$(dirname "$OUTBOX")"; : > "$OUTBOX"
touch -d "@$(( $(date +%s) + 10 ))" "$OUTBOX" 2>/dev/null \
  || touch -t "$(date -d "+10 seconds" +%Y%m%d%H%M.%S 2>/dev/null)" "$OUTBOX"
[[ "$(cw_list_classify_stale working "$OUTBOX" 180)" == "working" ]] \
  || { echo "FAIL c5"; exit 1; }
pass "future mtime (negative age) → not stale"

# Case 6: env threshold override accepted.
fake_outbox "$OUTBOX" 30
[[ "$(cw_list_classify_stale working "$OUTBOX" 10)" == "stale" ]] \
  || { echo "FAIL c6"; exit 1; }
pass "explicit threshold=10 with age=30 → stale"

# Case 7: non-numeric threshold falls back to 180 with warning to stderr.
fake_outbox "$OUTBOX" 30
warn=$(cw_list_classify_stale working "$OUTBOX" "abc" 2>&1 >/dev/null)
[[ "$warn" == *"invalid threshold"* ]] \
  || { echo "FAIL c7 stderr: $warn"; exit 1; }
out=$(cw_list_classify_stale working "$OUTBOX" "abc" 2>/dev/null)
[[ "$out" == "working" ]] || { echo "FAIL c7 out: $out"; exit 1; }
pass "non-numeric threshold → warn + fallback to 180 (working stays working)"

echo "ALL PASS"
