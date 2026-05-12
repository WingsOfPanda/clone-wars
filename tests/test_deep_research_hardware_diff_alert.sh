#!/usr/bin/env bash
# tests/test_deep_research_hardware_diff_alert.sh — v0.27.2 P2 diff alert
# Emits ONE "ALERT:" line when memory.free dropped >50% on any GPU row.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

write_hw() {
  # write_hw <path> <gpu-name> <total-mb> <free-mb>
  local path="$1" name="$2" total="$3" free="$4"
  {
    printf 'detected_at\t2026-05-12T12:00:00Z\n'
    printf 'gpu\t%s\t%s\t%s\t580.126.09\n' "$name" "$total" "$free"
  } > "$path"
}

# --- Case A: No memory drop ---
write_hw "$TMP/base.txt"    "NVIDIA L20" 49140 30000
write_hw "$TMP/current.txt" "NVIDIA L20" 49140 30000
out=$(cw_deep_research_hardware_diff_alert "$TMP/base.txt" "$TMP/current.txt")
[[ -z "$out" ]] \
  || { echo "FAIL: no-drop should emit empty stdout; got: $out" >&2; exit 1; }
pass "diff_alert: no-drop → empty stdout"

# --- Case B: 30% drop (below 50% threshold) ---
write_hw "$TMP/base.txt"    "NVIDIA L20" 49140 30000
write_hw "$TMP/current.txt" "NVIDIA L20" 49140 21000     # 30% drop
out=$(cw_deep_research_hardware_diff_alert "$TMP/base.txt" "$TMP/current.txt")
[[ -z "$out" ]] \
  || { echo "FAIL: 30%-drop should emit empty stdout; got: $out" >&2; exit 1; }
pass "diff_alert: 30%-drop (below threshold) → empty stdout"

# --- Case C: 60% drop (above threshold) ---
write_hw "$TMP/base.txt"    "NVIDIA L20" 49140 30000
write_hw "$TMP/current.txt" "NVIDIA L20" 49140 12000     # 60% drop
out=$(cw_deep_research_hardware_diff_alert "$TMP/base.txt" "$TMP/current.txt")
line_count=$(printf '%s' "$out" | grep -c '^ALERT:' || true)
[[ "$line_count" == "1" ]] \
  || { echo "FAIL: 60%-drop should emit 1 ALERT line; got $line_count line(s):" >&2; echo "$out" >&2; exit 1; }
echo "$out" | grep -qE "ALERT: gpu 'NVIDIA L20' memory.free 30000 -> 12000 MiB \(-60%\)" \
  || { echo "FAIL: ALERT text doesn't match expected format; got:" >&2; echo "$out" >&2; exit 1; }
pass "diff_alert: 60%-drop → 1 ALERT line with correct percentage"

# --- Case D: GPU disappeared in current (no row in current) ---
write_hw "$TMP/base.txt" "NVIDIA L20" 49140 30000
{
  printf 'detected_at\t2026-05-12T12:00:00Z\n'
  printf 'no-gpu\n'
} > "$TMP/current.txt"
out=$(cw_deep_research_hardware_diff_alert "$TMP/base.txt" "$TMP/current.txt")
[[ -z "$out" ]] \
  || { echo "FAIL: GPU-gone should emit empty stdout (not a memory-drop case); got: $out" >&2; exit 1; }
pass "diff_alert: GPU-gone → empty stdout (not memory-drop)"

# --- Case E: Missing file → rc=0, empty output ---
out=$(cw_deep_research_hardware_diff_alert "$TMP/nonexistent.txt" "$TMP/base.txt")
[[ -z "$out" ]] \
  || { echo "FAIL: missing baseline should emit empty stdout; got: $out" >&2; exit 1; }
pass "diff_alert: missing baseline → empty stdout (silent)"
