#!/usr/bin/env bash
# tests/test_event_match.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/state.sh
source ../lib/ipc.sh

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 1. cw_event_match_pattern returns an anchored regex.
PAT=$(cw_event_match_pattern done)
assert_eq "$PAT" '^\{"event":"done"[,}]' "pattern shape"
pass "cw_event_match_pattern produces anchored regex"

# 2. Strict pattern correctly identifies a true {done} event.
OUTBOX="$TMP/outbox.jsonl"
echo '{"event":"done","summary":"ok","ts":"2026-04-27T00:00:00Z"}' > "$OUTBOX"
grep -qE "$(cw_event_match_pattern done)" "$OUTBOX" || { echo "FAIL: strict matcher missed a real done line" >&2; exit 1; }
pass "strict matcher hits real done"

# 3. Strict pattern does NOT match a progress event whose note contains the
#    literal text "event":"done" — exactly the false-positive class #7 closes.
cat > "$OUTBOX" <<'EOF'
{"event":"progress","note":"the trooper said \"event\":\"done\" but this is just a status note","ts":"2026-04-27T00:01:00Z"}
EOF
if grep -qE "$(cw_event_match_pattern done)" "$OUTBOX"; then
  echo "FAIL: strict matcher false-positives on a progress event with embedded text" >&2
  exit 1
fi
pass "strict matcher rejects progress note with embedded text"

# 4. Strict matcher picks the REAL done line out of an outbox that contains
#    both the noisy progress event AND a genuine done event afterward.
cat > "$OUTBOX" <<'EOF'
{"event":"ack","task_summary":"work","ts":"2026-04-27T00:00:00Z"}
{"event":"progress","note":"contains the literal substring \"event\":\"done\" inside","ts":"2026-04-27T00:00:30Z"}
{"event":"done","summary":"actually finished","ts":"2026-04-27T00:01:00Z"}
EOF
HIT=$(grep -E "$(cw_event_match_pattern done)" "$OUTBOX" | tail -n1)
assert_contains "$HIT" '"summary":"actually finished"' "matched the real done line"
pass "strict matcher selects real done from mixed outbox"

# 5. Empty event-name rejected (defensive — a caller passing "" would otherwise
#    construct a regex matching ANY event line).
PAT_EMPTY=$(cw_event_match_pattern '' 2>&1) && { echo "FAIL: empty event accepted" >&2; exit 1; }
pass "empty event rejected"

echo "  ALL: ok"
