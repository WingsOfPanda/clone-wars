#!/usr/bin/env bash
# tests/test_deep_research_experiment_send_hardware_block.sh — v0.27.2 P2 wiring
# experiment-send.sh must:
#   1. Run the per-experiment hardware probe (writes hardware-current.txt)
#   2. Compute the diff alert
#   3. Render HARDWARE_BLOCK into prompt.md
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

mkdir -p "$CLONE_WARS_HOME"
echo "codex" > "$CLONE_WARS_HOME/providers-available.txt"

TOPIC=$("$PLUGIN_ROOT/bin/deep-research-init.sh" "P2 hardware block wiring test")
source "$PLUGIN_ROOT/lib/state.sh"
REPO_HASH=$(cw_repo_hash)
TD="$CLONE_WARS_HOME/state/$REPO_HASH/$TOPIC"
ART="$TD/_deep-research"

# Hand-write metric.md
cat > "$ART/metric.md" <<'EOF'
# Research goal

**Primary metric:** accuracy
**Direction:** maximize
EOF

# Hand-write hardware.txt baseline (high memory.free)
{
  printf 'detected_at\t2026-05-12T11:39:40Z\n'
  printf 'gpu\tNVIDIA L20\t49140\t30000\t580.126.09\n'
} > "$ART/hardware.txt"

# Mock nvidia-smi on PATH to return LOW memory.free (simulating co-tenant
# grabbed memory mid-session) so the diff alert fires.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/nvidia-smi" <<'NVSMI'
#!/usr/bin/env bash
if [[ "$*" == *"--query-gpu="* ]]; then
  echo "NVIDIA L20, 49140, 12000, 580.126.09"  # 60% drop vs baseline 30000
fi
NVSMI
chmod +x "$TMP/bin/nvidia-smi"

# Fake-spawn the trooper
mkdir -p "$TD/rex-codex"
echo '{"pane_id":"%9999","pid":99999,"spawned_at":"2026-05-12T00:00:00Z"}' > "$TD/rex-codex/pane.json"
echo '' > "$TD/rex-codex/outbox.jsonl"
echo '{"state":"working","updated":"2026-05-12T12:00:00Z","last_event":"ready"}' > "$TD/rex-codex/status.json"

# v0.28.0: seed per-trooper state.txt (normally done by directive Phase 4.a)
source "$PLUGIN_ROOT/lib/deep-research.sh"
mkdir -p "$ART/troopers/rex/experiments"
cw_deep_research_trooper_state_write "$ART" rex \
  exp_counter=0 phase=idle current_exp_id= \
  last_event_ts=2026-05-13T08:00:00Z last_event=spawn probe_sent_ts=

export CW_DEEP_RESEARCH_DRY_RUN=1
PATH="$TMP/bin:$PATH" "$PLUGIN_ROOT/bin/deep-research-experiment-send.sh" \
  "$TOPIC" rex exp-001 "P2 wiring" "Smoke-test approach brief."

# Assert hardware-current.txt was written
assert_file_exists "$ART/hardware-current.txt" "hardware-current.txt written"
TAB=$(printf '\t')
grep -qE "^gpu${TAB}NVIDIA L20${TAB}49140${TAB}12000${TAB}580\.126\.09$" "$ART/hardware-current.txt" \
  || { echo "FAIL: hardware-current.txt missing expected gpu row:" >&2; cat "$ART/hardware-current.txt" >&2; exit 1; }
pass "hardware-current.txt written by experiment-send.sh"

# Assert prompt.md contains the rendered Hardware section
PROMPT="$ART/troopers/rex/experiments/exp-001/prompt.md"
assert_file_exists "$PROMPT" "prompt.md exists"
grep -q '^Hardware:$' "$PROMPT" \
  || { echo "FAIL: prompt.md missing 'Hardware:' header" >&2; exit 1; }
grep -qE "gpu${TAB}NVIDIA L20${TAB}49140${TAB}12000" "$PROMPT" \
  || { echo "FAIL: prompt.md missing hardware row from hardware-current.txt" >&2; exit 1; }
pass "prompt.md contains rendered Hardware section"

# Assert ALERT line landed in prompt.md (60% drop > 50% threshold)
grep -qE "ALERT: gpu 'NVIDIA L20' memory.free 30000 -> 12000 MiB \(-60%\)" "$PROMPT" \
  || { echo "FAIL: ALERT line missing from prompt.md" >&2; exit 1; }
pass "prompt.md contains diff-alert ALERT line"
