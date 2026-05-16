#!/usr/bin/env bash
# v0.35.0 Layer B — mtime liveness probe in cw_consult_wait
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
TMP=$(mktemp -d)
TOUCHER=""
cleanup() {
  if [[ -n "$TOUCHER" ]]; then
    kill "$TOUCHER" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT
export CLONE_WARS_HOME="$TMP"

source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/contracts.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/consult-wait.sh"

# Tight timing knobs so the test runs in seconds, not minutes.
export CW_CONSULT_RESEARCH_TIMEOUT_OVERRIDE=2
export CW_CONSULT_LIVENESS_PROBE_S=2
export CW_CONSULT_LIVENESS_GRACE_S=2
export CW_CONSULT_MAX_DEADLINE_FACTOR=2

# Use codex provider (multiplier 1.0) so timing math is predictable.
cat > "$TMP/contracts.yaml" <<'EOF'
codex:
  binary: codex
  default_mode: full
  ready_timeout_s: 90
  bootstrap_sleep_s: 20
EOF

setup_topic() {
  local topic="$1" cmdr="${2:-rex}"
  local topic_dir art_dir trooper_dir state_file outbox
  topic_dir="$(cw_topic_state_dir "$topic")"
  art_dir="$topic_dir/_consult"
  trooper_dir="$topic_dir/$cmdr-codex"
  mkdir -p "$art_dir" "$trooper_dir"
  state_file="$art_dir/research-$cmdr.txt"
  outbox="$trooper_dir/outbox.jsonl"
  printf 'OFFSET=0\n' > "$state_file"
  : > "$outbox"
  printf '%s %s\n' "$state_file" "$outbox"
}

# Case 1: stale outbox → real timeout, NO grace log line.
read -r STATE_FILE OUTBOX < <(setup_topic consult-stale-1 rex)
touch -d "@$(($(date +%s) - 600))" "$OUTBOX"   # outbox 10 min stale

logs=$(cw_consult_wait research consult-stale-1 rex codex 2>&1 || true)
grep -q '^FS=timeout' "$STATE_FILE" \
  || { echo "FAIL: case 1 expected FS=timeout in state file"; cat "$STATE_FILE"; echo "logs: $logs"; exit 1; }
echo "$logs" | grep -q 'alive' \
  && { echo "FAIL: case 1 should NOT show 'alive' grace log"; echo "$logs"; exit 1; }
pass "1. stale outbox → real timeout, no grace extension"

# Case 2: fresh outbox → grace extension fires, but hits hard cap eventually.
# Background toucher keeps mtime fresh until hard cap fires.
read -r STATE_FILE OUTBOX < <(setup_topic consult-fresh-2 rex)
touch "$OUTBOX"

( for _ in 1 2 3 4 5 6 7 8 9 10; do touch "$OUTBOX"; sleep 1; done ) &
TOUCHER=$!

logs=$(cw_consult_wait research consult-fresh-2 rex codex 2>&1 || true)
kill "$TOUCHER" 2>/dev/null || true
TOUCHER=""

grep -q '^FS=timeout' "$STATE_FILE" \
  || { echo "FAIL: case 2 expected FS=timeout after hard cap"; cat "$STATE_FILE"; echo "logs: $logs"; exit 1; }
echo "$logs" | grep -qE 'alive .* grace, hard cap' \
  || { echo "FAIL: case 2 expected 'alive ... grace, hard cap' log line"; echo "$logs"; exit 1; }
pass "2. fresh outbox → grace extension fires; hard cap eventually wins"

# Case 3: PROBE_S=0 disables probe (escape hatch) — fresh outbox, immediate timeout.
read -r STATE_FILE OUTBOX < <(setup_topic consult-disabled-3 rex)
touch "$OUTBOX"   # very fresh

logs=$(CW_CONSULT_LIVENESS_PROBE_S=0 cw_consult_wait research consult-disabled-3 rex codex 2>&1 || true)
grep -q '^FS=timeout' "$STATE_FILE" \
  || { echo "FAIL: case 3 expected FS=timeout with probe disabled"; cat "$STATE_FILE"; echo "logs: $logs"; exit 1; }
echo "$logs" | grep -q 'alive' \
  && { echo "FAIL: case 3 PROBE_S=0 should NOT extend"; echo "$logs"; exit 1; }
pass "3. PROBE_S=0 disables probe (v0.34 behavior preserved)"

echo "test_consult_wait_liveness_probe: 3 cases passed"
