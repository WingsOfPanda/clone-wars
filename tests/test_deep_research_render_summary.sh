#!/usr/bin/env bash
# tests/test_deep_research_render_summary.sh — v0.28.0 session-summary render
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
ART="$TMP/_deep-research"
mkdir -p "$ART/troopers/rex" "$ART/troopers/cody"

# Seed inputs
echo "fake-topic" > "$ART/topic.txt"
cat > "$ART/metric.md" <<'EOF'
**Primary metric:** accuracy
**Direction:** maximize
**min_acceptable:** >= 0.90
**target:** >= 0.99
**K_corroboration:** 1
**plateau_window:** 5
**plateau_threshold:** 0.01
EOF
cat > "$ART/troopers.txt" <<'EOF'
rex
cody
EOF
echo "none" > "$ART/time-budget.txt"
date -u +%Y-%m-%dT%H:%M:%SZ > "$ART/session-start.txt"

# Production 7-col scoreboard schema (bin/deep-research-score.sh:77):
# | Rank | Experiment | Commander | Metric | Status | Runtime | Approach |
cat > "$ART/scoreboard.md" <<'EOF'
# Scoreboard

| Rank | Experiment | Commander | Metric | Status | Runtime | Approach |
|---|---|---|---|---|---|---|
| 1 | exp-002 | rex | 0.991 | ok | 110s | approach-b |
| 2 | exp-001 | rex | 0.97 | ok | 100s | approach-a |
EOF

cat > "$ART/troopers/rex/state.txt" <<'EOF'
exp_counter=3
phase=working
current_exp_id=exp-003
last_event_ts=2026-05-13T08:42:18Z
last_event=ack
probe_sent_ts=
EOF
cat > "$ART/troopers/cody/state.txt" <<'EOF'
exp_counter=2
phase=idle
current_exp_id=
last_event_ts=2026-05-13T08:40:00Z
last_event=done
probe_sent_ts=
EOF

# Seed outboxes at topic-dir/<cmdr>-codex/outbox.jsonl
TOPIC_DIR=$(dirname "$ART")
mkdir -p "$TOPIC_DIR/rex-codex" "$TOPIC_DIR/cody-codex"
cat > "$TOPIC_DIR/rex-codex/outbox.jsonl" <<'EOF'
{"event":"ready","ts":"2026-05-13T08:00:00Z"}
{"event":"ack","ts":"2026-05-13T08:30:00Z"}
{"event":"done","summary":"exp-002 metric=0.991 status=ok","ts":"2026-05-13T08:42:18Z"}
EOF
cat > "$TOPIC_DIR/cody-codex/outbox.jsonl" <<'EOF'
{"event":"ready","ts":"2026-05-13T08:05:00Z"}
{"event":"done","summary":"exp-001 metric=0.95 status=ok","ts":"2026-05-13T08:40:00Z"}
EOF

cw_deep_research_render_summary "$ART" > "$ART/session-summary.md"
OUT=$(cat "$ART/session-summary.md")

# Section headers present
assert_contains "$OUT" "# Research session" "title section"
assert_contains "$OUT" "## Status" "Status section"
assert_contains "$OUT" "## Scoreboard top 5" "Scoreboard section"
assert_contains "$OUT" "## Completion check" "Completion check section"
assert_contains "$OUT" "## Recent events" "Recent events section"

# Title block content
assert_contains "$OUT" "fake-topic" "topic in title"
assert_contains "$OUT" "Time budget: none" "time-budget rendered"

# Status content
assert_contains "$OUT" "rex" "rex in status"
assert_contains "$OUT" "working" "rex phase shown"
assert_contains "$OUT" "exp-003" "rex current shown"
assert_contains "$OUT" "cody" "cody in status"
assert_contains "$OUT" "idle" "cody phase shown"

# Scoreboard top-5 (only 2 rows but section should render them)
assert_contains "$OUT" "exp-002" "scoreboard row"
assert_contains "$OUT" "0.991" "scoreboard metric"

# Completion check shows signals
assert_contains "$OUT" "Floor" "Floor label"
assert_contains "$OUT" "Target" "Target label"
assert_contains "$OUT" "MET" "MET marker (target hit)"
assert_contains "$OUT" "K corroboration" "K corroboration label"
assert_contains "$OUT" "Plateau" "Plateau label"

# Recent events should include events from both troopers
assert_contains "$OUT" "rex/done" "rex done event in Recent events"
assert_contains "$OUT" "cody/done" "cody done event in Recent events"

pass "session-summary.md renders all required sections"
