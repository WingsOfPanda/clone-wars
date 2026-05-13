#!/usr/bin/env bash
# tests/test_deep_research_finalize_cleanup.sh — v0.28.0 finalize cleanup
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

source "$PLUGIN_ROOT/lib/state.sh"
REPO_HASH=$(cw_repo_hash)
TOPIC=deep-research-finalize-test
ART="$CLONE_WARS_HOME/state/$REPO_HASH/$TOPIC/_deep-research"
mkdir -p "$ART/troopers/rex" "$ART/troopers/cody"
echo "rex" > "$ART/troopers.txt"
echo "cody" >> "$ART/troopers.txt"
echo "$TOPIC" > "$ART/active.txt"
echo "user-halted" > "$ART/halt.flag"
echo "fake-topic" > "$ART/topic.txt"
echo "none" > "$ART/time-budget.txt"
date -u +%Y-%m-%dT%H:%M:%SZ > "$ART/session-start.txt"

# Per-trooper state: rex working, cody idle
cat > "$ART/troopers/rex/state.txt" <<'EOF'
exp_counter=3
phase=working
current_exp_id=exp-003
last_event_ts=2026-05-13T08:00:00Z
last_event=ack
probe_sent_ts=
EOF
cat > "$ART/troopers/cody/state.txt" <<'EOF'
exp_counter=2
phase=idle
current_exp_id=
last_event_ts=2026-05-13T08:01:00Z
last_event=done
probe_sent_ts=
EOF

# Mock outbox files
TD="$CLONE_WARS_HOME/state/$REPO_HASH/$TOPIC"
mkdir -p "$TD/rex-codex" "$TD/cody-codex"
echo '{"event":"ack","ts":"2026-05-13T08:00:00Z"}' > "$TD/rex-codex/outbox.jsonl"
echo '{"event":"done","ts":"2026-05-13T08:01:00Z"}' > "$TD/cody-codex/outbox.jsonl"

# Empty scoreboard
cat > "$ART/scoreboard.md" <<'EOF'
# Scoreboard

| Rank | Experiment | Commander | Metric | Status | Runtime | Approach |
|---|---|---|---|---|---|---|
EOF

# Minimal metric.md
cat > "$ART/metric.md" <<'EOF'
**Primary metric:** accuracy
**Direction:** maximize
**min_acceptable:** >= 0.90
**target:** >= 0.99
**K_corroboration:** 1
**plateau_window:** 5
**plateau_threshold:** 0.01
EOF

# Run finalize
rc=0; "$PLUGIN_ROOT/bin/deep-research-finalize.sh" "$TOPIC" >/tmp/finalize.out 2>&1 || rc=$?
[[ "$rc" == "0" ]] || { echo "FAIL: finalize rc=$rc" >&2; cat /tmp/finalize.out >&2; exit 1; }

# active.txt removed
[[ ! -f "$ART/active.txt" ]] \
  || { echo "FAIL: active.txt still exists" >&2; exit 1; }
pass "finalize removes active.txt"

# Per-trooper state phase updated
rex_phase=$(awk -F= '/^phase=/{print $2}' "$ART/troopers/rex/state.txt")
cody_phase=$(awk -F= '/^phase=/{print $2}' "$ART/troopers/cody/state.txt")
[[ "$rex_phase" == "incomplete" ]] \
  || { echo "FAIL: rex should be incomplete (was working at halt); got $rex_phase" >&2; exit 1; }
[[ "$cody_phase" == "complete" ]] \
  || { echo "FAIL: cody should be complete (was idle at halt); got $cody_phase" >&2; exit 1; }
pass "trooper phases set correctly (working→incomplete, idle→complete)"

# session-summary.md updated with ## Halt section
grep -q '## Halt' "$ART/session-summary.md" \
  || { echo "FAIL: session-summary missing Halt section" >&2; cat "$ART/session-summary.md" >&2; exit 1; }
grep -q 'user-halted' "$ART/session-summary.md" \
  || { echo "FAIL: Halt section missing reason" >&2; exit 1; }
pass "session-summary has Halt section with reason"

# Idempotency — running again should not error
rc=0; "$PLUGIN_ROOT/bin/deep-research-finalize.sh" "$TOPIC" 2>/dev/null || rc=$?
[[ "$rc" == "0" ]] || { echo "FAIL: idempotent run rc=$rc" >&2; exit 1; }
pass "finalize is idempotent"
