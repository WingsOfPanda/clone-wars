#!/usr/bin/env bash
# Version-stamped invariant lock for v0.38.0.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"

PV=$(grep -E '^  "version":' "$PLUGIN_ROOT/.claude-plugin/plugin.json" \
  | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')

if [[ "$PV" != "0.38.0" ]]; then
  pass "skip — plugin version $PV ≠ 0.38.0"
  exit 0
fi

assert_eq "$PV" "0.38.0" "invariant 1: plugin.json version"
pass "1. plugin.json reads 0.38.0"

grep -q '^cw_global_state_root() {' "$PLUGIN_ROOT/lib/state.sh" \
  || { echo "FAIL: invariant 2: cw_global_state_root missing"; exit 1; }
pass "2. cw_global_state_root defined in lib/state.sh"

grep -q '^cw_global_state_ensure() {' "$PLUGIN_ROOT/lib/state.sh" \
  || { echo "FAIL: invariant 3: cw_global_state_ensure missing"; exit 1; }
pass "3. cw_global_state_ensure defined in lib/state.sh"

grep -q 'cw_global_state_root' "$PLUGIN_ROOT/bin/medic.sh" \
  || { echo "FAIL: invariant 4a: bin/medic.sh missing cw_global_state_root"; exit 1; }
if grep -qE '\bcw_state_root\b' "$PLUGIN_ROOT/bin/medic.sh"; then
  echo "FAIL: invariant 4b: bin/medic.sh still calls cw_state_root"; exit 1
fi
pass "4. bin/medic.sh uses cw_global_state_root, not cw_state_root"

for f in lib/contracts.sh lib/commanders.sh; do
  grep -q 'cw_global_state_root' "$PLUGIN_ROOT/$f" \
    || { echo "FAIL: invariant 5: $f missing cw_global_state_root"; exit 1; }
done
pass "5. lib/contracts.sh + lib/commanders.sh use cw_global_state_root"

for f in bin/consult-archive.sh bin/deploy-archive.sh lib/ipc.sh; do
  grep -q 'cw_global_state_root' "$PLUGIN_ROOT/$f" \
    || { echo "FAIL: invariant 6: $f archive base missing cw_global_state_root"; exit 1; }
done
pass "6. archive base files use cw_global_state_root"

if grep -qE '_args/' "$PLUGIN_ROOT/commands/medic.md"; then
  echo "FAIL: invariant 7: commands/medic.md still references _args/"; exit 1
fi
pass "7. commands/medic.md has no _args/ reference (Step 1 dropped)"

[[ -f "$PLUGIN_ROOT/tests/test_state_root_discipline.sh" ]] \
  || { echo "FAIL: invariant 8a: discipline lint missing"; exit 1; }
[[ -x "$PLUGIN_ROOT/tests/test_state_root_discipline.sh" ]] \
  || { echo "FAIL: invariant 8b: discipline lint not executable"; exit 1; }
pass "8. tests/test_state_root_discipline.sh exists + executable"

# 9: no literal env-var seam outside lib/state.sh
banned=$(grep -rnE '\$\{CLONE_WARS_HOME:-\$HOME/\.clone-wars\}' \
  "$PLUGIN_ROOT/commands" "$PLUGIN_ROOT/bin" "$PLUGIN_ROOT/hooks" \
  "$PLUGIN_ROOT/lib" 2>/dev/null | grep -vE 'lib/state\.sh' || true)
[[ -z "$banned" ]] \
  || { echo "FAIL: invariant 9: literal env-var seam outside lib/state.sh"; echo "$banned"; exit 1; }
pass "9. no literal \${CLONE_WARS_HOME:-\$HOME/.clone-wars} outside lib/state.sh"

grep -q '^- \[x\] v0.38.0' "$PLUGIN_ROOT/CLAUDE.md" \
  || { echo "FAIL: invariant 10a: CLAUDE.md missing v0.38.0 done row"; exit 1; }
grep -q '^- \[ \] v0.38.0 strict-dogfood' "$PLUGIN_ROOT/CLAUDE.md" \
  || { echo "FAIL: invariant 10b: CLAUDE.md missing v0.38.0 release-gate row"; exit 1; }
pass "10. CLAUDE.md has v0.38.0 status + release-gate rows"

echo "test_v0_38_0_static_wiring: 10 invariants locked"
