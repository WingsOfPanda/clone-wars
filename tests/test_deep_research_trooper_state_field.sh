#!/usr/bin/env bash
# tests/test_deep_research_trooper_state_field.sh — single-field reader contract.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"

declare -F cw_deep_research_trooper_state_field >/dev/null \
  || { echo "FAIL: cw_deep_research_trooper_state_field not defined" >&2; exit 1; }
pass "helper defined"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/troopers/rex"
cat > "$SANDBOX/troopers/rex/state.txt" <<'EOF'
phase=working
last_event_ts=2026-05-13T13:11:39Z
current_exp_id=exp-002
exp_counter=2
probe_sent_ts=
last_event=heartbeat
EOF

# Case 1: existing field returns value
got=$(cw_deep_research_trooper_state_field "$SANDBOX" rex phase)
[[ "$got" == "working" ]] || { echo "FAIL: phase: got '$got' want 'working'" >&2; exit 1; }
pass "phase=working"

# Case 2: another field
got=$(cw_deep_research_trooper_state_field "$SANDBOX" rex current_exp_id)
[[ "$got" == "exp-002" ]] || { echo "FAIL: current_exp_id: got '$got' want 'exp-002'" >&2; exit 1; }
pass "current_exp_id=exp-002"

# Case 3: empty-value field returns empty
got=$(cw_deep_research_trooper_state_field "$SANDBOX" rex probe_sent_ts)
[[ -z "$got" ]] || { echo "FAIL: probe_sent_ts: expected empty, got '$got'" >&2; exit 1; }
pass "empty value handled"

# Case 4: missing field returns empty
got=$(cw_deep_research_trooper_state_field "$SANDBOX" rex nonexistent)
[[ -z "$got" ]] || { echo "FAIL: missing field: expected empty, got '$got'" >&2; exit 1; }
pass "missing field returns empty"

# Case 5: missing state.txt returns rc=1
set +e
got=$(cw_deep_research_trooper_state_field "$SANDBOX" nobody phase 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "1" ]] || { echo "FAIL: missing state.txt rc=$rc, expected 1" >&2; exit 1; }
pass "missing state.txt returns rc=1"

# Case 6: value with embedded '=' preserved
cat > "$SANDBOX/troopers/rex/state.txt" <<'EOF'
notes=a=b=c
phase=idle
EOF
got=$(cw_deep_research_trooper_state_field "$SANDBOX" rex notes)
[[ "$got" == "a=b=c" ]] || { echo "FAIL: embedded equals: got '$got' want 'a=b=c'" >&2; exit 1; }
pass "embedded equals preserved"

echo "test_deep_research_trooper_state_field: 6 cases passed"
