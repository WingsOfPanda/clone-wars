#!/usr/bin/env bash
# Version-stamped invariant lock for v0.36.0.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"

PV=$(grep -E '^  "version":' "$PLUGIN_ROOT/.claude-plugin/plugin.json" \
  | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')

if [[ "$PV" != "0.36.0" ]]; then
  pass "skip — plugin version $PV ≠ 0.36.0"
  exit 0
fi

# 1: plugin.json reports 0.36.0
assert_eq "$PV" "0.36.0" "invariant 1: plugin.json version"
pass "1. plugin.json reads 0.36.0"

# 2: cw_run_dir defined
grep -q '^cw_run_dir() {' "$PLUGIN_ROOT/lib/state.sh" \
  || { echo "FAIL: invariant 2: cw_run_dir missing" >&2; exit 1; }
pass "2. cw_run_dir defined in lib/state.sh"

# 3: cw_run_dir_last defined
grep -q '^cw_run_dir_last() {' "$PLUGIN_ROOT/lib/state.sh" \
  || { echo "FAIL: invariant 3: cw_run_dir_last missing" >&2; exit 1; }
pass "3. cw_run_dir_last defined in lib/state.sh"

# 4: consult.md uses cw_run_dir and has zero /tmp/cw-* references
grep -q 'cw_run_dir' "$PLUGIN_ROOT/commands/consult.md" \
  || { echo "FAIL: invariant 4a: consult.md missing cw_run_dir call" >&2; exit 1; }
if grep -q '/tmp/cw-' "$PLUGIN_ROOT/commands/consult.md"; then
  echo "FAIL: invariant 4b: consult.md still has /tmp/cw-* refs" >&2; exit 1
fi
pass "4. consult.md migrated to cw_run_dir (no /tmp/cw-* left)"

# 5: meditate.md
grep -q 'cw_run_dir' "$PLUGIN_ROOT/commands/meditate.md" \
  || { echo "FAIL: invariant 5a: meditate.md missing cw_run_dir call" >&2; exit 1; }
if grep -q '/tmp/cw-' "$PLUGIN_ROOT/commands/meditate.md"; then
  echo "FAIL: invariant 5b: meditate.md still has /tmp/cw-* refs" >&2; exit 1
fi
pass "5. meditate.md migrated to cw_run_dir"

# 6: deep-research.md
grep -q 'cw_run_dir' "$PLUGIN_ROOT/commands/deep-research.md" \
  || { echo "FAIL: invariant 6a: deep-research.md missing cw_run_dir call" >&2; exit 1; }
if grep -q '/tmp/cw-' "$PLUGIN_ROOT/commands/deep-research.md"; then
  echo "FAIL: invariant 6b: deep-research.md still has /tmp/cw-* refs" >&2; exit 1
fi
pass "6. deep-research.md migrated to cw_run_dir"

# 7: deploy.md
grep -q 'cw_run_dir' "$PLUGIN_ROOT/commands/deploy.md" \
  || { echo "FAIL: invariant 7a: deploy.md missing cw_run_dir call" >&2; exit 1; }
if grep -q '/tmp/cw-' "$PLUGIN_ROOT/commands/deploy.md"; then
  echo "FAIL: invariant 7b: deploy.md still has /tmp/cw-* refs" >&2; exit 1
fi
pass "7. deploy.md migrated to cw_run_dir"

# 8: CLAUDE.md has v0.36.0 status row + release-gate row
grep -q '^- \[x\] v0.36.0' "$PLUGIN_ROOT/CLAUDE.md" \
  || { echo "FAIL: invariant 8a: CLAUDE.md missing v0.36.0 done row" >&2; exit 1; }
grep -q '^- \[ \] v0.36.0 strict-dogfood' "$PLUGIN_ROOT/CLAUDE.md" \
  || { echo "FAIL: invariant 8b: CLAUDE.md missing v0.36.0 release-gate row" >&2; exit 1; }
pass "8. CLAUDE.md has v0.36.0 status + release-gate rows"

echo "test_v0_36_0_static_wiring: 8 invariants locked"
