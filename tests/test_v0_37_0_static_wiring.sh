#!/usr/bin/env bash
# Version-stamped invariant lock for v0.37.0.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"

PV=$(grep -E '^  "version":' "$PLUGIN_ROOT/.claude-plugin/plugin.json" \
  | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')

if [[ "$PV" != "0.37.0" ]]; then
  pass "skip — plugin version $PV ≠ 0.37.0"
  exit 0
fi

# 1: plugin.json reports 0.37.0
assert_eq "$PV" "0.37.0" "invariant 1: plugin.json version"
pass "1. plugin.json reads 0.37.0"

# 2: deep-research.md references CLAUDE_PLUGIN_ROOT
grep -q 'CLAUDE_PLUGIN_ROOT' "$PLUGIN_ROOT/commands/deep-research.md" \
  || { echo "FAIL: invariant 2: deep-research.md missing CLAUDE_PLUGIN_ROOT" >&2; exit 1; }
pass "2. commands/deep-research.md uses CLAUDE_PLUGIN_ROOT"

# 3: deep-research-resume.md references CLAUDE_PLUGIN_ROOT
grep -q 'CLAUDE_PLUGIN_ROOT' "$PLUGIN_ROOT/commands/deep-research-resume.md" \
  || { echo "FAIL: invariant 3: deep-research-resume.md missing CLAUDE_PLUGIN_ROOT" >&2; exit 1; }
pass "3. commands/deep-research-resume.md uses CLAUDE_PLUGIN_ROOT"

# 4: deep-research.md has zero /home/liupan literal hits
if grep -q '/home/liupan' "$PLUGIN_ROOT/commands/deep-research.md"; then
  echo "FAIL: invariant 4: deep-research.md still has /home/liupan refs" >&2
  exit 1
fi
pass "4. commands/deep-research.md: no /home/liupan literal"

# 5: deep-research-resume.md has zero /home/liupan literal hits
if grep -q '/home/liupan' "$PLUGIN_ROOT/commands/deep-research-resume.md"; then
  echo "FAIL: invariant 5: deep-research-resume.md still has /home/liupan refs" >&2
  exit 1
fi
pass "5. commands/deep-research-resume.md: no /home/liupan literal"

# 6: test_no_hardcoded_paths.sh exists + executable (permanent lint in place)
[[ -f "$PLUGIN_ROOT/tests/test_no_hardcoded_paths.sh" ]] \
  || { echo "FAIL: invariant 6a: permanent lint test missing" >&2; exit 1; }
[[ -x "$PLUGIN_ROOT/tests/test_no_hardcoded_paths.sh" ]] \
  || { echo "FAIL: invariant 6b: permanent lint test not executable" >&2; exit 1; }
pass "6. tests/test_no_hardcoded_paths.sh exists + executable"

# 7: CLAUDE.md has v0.37.0 status row + release-gate row
grep -q '^- \[x\] v0.37.0' "$PLUGIN_ROOT/CLAUDE.md" \
  || { echo "FAIL: invariant 7a: CLAUDE.md missing v0.37.0 done row" >&2; exit 1; }
grep -q '^- \[ \] v0.37.0 strict-dogfood' "$PLUGIN_ROOT/CLAUDE.md" \
  || { echo "FAIL: invariant 7b: CLAUDE.md missing v0.37.0 release-gate row" >&2; exit 1; }
pass "7. CLAUDE.md has v0.37.0 status + release-gate rows"

echo "test_v0_37_0_static_wiring: 7 invariants locked"
