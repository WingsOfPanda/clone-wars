#!/usr/bin/env bash
# Version-stamped invariant lock for v0.39.0.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"

PV=$(grep -E '^  "version":' "$PLUGIN_ROOT/.claude-plugin/plugin.json" \
  | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')

if [[ "$PV" != "0.39.0" ]]; then
  pass "skip — plugin version $PV ≠ 0.39.0"
  exit 0
fi

# Invariant 1: plugin.json reads 0.39.0
assert_eq "$PV" "0.39.0" "invariant 1: plugin.json version"
pass "1. plugin.json reads 0.39.0"

# Invariant 2: permanent lint exists + is executable
[[ -f "$PLUGIN_ROOT/tests/test_braced_plugin_root.sh" ]] \
  || { echo "FAIL: invariant 2a: tests/test_braced_plugin_root.sh missing"; exit 1; }
[[ -x "$PLUGIN_ROOT/tests/test_braced_plugin_root.sh" ]] \
  || { echo "FAIL: invariant 2b: tests/test_braced_plugin_root.sh not executable"; exit 1; }
pass "2. tests/test_braced_plugin_root.sh exists + executable"

# Invariant 3: regression spot-check — medic.md Step A source line is braced
# shellcheck disable=SC2016  # literal ${CLAUDE_PLUGIN_ROOT} is the grep pattern
grep -q 'source "${CLAUDE_PLUGIN_ROOT}/lib/state.sh"' "$PLUGIN_ROOT/commands/medic.md" \
  || { echo "FAIL: invariant 3: medic.md missing braced source line"; exit 1; }
pass "3. medic.md Step A uses \${CLAUDE_PLUGIN_ROOT} (braced)"

# Invariant 4: census — braced refs in commands/ ≥ 146 (50 prior + 96 migrated)
BRACED_COUNT=$(grep -rE '\$\{CLAUDE_PLUGIN_ROOT\}' "$PLUGIN_ROOT/commands/" | wc -l)
[[ $BRACED_COUNT -ge 146 ]] \
  || { echo "FAIL: invariant 4: braced count $BRACED_COUNT < 146"; exit 1; }
pass "4. braced \${CLAUDE_PLUGIN_ROOT} count in commands/ = $BRACED_COUNT (≥ 146)"

# Invariant 5: CLAUDE.md "Current focus" names v0.39.0
grep -qE '^- \*\*Most recent merge:\*\* v0\.39\.0' "$PLUGIN_ROOT/CLAUDE.md" \
  || { echo "FAIL: invariant 5: CLAUDE.md missing v0.39.0 Most-recent-merge row"; exit 1; }
pass "5. CLAUDE.md Current focus names v0.39.0"

echo "test_v0_39_0_static_wiring: 5 invariants locked"
