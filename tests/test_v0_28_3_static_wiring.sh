#!/usr/bin/env bash
# tests/test_v0_28_3_static_wiring.sh — v0.28.3 invariant lock.
# Locks the v0.28.3 deep-research preflight port:
#   1. plugin.json + marketplace.json on 0.28.3+
#   2. cw_deep_research_write_preflight_sidecar exists in lib/deep-research.sh
#   3. bin/deep-research-teardown.sh sources lib/tmux.sh + calls cw_preflight_kill_orphans
#   4. commands/deep-research.md has Phase 3a + 3b
#   5. CLAUDE.md has v0.28.3 status row
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

# v0.28.4+ skip-and-pass guard (mirror v0.28.2 lock pattern)
plug_ver=$(awk -F'"' '/"version"/{print $4}' "$PLUGIN_ROOT/.claude-plugin/plugin.json")
case "$plug_ver" in
  0.28.[3-9]|0.28.[1-9][0-9]*) ;;
  0.28.*) pass "v0.28.3 lock skipped — plugin on $plug_ver (pre-v0.28.3)"; exit 0 ;;
  *)      pass "v0.28.3 lock skipped — plugin on $plug_ver (later release)"; exit 0 ;;
esac

# Invariant 1: plugin.json + marketplace.json on 0.28.3+
grep -qE '"version"[[:space:]]*:[[:space:]]*"0\.28\.[3-9]"' "$PLUGIN_ROOT/.claude-plugin/plugin.json" \
  || { echo "FAIL: plugin.json version not 0.28.3+" >&2; exit 1; }
count=$(grep -cE '"version"[[:space:]]*:[[:space:]]*"0\.28\.[3-9]"' "$PLUGIN_ROOT/.claude-plugin/marketplace.json")
[[ "$count" == "2" ]] \
  || { echo "FAIL: marketplace.json expected 2 v0.28.3+ fields, got $count" >&2; exit 1; }
pass "1. plugin.json + marketplace.json on 0.28.3+"

# Invariant 2: lib helper exists
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"
declare -F cw_deep_research_write_preflight_sidecar >/dev/null \
  || { echo "FAIL: cw_deep_research_write_preflight_sidecar not defined" >&2; exit 1; }
pass "2. cw_deep_research_write_preflight_sidecar helper exists"

# Invariant 3: deep-research-teardown sources tmux.sh + calls orphan helper
TEARDOWN="$PLUGIN_ROOT/bin/deep-research-teardown.sh"
grep -q 'source.*lib/tmux\.sh' "$TEARDOWN" \
  || { echo "FAIL: deep-research-teardown doesn't source lib/tmux.sh" >&2; exit 1; }
grep -q 'cw_preflight_kill_orphans' "$TEARDOWN" \
  || { echo "FAIL: deep-research-teardown doesn't call cw_preflight_kill_orphans" >&2; exit 1; }
pass "3. deep-research-teardown sources tmux.sh + calls cw_preflight_kill_orphans"

# Invariant 4: directive has Phase 3a + 3b
grep -qE '^### Phase 3a — Preflight' "$PLUGIN_ROOT/commands/deep-research.md" \
  || { echo "FAIL: Phase 3a heading missing in directive" >&2; exit 1; }
grep -qE '^### Phase 3b — Parallel dispatch' "$PLUGIN_ROOT/commands/deep-research.md" \
  || { echo "FAIL: Phase 3b heading missing in directive" >&2; exit 1; }
pass "4. directive has Phase 3a + 3b headings"

# Invariant 5: CLAUDE.md has v0.28.3 status row + release-gate row
grep -q '^- \[x\] v0\.28\.3:' "$PLUGIN_ROOT/CLAUDE.md" \
  || { echo "FAIL: CLAUDE.md missing v0.28.3 status row" >&2; exit 1; }
grep -q 'v0\.28\.3 strict-dogfood' "$PLUGIN_ROOT/CLAUDE.md" \
  || { echo "FAIL: CLAUDE.md missing v0.28.3 release-gate row" >&2; exit 1; }
pass "5. CLAUDE.md has v0.28.3 status + release-gate rows"

echo "test_v0_28_3_static_wiring: 5 invariants locked"
