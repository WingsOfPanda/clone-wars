#!/usr/bin/env bash
# tests/test_state_root_discipline.sh
# Permanent lint: per-machine config must use cw_global_state_root;
# per-project state must use cw_state_root. v0.31.0 collapsed both
# under cw_state_root; v0.38.0 split them via cw_global_state_root.
# No version skip-guard.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
PLUGIN_ROOT="$(cd .. && pwd)"

FAILED=0
report() {
  echo "FAIL: $1" >&2
  [[ -n "$2" ]] && echo "$2" >&2
  FAILED=1
}

# Assert 1: medic.{md,sh} never call cw_state_root (medic is per-MACHINE)
for f in commands/medic.md bin/medic.sh; do
  hits=$(grep -nE '\bcw_state_root\b' "$PLUGIN_ROOT/$f" 2>/dev/null || true)
  [[ -z "$hits" ]] || report "$f calls cw_state_root (medic is per-machine; use cw_global_state_root)" "$hits"
done

# Assert 2: lib/contracts.sh + lib/commanders.sh use cw_global_state_root
# (the config they touch is per-machine)
for f in lib/contracts.sh lib/commanders.sh; do
  grep -qE 'cw_global_state_root' "$PLUGIN_ROOT/$f" \
    || report "$f missing cw_global_state_root call" "(expected at least one reference)"
  hits=$(grep -nE '\bcw_state_root\b' "$PLUGIN_ROOT/$f" 2>/dev/null || true)
  [[ -z "$hits" ]] || report "$f calls cw_state_root (its config is per-machine)" "$hits"
done

# Assert 3: cw_active_providers_path uses cw_global_state_root
# Look at the helper definition only (not just any occurrence in the file).
if ! awk '/^cw_active_providers_path\(\)/,/^}/' "$PLUGIN_ROOT/lib/state.sh" \
  | grep -qE 'cw_global_state_root'; then
  report "lib/state.sh cw_active_providers_path must use cw_global_state_root" ""
fi

# Assert 4: archive base files use cw_global_state_root
for f in bin/consult-archive.sh bin/deploy-archive.sh lib/ipc.sh; do
  grep -qE 'cw_global_state_root' "$PLUGIN_ROOT/$f" \
    || report "$f archive base must use cw_global_state_root" "(expected at least one reference)"
done

# Assert 5: no literal ${CLONE_WARS_HOME:-$HOME/.clone-wars} outside lib/state.sh
# (use cw_global_state_root instead)
banned=$(grep -rnE '\$\{CLONE_WARS_HOME:-\$HOME/\.clone-wars\}' \
  "$PLUGIN_ROOT/commands" "$PLUGIN_ROOT/bin" "$PLUGIN_ROOT/lib" "$PLUGIN_ROOT/hooks" \
  2>/dev/null | grep -vE 'lib/state\.sh' || true)
[[ -z "$banned" ]] || report "literal \${CLONE_WARS_HOME:-\$HOME/.clone-wars} found outside lib/state.sh" "$banned"

# Assert 6: commands/medic.md has no _args/ reference (Step 1 dropped)
hits=$(grep -nE '_args/' "$PLUGIN_ROOT/commands/medic.md" 2>/dev/null || true)
[[ -z "$hits" ]] || report "commands/medic.md references _args/ (Step 1 boilerplate should be dropped)" "$hits"

if (( FAILED != 0 )); then
  echo "" >&2
  echo "Fix: use cw_global_state_root for per-machine config (~/.clone-wars/)" >&2
  echo "     use cw_state_root for per-project state (\$PWD/.clone-wars/)" >&2
  exit 1
fi
pass "state-root discipline enforced: medic + contracts + commanders + archive use cw_global_state_root; no literal env-var seam outside lib/state.sh"
echo "test_state_root_discipline: lint passed"
