#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/log.sh
source ../lib/state.sh
source ../lib/consult.sh

TMPROOT=$(mktemp -d -t cw-targets.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT
ART="$TMPROOT/_consult"
mkdir -p "$ART"

# Happy path round-trip
printf '%s\n' "hub_a/leaf1" "hub_b/leaf3" | cw_consult_targets_persist "$ART"
out=$(cw_consult_targets_load "$ART")
[[ "$out" == $'hub_a/leaf1\nhub_b/leaf3' ]] \
  || { echo "FAIL round-trip: $out"; exit 1; }
pass "round-trip hub_a/leaf1 + hub_b/leaf3"

# Hub-mode persist + load
cw_consult_hub_mode_persist "$ART" "super-hub"
mode=$(cw_consult_hub_mode_load "$ART")
[[ "$mode" == "super-hub" ]] || { echo "FAIL mode: $mode"; exit 1; }
pass "hub-mode persist/load round-trip"

# Default fallback
rm -f "$ART/hub-mode.txt"
mode=$(cw_consult_hub_mode_load "$ART")
[[ "$mode" == "single-repo" ]] || { echo "FAIL default: $mode"; exit 1; }
pass "hub-mode load default = single-repo"

# Slug rejection
if printf '%s\n' "../escape/leaf" | cw_consult_targets_persist "$ART" 2>/dev/null; then
  echo "FAIL: ../escape should be rejected"; exit 1
fi
pass "rejects ../escape slug"

if printf '%s\n' "no-slash-here" | cw_consult_targets_persist "$ART" 2>/dev/null; then
  echo "FAIL: no-slash-here should be rejected"; exit 1
fi
pass "rejects line without slash"

# Empty targets.txt → load rc=1
: > "$ART/targets.txt"
if cw_consult_targets_load "$ART" 2>/dev/null; then
  echo "FAIL: empty targets.txt should rc=1"; exit 1
fi
pass "empty targets.txt → load rc=1"
