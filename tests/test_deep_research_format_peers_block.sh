#!/usr/bin/env bash
# tests/test_deep_research_format_peers_block.sh — v0.45.0 Lane A
# Locks: cw_deep_research_format_peers_block reads $art_dir + current
# commander, emits a "## Peers" section with rows for all OTHER
# rostered commanders, or empty when N=1. Per-peer columns sourced
# from state.txt + most-recent exp-NNN/result.json. Robust to missing
# peer state files (renders '?' / '—' cells).
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

seed_trooper() {
  local art="$1" cmdr="$2" phase="$3" current="$4"
  mkdir -p "$art/troopers/$cmdr/experiments"
  cat > "$art/troopers/$cmdr/state.txt" <<EOF
exp_counter=0
phase=$phase
current_exp_id=$current
last_event_ts=
last_event=spawn
probe_sent_ts=
EOF
}

seed_result_json() {
  local art="$1" cmdr="$2" exp="$3" approach="$4" metric="$5" status="$6" notes="$7"
  local d="$art/troopers/$cmdr/experiments/$exp"
  mkdir -p "$d"
  cat > "$d/result.json" <<EOF
{
  "branch_id": "$exp",
  "approach_label": "$approach",
  "metric_name": "accuracy",
  "metric_value": $metric,
  "status": "$status",
  "runtime_s": 12,
  "log_paths": ["./stdout.log"],
  "notes": "$notes"
}
EOF
}

# Case 1: N=2 with 1 peer scored
ART1="$SANDBOX/case1/_deep-research"
mkdir -p "$ART1"
printf 'rex\nkeeli\n' > "$ART1/troopers.txt"
seed_trooper "$ART1" rex   idle    ""
seed_trooper "$ART1" keeli idle    ""
seed_result_json "$ART1" keeli exp-001 "Plain CNN" 0.9821 ok "param-shrink to 96k worked"

out=$(cw_deep_research_format_peers_block "$ART1" rex)
echo "$out" | grep -qE '^## Peers$' \
  || { echo "FAIL: case1 missing '## Peers' header" >&2; echo "$out" >&2; exit 1; }
echo "$out" | grep -qE '\| keeli' \
  || { echo "FAIL: case1 missing keeli row" >&2; echo "$out" >&2; exit 1; }
if echo "$out" | grep -qE '\| rex'; then
  echo "FAIL: case1 current commander (rex) should NOT appear in own peers table" >&2
  echo "$out" >&2
  exit 1
fi
echo "$out" | grep -q 'Plain CNN' \
  || { echo "FAIL: case1 missing approach_label for keeli" >&2; echo "$out" >&2; exit 1; }
echo "$out" | grep -q '0.9821' \
  || { echo "FAIL: case1 missing metric_value for keeli" >&2; echo "$out" >&2; exit 1; }
echo "$out" | grep -q 'param-shrink to 96k' \
  || { echo "FAIL: case1 missing notes excerpt for keeli" >&2; echo "$out" >&2; exit 1; }
echo "$out" | grep -qiE 'diverge|different corner' \
  || { echo "FAIL: case1 missing divergence guidance paragraph" >&2; echo "$out" >&2; exit 1; }
pass "1. N=2 with 1 scored peer emits ## Peers + 1 row excluding current commander"

# Case 2: N=1 solo session → empty output, rc=0
ART2="$SANDBOX/case2/_deep-research"
mkdir -p "$ART2"
printf 'rex\n' > "$ART2/troopers.txt"
seed_trooper "$ART2" rex idle ""
out=$(cw_deep_research_format_peers_block "$ART2" rex)
[[ -z "$out" ]] \
  || { echo "FAIL: case2 N=1 solo should emit empty output, got:" >&2; echo "$out" >&2; exit 1; }
pass "2. N=1 solo session emits empty output (no ## Peers header)"

# Case 3: N=2 peer has no result.json yet
ART3="$SANDBOX/case3/_deep-research"
mkdir -p "$ART3"
printf 'rex\nkeeli\n' > "$ART3/troopers.txt"
seed_trooper "$ART3" rex   working exp-001
seed_trooper "$ART3" keeli working exp-001
out=$(cw_deep_research_format_peers_block "$ART3" rex)
echo "$out" | grep -qE '^## Peers$' \
  || { echo "FAIL: case3 missing '## Peers' header" >&2; echo "$out" >&2; exit 1; }
echo "$out" | grep -qE '\| keeli' \
  || { echo "FAIL: case3 missing keeli row" >&2; echo "$out" >&2; exit 1; }
echo "$out" | grep -qE '\| keeli .*\| working' \
  || { echo "FAIL: case3 keeli row missing phase=working" >&2; echo "$out" >&2; exit 1; }
echo "$out" | grep -qE '\| keeli .*—' \
  || { echo "FAIL: case3 keeli row missing '—' cell for absent result.json" >&2; echo "$out" >&2; exit 1; }
pass "3. N=2 peer-without-result.json renders row with '—' cells"

# Case 4: N=3 with abandoned peer
ART4="$SANDBOX/case4/_deep-research"
mkdir -p "$ART4"
printf 'rex\nkeeli\ncody\n' > "$ART4/troopers.txt"
seed_trooper "$ART4" rex   idle      ""
seed_trooper "$ART4" keeli abandoned ""
seed_trooper "$ART4" cody  idle      ""
seed_result_json "$ART4" cody exp-001 "Transformer" 0.9742 ok "seq-len 28 was bottleneck"
out=$(cw_deep_research_format_peers_block "$ART4" rex)
row_count=$(echo "$out" | grep -cE '^\| (keeli|cody)' || true)
[[ "$row_count" == "2" ]] \
  || { echo "FAIL: case4 expected 2 peer rows, got $row_count" >&2; echo "$out" >&2; exit 1; }
echo "$out" | grep -qE '\| keeli .*\| abandoned' \
  || { echo "FAIL: case4 keeli row missing phase=abandoned" >&2; echo "$out" >&2; exit 1; }
echo "$out" | grep -qE '\| cody .*Transformer' \
  || { echo "FAIL: case4 cody row missing Transformer approach" >&2; echo "$out" >&2; exit 1; }
pass "4. N=3 with abandoned peer renders both peer rows including abandoned phase"

# Case 5: missing art-dir → rc=2
set +e
out=$(cw_deep_research_format_peers_block "$SANDBOX/nonexistent" rex 2>&1)
rc=$?
set -e
[[ "$rc" == "2" ]] \
  || { echo "FAIL: case5 missing art-dir should rc=2, got $rc" >&2; echo "$out" >&2; exit 1; }
pass "5. missing art-dir returns rc=2 with stderr message"

echo "test_deep_research_format_peers_block: 5 cases passed"
