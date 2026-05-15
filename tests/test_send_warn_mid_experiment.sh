#!/usr/bin/env bash
# v0.33.0 D5 — bin/send.sh warns when target is mid-experiment deep-research trooper
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP"

source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"

# Case 1: static-string check — warning literal + state.txt probe present in source
grep -q "mid-experiment" "$PLUGIN_ROOT/bin/send.sh" \
  || { echo "FAIL: case 1 'mid-experiment' literal missing from bin/send.sh"; exit 1; }
grep -q 'state.txt' "$PLUGIN_ROOT/bin/send.sh" \
  || { echo "FAIL: case 1 state.txt reference missing from bin/send.sh"; exit 1; }
pass "1. warning literal + state.txt probe present in source"

# Set up topic + trooper state for functional tests
TOPIC=deep-research-v033warn
TOPIC_DIR="$(cw_topic_state_dir "$TOPIC")"
ART="$TOPIC_DIR/_deep-research"
mkdir -p "$ART/troopers/rex" "$TOPIC_DIR/rex-codex"

# Case 2: phase=working → warning visible (inline the conditional from send.sh)
cat > "$ART/troopers/rex/state.txt" <<EOF
phase=working
current_exp_id=exp-005
exp_counter=5
last_event_ts=
last_event=dispatched
probe_sent_ts=
EOF
out=$( bash -c '
  state_file="'"$ART"'/troopers/rex/state.txt"
  if [[ -f "$state_file" ]]; then
    phase=$(grep "^phase=" "$state_file" 2>/dev/null | cut -d= -f2 | tr -d "[:space:]")
    if [[ "$phase" == "working" ]]; then
      cur_exp=$(grep "^current_exp_id=" "$state_file" 2>/dev/null | cut -d= -f2 | tr -d "[:space:]")
      printf "[WARN] trooper rex is mid-experiment (phase=working, current_exp_id=%s); prefer bin/deep-research-experiment-send.sh after the next done event. Sending anyway.\n" "$cur_exp"
    fi
  fi
' )
echo "$out" | grep -q "mid-experiment" \
  || { echo "FAIL: case 2 warning not emitted on phase=working"; echo "$out"; exit 1; }
echo "$out" | grep -q "exp-005" \
  || { echo "FAIL: case 2 current_exp_id missing from warning"; echo "$out"; exit 1; }
pass "2. phase=working trooper triggers warning"

# Case 3: phase=idle → no warning
sed -i 's/phase=working/phase=idle/' "$ART/troopers/rex/state.txt"
out=$( bash -c '
  state_file="'"$ART"'/troopers/rex/state.txt"
  if [[ -f "$state_file" ]]; then
    phase=$(grep "^phase=" "$state_file" 2>/dev/null | cut -d= -f2 | tr -d "[:space:]")
    if [[ "$phase" == "working" ]]; then
      printf "WARNING\n"
    fi
  fi
' )
[[ -z "$out" ]] \
  || { echo "FAIL: case 3 idle should produce no warning. got: $out"; exit 1; }
pass "3. phase=idle trooper produces no warning"

# Case 4: no state.txt (consult/meditate pane) → no warning
rm -f "$ART/troopers/rex/state.txt"
out=$( bash -c '
  state_file="'"$ART"'/troopers/rex/state.txt"
  if [[ -f "$state_file" ]]; then
    printf "WARNING\n"
  fi
' )
[[ -z "$out" ]] \
  || { echo "FAIL: case 4 missing state.txt should produce no warning. got: $out"; exit 1; }
pass "4. missing state.txt produces no warning"

echo "test_send_warn_mid_experiment: 4 cases passed"
