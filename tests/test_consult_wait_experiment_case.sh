#!/usr/bin/env bash
# tests/test_consult_wait_experiment_case.sh — BUG #2: cw_consult_wait must
# handle kind=experiment without 'unbound variable' error on the done event.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/contracts.sh"
source "$PLUGIN_ROOT/lib/consult-wait.sh"

TMPHOME=$(mktemp -d); trap 'rm -rf "$TMPHOME"' EXIT
export CLONE_WARS_HOME="$TMPHOME"

# Build minimal fake state for a "rex codex deep-research-foo" trooper:
# outbox.jsonl pre-populated with a 'done' event so cw_consult_wait returns
# immediately on the experiment-case branch.
REPO_HASH=$(cw_repo_hash)
TOPIC=deep-research-foo
TOPIC_DIR="$TMPHOME/state/$REPO_HASH/$TOPIC"
ART_DIR="$TOPIC_DIR/_deep-research"
mkdir -p "$TOPIC_DIR/rex-codex" "$ART_DIR"
cat > "$TOPIC_DIR/rex-codex/outbox.jsonl" <<'EOF'
{"event":"ready","ts":"2026-05-12T00:00:00Z"}
{"event":"done","summary":"exp done","ts":"2026-05-12T00:01:00Z"}
EOF

# Pre-create state file (offset=0 so we read from the start)
cat > "$ART_DIR/experiment-rex.txt" <<'EOF'
OFFSET=0
EOF

# Capture stderr from cw_consult_wait — assert NO unbound-variable error
err=$(CW_DEEP_RESEARCH_EXPERIMENT_TIMEOUT_OVERRIDE=5 \
  cw_consult_wait experiment "$TOPIC" rex codex 2>&1 >/dev/null) || true
[[ "$err" != *"unbound variable"* ]] \
  || { echo "FAIL: stderr contains unbound variable; got:" >&2; echo "$err" >&2; exit 1; }
pass "cw_consult_wait experiment does not error with unbound variable"

# Also assert the state file got an EX=ok line written
grep -q '^EX=ok$' "$ART_DIR/experiment-rex.txt" \
  || { echo "FAIL: state file missing EX=ok; got:" >&2; cat "$ART_DIR/experiment-rex.txt" >&2; exit 1; }
pass "state file records EX=ok"

echo "test_consult_wait_experiment_case: 2 assertions green"
