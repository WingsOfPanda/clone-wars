#!/usr/bin/env bash
# tests/test_deep_research_experiment_send_auto_prefix.sh — v0.32.0 #7
# Locks: deep-research-experiment-send.sh auto-prefixes 'deep-research-' to
# a bare commander name, so `rex` becomes `deep-research-rex`.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
SANDBOX=$(mktemp -d)
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
export CLONE_WARS_HOME="$SANDBOX/.clone-wars"
mkdir -p "$CLONE_WARS_HOME"
trap 'rm -rf "$SANDBOX"' EXIT

source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"

# Set up a real-shaped art-dir for a topic 'deep-research-rex' so the
# script's later checks (art-dir exists, metric.md exists, state.txt exists)
# get past the prefix check we care about and reach an error we can identify
# without needing a real spawned trooper pane.
TOPIC_NAME="deep-research-rex"
REPO_HASH=$(cd "$SANDBOX" && cw_repo_hash)
TD="$CLONE_WARS_HOME/state/$REPO_HASH/$TOPIC_NAME"
ART="$TD/_deep-research"
mkdir -p "$ART/troopers/rex"
mkdir -p "$TD/rex-codex"
: > "$TD/rex-codex/outbox.jsonl"
# metric.md must exist for the dispatch to proceed past lines 50-52
cat > "$ART/metric.md" <<EOF
**Primary metric:** accuracy
**Direction:** maximize
EOF
# state.txt must exist with phase=idle to proceed past lines 57-62
cat > "$ART/troopers/rex/state.txt" <<EOF
exp_counter=0
phase=idle
current_exp_id=
last_event_ts=
last_event=
probe_sent_ts=
EOF
# hardware.txt for hardware probe diff (lines 95-103)
cat > "$ART/hardware.txt" <<EOF
detected_at	2026-05-15T00:00:00Z
no-gpu
EOF

# Call with bare topic 'rex' — should auto-prefix to 'deep-research-rex'
# and reach the missing-pane-id path (exit code 0 since the dispatch flow
# allows missing pane.json — it just logs a warning and exits OK). What
# we really care about: the topic validation step doesn't reject.
# A bare 'rex' under v0.31.0 returns rc=2 with "topic must start with".
( cd "$SANDBOX" \
  && CW_DEEP_RESEARCH_DRY_RUN=1 \
     "$PLUGIN_ROOT/bin/deep-research-experiment-send.sh" \
     rex rex exp-001 "test-approach" "test brief" 2>&1 ) \
  | tee "$SANDBOX/out.txt"
rc=${PIPESTATUS[0]}
[[ "$rc" == "0" ]] || { echo "FAIL: auto-prefix should let dispatch succeed under DRY_RUN; got rc=$rc" >&2; cat "$SANDBOX/out.txt" >&2; exit 1; }
if grep -q 'topic must start with' "$SANDBOX/out.txt"; then
  echo "FAIL: legacy 'topic must start with' message still present" >&2
  cat "$SANDBOX/out.txt" >&2
  exit 1
fi
pass "1. bare 'rex' auto-prefixes to 'deep-research-rex' and dispatch proceeds"

# Reset trooper state to idle so the second dispatch isn't blocked by
# the phase!=idle guard from case 1 (experiment-send sets phase=working).
cat > "$ART/troopers/rex/state.txt" <<EOF
exp_counter=1
phase=idle
current_exp_id=
last_event_ts=
last_event=scored
probe_sent_ts=
EOF

# Already-prefixed topic still works (idempotent — no double-prefix)
( cd "$SANDBOX" \
  && CW_DEEP_RESEARCH_DRY_RUN=1 \
     "$PLUGIN_ROOT/bin/deep-research-experiment-send.sh" \
     deep-research-rex rex exp-002 "test2" "brief2" 2>&1 ) \
  | tee "$SANDBOX/out2.txt"
rc=${PIPESTATUS[0]}
[[ "$rc" == "0" ]] || { echo "FAIL: already-prefixed topic must still work; got rc=$rc" >&2; cat "$SANDBOX/out2.txt" >&2; exit 1; }
if grep -q 'deep-research-deep-research-' "$SANDBOX/out2.txt"; then
  echo "FAIL: double-prefix detected; auto-prefix not idempotent" >&2
  cat "$SANDBOX/out2.txt" >&2
  exit 1
fi
pass "2. already-prefixed 'deep-research-rex' is not double-prefixed"

echo "test_deep_research_experiment_send_auto_prefix: 2 cases passed"
