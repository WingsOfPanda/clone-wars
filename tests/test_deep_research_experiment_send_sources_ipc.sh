#!/usr/bin/env bash
# tests/test_deep_research_experiment_send_sources_ipc.sh — v0.28.1 BUG #1 lock.
# experiment-send.sh must source lib/ipc.sh; otherwise cw_outbox_offset
# fires "command not found" at every dispatch (v0.28.0 dogfood regression).
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

# Static-wiring: the bin script must source lib/ipc.sh
grep -qE '^source[[:space:]]+"\$PLUGIN_ROOT/lib/ipc\.sh"' \
  "$PLUGIN_ROOT/bin/deep-research-experiment-send.sh" \
  || { echo "FAIL: deep-research-experiment-send.sh does not source lib/ipc.sh" >&2; exit 1; }
pass "deep-research-experiment-send.sh sources lib/ipc.sh"

# Runtime: end-to-end dispatch must NOT emit 'command not found' on stderr.
# Reuses the same DRY_RUN scaffolding as test_deep_research_experiment_send_multiline_brief.sh.
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"
mkdir -p "$CLONE_WARS_HOME"
echo "codex" > "$CLONE_WARS_HOME/providers-available.txt"

TOPIC=$("$PLUGIN_ROOT/bin/deep-research-init.sh" "v028.1 bug1 source ipc")
source "$PLUGIN_ROOT/lib/state.sh"
REPO_HASH=$(cw_repo_hash)
TD="$CLONE_WARS_HOME/state/$REPO_HASH/$TOPIC"
ART="$TD/_deep-research"

cat > "$ART/metric.md" <<'EOF'
# Research goal

**Primary metric:** accuracy
**Direction:** maximize
EOF

{
  printf 'detected_at\t2026-05-13T00:00:00Z\n'
  printf 'gpu\tNVIDIA L20\t49140\t30000\t580.126.09\n'
} > "$ART/hardware.txt"

mkdir -p "$TD/rex-codex"
echo '{"pane_id":"%9999","pid":99999,"spawned_at":"2026-05-13T00:00:00Z"}' > "$TD/rex-codex/pane.json"
echo '' > "$TD/rex-codex/outbox.jsonl"
echo '{"state":"working","updated":"2026-05-13T00:00:00Z","last_event":"ready"}' > "$TD/rex-codex/status.json"

source "$PLUGIN_ROOT/lib/deep-research.sh"
mkdir -p "$ART/troopers/rex/experiments"
cw_deep_research_trooper_state_write "$ART" rex \
  exp_counter=0 phase=idle current_exp_id= \
  last_event_ts=2026-05-13T00:00:00Z last_event=spawn probe_sent_ts=

# Capture stderr. Must NOT contain 'cw_outbox_offset: command not found'.
export CW_DEEP_RESEARCH_DRY_RUN=1
err=$("$PLUGIN_ROOT/bin/deep-research-experiment-send.sh" \
  "$TOPIC" rex exp-001 "ipc-source-test" "Ensure ipc.sh helpers are sourced." 2>&1 >/dev/null)

if echo "$err" | grep -q 'cw_outbox_offset: command not found'; then
  echo "FAIL: dispatch emitted 'cw_outbox_offset: command not found' on stderr" >&2
  echo "$err" >&2
  exit 1
fi
pass "dispatch stderr clean of 'command not found' for cw_outbox_offset"

echo "test_deep_research_experiment_send_sources_ipc: 2 assertions green"
