#!/usr/bin/env bash
# tests/test_deep_research_hardware_probe.sh — v0.27.2 P2 hardware probe
# Covers both nvidia-smi present (mocked) and absent (PATH stripped).
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# --- Case A: nvidia-smi MOCKED to return fake CSV ---
mkdir -p "$TMP/bin"
cat > "$TMP/bin/nvidia-smi" <<'NVSMI'
#!/usr/bin/env bash
# Mock nvidia-smi for the test.
if [[ "$*" == *"--query-gpu="* ]]; then
  echo "NVIDIA L20, 49140, 24905, 580.126.09"
fi
NVSMI
chmod +x "$TMP/bin/nvidia-smi"

PATH="$TMP/bin:$PATH" cw_deep_research_hardware_probe "$TMP/hw-gpu.txt"
assert_file_exists "$TMP/hw-gpu.txt" "hw-gpu.txt written when nvidia-smi present"

# Has detected_at line with ISO-8601 timestamp
head -1 "$TMP/hw-gpu.txt" | grep -qE '^detected_at	[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
  || { echo "FAIL: hw-gpu.txt first line not detected_at<TAB>iso-8601:" >&2; head -1 "$TMP/hw-gpu.txt" >&2; exit 1; }

# Has gpu row with name, total, free, driver
TAB=$(printf '\t')
grep -qE "^gpu${TAB}NVIDIA L20${TAB}49140${TAB}24905${TAB}580\.126\.09$" "$TMP/hw-gpu.txt" \
  || { echo "FAIL: gpu row missing or wrong shape:" >&2; cat "$TMP/hw-gpu.txt" >&2; exit 1; }

pass "hardware_probe: nvidia-smi present → detected_at + gpu row"

# --- Case B: nvidia-smi ABSENT (jailed bin dir: symlinks to essentials, NO nvidia-smi) ---
# Build a sandbox bin dir with the commands cw_deep_research_hardware_probe needs
# (date, mv, awk, command builtin via /bin/sh) but explicitly NO nvidia-smi.
# v0.29.0: also include mktemp, cat, rm because cw_deep_research_hardware_probe
# now pipes through cw_atomic_write (mktemp + cat redirect + mv + rm-via-trap).
mkdir -p "$TMP/sandbox-bin"
for cmd in date mv awk mktemp cat rm; do
  abs=$(command -v "$cmd")
  ln -sf "$abs" "$TMP/sandbox-bin/$cmd"
done
ORIG_PATH="$PATH"
PATH="$TMP/sandbox-bin" cw_deep_research_hardware_probe "$TMP/hw-cpu.txt"
PATH="$ORIG_PATH"
assert_file_exists "$TMP/hw-cpu.txt" "hw-cpu.txt written when nvidia-smi absent"

head -1 "$TMP/hw-cpu.txt" | grep -qE '^detected_at	[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
  || { echo "FAIL: hw-cpu.txt first line not detected_at<TAB>iso-8601" >&2; exit 1; }

grep -qE '^no-gpu$' "$TMP/hw-cpu.txt" \
  || { echo "FAIL: hw-cpu.txt missing 'no-gpu' line:" >&2; cat "$TMP/hw-cpu.txt" >&2; exit 1; }

pass "hardware_probe: nvidia-smi absent → no-gpu marker"

# --- Case C: missing out-path argument ---
cw_deep_research_hardware_probe 2>/dev/null && rc=0 || rc=$?
[[ "$rc" == "2" ]] \
  || { echo "FAIL: missing out-path should exit rc=2, got $rc" >&2; exit 1; }
pass "hardware_probe: missing out-path arg → rc=2"
