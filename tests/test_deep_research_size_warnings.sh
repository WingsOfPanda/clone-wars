#!/usr/bin/env bash
# tests/test_deep_research_size_warnings.sh — v0.52.0 #24
# Validates cw_deep_research_compute_size_warnings: writes one TSV
# line per oversized experiment to warnings.txt; threshold defaults to
# 2 GB and is overridden by CW_DEEP_RESEARCH_SIZE_WARN_GB.
# Also validates cw_deep_research_render_summary emits ## Warnings.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

ART="$TMP/_deep-research"
mkdir -p "$ART/troopers/rex/experiments/exp-001"
mkdir -p "$ART/troopers/keeli/experiments/exp-001"
printf '%s\n' rex keeli > "$ART/troopers.txt"
echo "topic" > "$ART/topic.txt"
echo "2026-05-22T00:00:00Z" > "$ART/session-start.txt"
echo "none" > "$ART/time-budget.txt"
# Min state.txt for render
for c in rex keeli; do
  cat > "$ART/troopers/$c/state.txt" <<EOF
phase=idle
last_event_ts=2026-05-22T00:00:00Z
last_event=done
current_exp_id=
exp_counter=1
probe_sent_ts=
EOF
done

# Case 1: rex/exp-001 = 3 GB sparse file → warn at default 2 GB threshold
truncate -s 3G "$ART/troopers/rex/experiments/exp-001/blob.pt"
cw_deep_research_compute_size_warnings "$ART"
assert_file_exists "$ART/warnings.txt" "case1: warnings.txt written"
grep -q 'rex/exp-001' "$ART/warnings.txt" \
  || { echo "FAIL case1: rex/exp-001 missing from warnings.txt" >&2; exit 1; }
pass "case1: 3 GB experiment surfaces in warnings.txt"

# render_summary picks it up
out=$(cw_deep_research_render_summary "$ART")
echo "$out" | grep -q '^## Warnings' \
  || { echo "FAIL case1: render_summary missing ## Warnings"; echo "---"; echo "$out"; exit 1; }
echo "$out" | grep -q 'rex/exp-001' \
  || { echo "FAIL case1: render_summary Warnings missing rex/exp-001"; exit 1; }
pass "case1: render_summary emits ## Warnings section"

# Case 2: small experiments only → no warnings.txt entries, no ## Warnings section
rm -f "$ART/troopers/rex/experiments/exp-001/blob.pt"
truncate -s 100K "$ART/troopers/keeli/experiments/exp-001/small.pt"
cw_deep_research_compute_size_warnings "$ART"
[[ ! -s "$ART/warnings.txt" ]] \
  || { echo "FAIL case2: warnings.txt should be empty"; cat "$ART/warnings.txt"; exit 1; }
out=$(cw_deep_research_render_summary "$ART")
echo "$out" | grep -q '^## Warnings' \
  && { echo "FAIL case2: render_summary should not have ## Warnings section"; exit 1; }
pass "case2: small experiments — no warnings, no section"

# Case 3: CW_DEEP_RESEARCH_SIZE_WARN_GB=10 + 3 GB experiment → no warning
truncate -s 3G "$ART/troopers/rex/experiments/exp-001/blob.pt"
CW_DEEP_RESEARCH_SIZE_WARN_GB=10 cw_deep_research_compute_size_warnings "$ART"
[[ ! -s "$ART/warnings.txt" ]] \
  || { echo "FAIL case3: threshold override should suppress warning"; cat "$ART/warnings.txt"; exit 1; }
pass "case3: CW_DEEP_RESEARCH_SIZE_WARN_GB threshold respected"

echo "ALL: ok"
