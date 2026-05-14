#!/usr/bin/env bash
# tests/test_v0_29_0_static_wiring.sh — v0.29.0 invariant lock.
# Locks the v0.29.0 simplification sweep:
#   1. plugin.json + marketplace.json on 0.29.x+
#   2. tracer/ directory absent
#   3. config/identity-template.md symlink absent (target prompt-templates/identity.md present)
#   4. cw_deep_research_check_plateau not defined in lib/deep-research.sh
#   5. cw_deep_research_trooper_state_field defined in lib/deep-research.sh
#   6. cw_state_archive_dir defined in lib/state.sh
#   7. cw_teardown_with_preflight_orphans defined in lib/tmux.sh
#   8. CLAUDE.md v0.29.0 status row present
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

# v0.30+ skip-and-pass guard (mirror v0.28.3 lock pattern)
plug_ver=$(awk -F'"' '/"version"/{print $4}' "$PLUGIN_ROOT/.claude-plugin/plugin.json")
case "$plug_ver" in
  0.29.*) ;;
  0.[3-9][0-9].*|[1-9].*) pass "v0.29.0 lock skipped — plugin on $plug_ver (later release)"; exit 0 ;;
  0.2[0-8].*)             pass "v0.29.0 lock skipped — plugin on $plug_ver (pre-v0.29.0)"; exit 0 ;;
  *)                      pass "v0.29.0 lock skipped — plugin on $plug_ver"; exit 0 ;;
esac

# Invariant 1: plugin.json + marketplace.json on 0.29.x
grep -qE '"version"[[:space:]]*:[[:space:]]*"0\.29\.[0-9]+"' "$PLUGIN_ROOT/.claude-plugin/plugin.json" \
  || { echo "FAIL: plugin.json version not 0.29.x" >&2; exit 1; }
count=$(grep -cE '"version"[[:space:]]*:[[:space:]]*"0\.29\.[0-9]+"' "$PLUGIN_ROOT/.claude-plugin/marketplace.json")
[[ "$count" == "2" ]] \
  || { echo "FAIL: marketplace.json expected 2 v0.29.x fields, got $count" >&2; exit 1; }
pass "1. plugin.json + marketplace.json on 0.29.x"

# Invariant 2: tracer/ directory absent
[[ ! -d "$PLUGIN_ROOT/tracer" ]] \
  || { echo "FAIL: tracer/ directory should be absent in v0.29.0" >&2; exit 1; }
pass "2. tracer/ absent"

# Invariant 3: identity-template.md symlink absent; target present
[[ ! -e "$PLUGIN_ROOT/config/identity-template.md" ]] \
  || { echo "FAIL: config/identity-template.md should not exist in v0.29.0" >&2; exit 1; }
[[ -f "$PLUGIN_ROOT/config/prompt-templates/identity.md" ]] \
  || { echo "FAIL: config/prompt-templates/identity.md target missing" >&2; exit 1; }
pass "3. identity-template symlink absent; target present"

# Invariant 4: cw_deep_research_check_plateau not defined
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"
if declare -F cw_deep_research_check_plateau >/dev/null; then
  echo "FAIL: cw_deep_research_check_plateau should be removed in v0.29.0" >&2; exit 1
fi
pass "4. cw_deep_research_check_plateau removed"

# Invariant 5: cw_deep_research_trooper_state_field defined
declare -F cw_deep_research_trooper_state_field >/dev/null \
  || { echo "FAIL: cw_deep_research_trooper_state_field not defined" >&2; exit 1; }
pass "5. cw_deep_research_trooper_state_field defined"

# Invariant 6: cw_state_archive_dir defined in lib/state.sh
declare -F cw_state_archive_dir >/dev/null \
  || { echo "FAIL: cw_state_archive_dir not defined" >&2; exit 1; }
pass "6. cw_state_archive_dir defined"

# Invariant 7: cw_teardown_with_preflight_orphans defined in lib/tmux.sh
source "$PLUGIN_ROOT/lib/tmux.sh"
declare -F cw_teardown_with_preflight_orphans >/dev/null \
  || { echo "FAIL: cw_teardown_with_preflight_orphans not defined" >&2; exit 1; }
pass "7. cw_teardown_with_preflight_orphans defined"

# Invariant 8: CLAUDE.md v0.29.0 status row present
grep -q '^- \[x\] v0\.29\.0:' "$PLUGIN_ROOT/CLAUDE.md" \
  || { echo "FAIL: CLAUDE.md missing v0.29.0 status row (^- [x] v0.29.0:)" >&2; exit 1; }
pass "8. CLAUDE.md v0.29.0 status row present"

echo "test_v0_29_0_static_wiring: 8 invariants locked"
