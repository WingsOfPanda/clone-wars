#!/usr/bin/env bash
# tests/test_deep_research_wait_stale_done_event.sh — v0.27.2 BUG #6 lock
# When the trooper's outbox.jsonl contains a stale done event for a prior
# experiment ID, the wait shim must skip it (log_warn) and continue
# polling for the done event whose summary contains the expected EXP_ID.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/contracts.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/consult-wait.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

REPO_HASH=$(cw_repo_hash)
TOPIC=deep-research-stale-done-test
TD="$CLONE_WARS_HOME/state/$REPO_HASH/$TOPIC"
ART="$TD/_deep-research"
CMDR_DIR="$TD/keeli-codex"
mkdir -p "$ART" "$CMDR_DIR"

# Stage outbox.jsonl with a PHANTOM done (exp-001) followed by the
# REAL done (exp-002). The OFFSET we'll set is past the "ready" line, so
# both done events are after the offset.
cat > "$CMDR_DIR/outbox.jsonl" <<'EOF'
{"event":"ready","ts":"2026-05-12T11:42:22Z","commander":"keeli","model":"codex"}
{"event":"done","summary":"experiment exp-001 metric=0.5 status=ok","ts":"2026-05-12T11:58:49Z"}
{"event":"ack","task_summary":"execute exp-002","ts":"2026-05-12T12:01:36Z"}
{"event":"done","summary":"experiment exp-002 metric=0.9977 status=ok","ts":"2026-05-12T12:14:37Z"}
EOF

# Stage minimal pane.json + status.json
echo '{"pane_id":"%9999","pid":99999,"spawned_at":"2026-05-12T00:00:00Z"}' > "$CMDR_DIR/pane.json"
echo '{"state":"working","updated":"2026-05-12T12:00:00Z","last_event":"ack"}' > "$CMDR_DIR/status.json"

# Stage state file with EXP_ID=exp-002 + OFFSET pointing past the ready
# line (byte count of the first line). The phantom exp-001 done starts
# at that offset.
READY_BYTES=$(head -1 "$CMDR_DIR/outbox.jsonl" | wc -c)
STATE_FILE="$ART/experiment-keeli.txt"
printf 'OFFSET=%s\nEXP_ID=exp-002\n' "$READY_BYTES" > "$STATE_FILE"

# Run the wait shim with a SHORT timeout (already-emitted events resolve
# instantly via cw_outbox_wait_since's existing-event detection).
export CW_DEEP_RESEARCH_EXPERIMENT_TIMEOUT_OVERRIDE=10
LOG=$(cw_consult_wait experiment "$TOPIC" keeli codex 2>&1)
rc=$?

[[ "$rc" == "0" ]] \
  || { echo "FAIL: cw_consult_wait rc=$rc; expected 0" >&2; echo "$LOG" >&2; exit 1; }

# Assert: stderr/log contains "stale done event ignored"
echo "$LOG" | grep -q "stale done event ignored" \
  || { echo "FAIL: stale-event warning missing from log:" >&2; echo "$LOG" >&2; exit 1; }
pass "wait shim emitted 'stale done event ignored' warning"

# Assert: state file final status is EX=ok (matched the exp-002 done)
grep -qE '^EX=ok$' "$STATE_FILE" \
  || { echo "FAIL: state file should end with EX=ok; got:" >&2; cat "$STATE_FILE" >&2; exit 1; }
pass "wait shim recorded EX=ok after matching exp-002 done"

# Assert: OFFSET in state file advanced past the phantom exp-001 done
# (not stuck at the initial READY_BYTES). The skip-path persists OFFSET;
# the final-match path doesn't (existing wait-shim contract — wait is
# one-shot post-match, so OFFSET-for-final-done would only matter on a
# wait-shim restart, which doesn't happen for a successfully-completed
# experiment).
FINAL_OFFSET=$(grep '^OFFSET=' "$STATE_FILE" | tail -1 | cut -d= -f2)
(( FINAL_OFFSET > READY_BYTES + 50 )) \
  || { echo "FAIL: final OFFSET ($FINAL_OFFSET) should be > READY_BYTES+50 ($READY_BYTES+50) — must have advanced past phantom; state file:" >&2; cat "$STATE_FILE" >&2; exit 1; }
pass "wait shim advanced OFFSET past phantom exp-001 done (restart-safe)"

# --- Negative case: no stale event, just exp-001 done with matching EXP_ID ---
cat > "$CMDR_DIR/outbox.jsonl" <<'EOF'
{"event":"ready","ts":"2026-05-12T11:42:22Z","commander":"keeli","model":"codex"}
{"event":"done","summary":"experiment exp-001 metric=0.99 status=ok","ts":"2026-05-12T11:58:49Z"}
EOF
READY_BYTES=$(head -1 "$CMDR_DIR/outbox.jsonl" | wc -c)
printf 'OFFSET=%s\nEXP_ID=exp-001\n' "$READY_BYTES" > "$STATE_FILE"

LOG2=$(cw_consult_wait experiment "$TOPIC" keeli codex 2>&1)
rc=$?
[[ "$rc" == "0" ]] || { echo "FAIL: matching-EXP_ID case rc=$rc" >&2; echo "$LOG2" >&2; exit 1; }

# stderr should NOT contain "stale done event ignored"
if echo "$LOG2" | grep -q "stale done event ignored"; then
  echo "FAIL: matching-EXP_ID case should NOT emit stale warning" >&2
  echo "$LOG2" >&2
  exit 1
fi
pass "matching-EXP_ID case: no stale warning emitted"
