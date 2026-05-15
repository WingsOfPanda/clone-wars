#!/usr/bin/env bash
# tests/test_v0_31_0_static_wiring.sh — v0.31.0 invariant lock
# Never edit — adjust at v0.32.0 by creating a new static-wiring test.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

# v0.32.0+ guard: skip if plugin moves on.
plug_ver=$(awk -F'"' '/"version"/{print $4}' "$PLUGIN_ROOT/.claude-plugin/plugin.json")
case "$plug_ver" in
  0.31.*) ;;
  *)
    pass "v0.31.0 lock skipped — plugin on $plug_ver"
    exit 0
    ;;
esac

# Invariant 1: plugin.json on 0.31.x
grep -qE '"version"[[:space:]]*:[[:space:]]*"0\.31\.[0-9]+"' "$PLUGIN_ROOT/.claude-plugin/plugin.json" \
  || { echo "FAIL: plugin.json not on 0.31.x" >&2; exit 1; }
pass "1. plugin.json version on 0.31.x"

# Invariant 2: marketplace.json has 2 v0.31.x fields
count=$(grep -cE '"version"[[:space:]]*:[[:space:]]*"0\.31\.[0-9]+"' "$PLUGIN_ROOT/.claude-plugin/marketplace.json")
[[ "$count" == "2" ]] \
  || { echo "FAIL: marketplace.json expected 2 v0.31.x fields, got $count" >&2; exit 1; }
pass "2. marketplace.json has 2 v0.31.x version fields"

# Invariant 3: cw_state_root resolves to $PWD/.clone-wars when no env var
SANDBOX=$(mktemp -d); trap 'rm -rf "$SANDBOX"' EXIT
cd "$SANDBOX"
unset CLONE_WARS_HOME
source "$PLUGIN_ROOT/lib/state.sh"
out=$(cw_state_root)
[[ "$out" == "$SANDBOX/.clone-wars" ]] \
  || { echo "FAIL: cw_state_root resolution wrong (got $out)" >&2; exit 1; }
pass "3. cw_state_root returns \$PWD/.clone-wars by default"

# Invariant 4: cw_state_ensure writes .gitignore
cw_state_ensure
[[ -f "$SANDBOX/.clone-wars/.gitignore" ]] \
  || { echo "FAIL: .gitignore not written by cw_state_ensure" >&2; exit 1; }
[[ "$(cat "$SANDBOX/.clone-wars/.gitignore")" == "*" ]] \
  || { echo "FAIL: .gitignore content wrong" >&2; exit 1; }
pass "4. cw_state_ensure writes <root>/.gitignore with '*'"

# Invariant 5: cw_args_file_consume defined
source "$PLUGIN_ROOT/lib/argsfile.sh"
declare -F cw_args_file_consume >/dev/null \
  || { echo "FAIL: cw_args_file_consume not defined" >&2; exit 1; }
pass "5. cw_args_file_consume defined in lib/argsfile.sh"

# Invariant 6: hook uses $PWD/.clone-wars/state (not the global path)
grep -q 'STATE_ROOT="\$PWD/\.clone-wars/state"' "$PLUGIN_ROOT/hooks/user-prompt-submit-active-session.sh" \
  || { echo "FAIL: hook doesn't use \$PWD/.clone-wars/state" >&2; exit 1; }
if grep -q 'CLONE_WARS_HOME' "$PLUGIN_ROOT/hooks/user-prompt-submit-active-session.sh"; then
  echo "FAIL: hook still references CLONE_WARS_HOME" >&2; exit 1
fi
pass "6. hook uses \$PWD/.clone-wars/state and no longer references CLONE_WARS_HOME"

# Invariant 7: bin/deploy-init.sh does NOT export CW_TOPIC_REPO_CWD
if grep -qE '^[[:space:]]*export[[:space:]]+CW_TOPIC_REPO_CWD' "$PLUGIN_ROOT/bin/deploy-init.sh"; then
  echo "FAIL: bin/deploy-init.sh still exports CW_TOPIC_REPO_CWD" >&2; exit 1
fi
pass "7. bin/deploy-init.sh does NOT export CW_TOPIC_REPO_CWD"

# Invariant 8: commands/deploy.md has zero CW_TOPIC_REPO_CWD references
count=$(grep -c 'CW_TOPIC_REPO_CWD' "$PLUGIN_ROOT/commands/deploy.md" || true)
[[ "$count" == "0" ]] \
  || { echo "FAIL: commands/deploy.md still has $count CW_TOPIC_REPO_CWD references" >&2; exit 1; }
pass "8. commands/deploy.md has no CW_TOPIC_REPO_CWD references"

# Invariant 9: cw_topic_repo_hash has no CW_TOPIC_REPO_CWD branch
if awk '/^cw_topic_repo_hash\(\)/,/^}/' "$PLUGIN_ROOT/lib/state.sh" | grep -q 'CW_TOPIC_REPO_CWD'; then
  echo "FAIL: cw_topic_repo_hash still has CW_TOPIC_REPO_CWD branch" >&2; exit 1
fi
pass "9. cw_topic_repo_hash has no CW_TOPIC_REPO_CWD branch"

# Invariant 10: at least one directive uses mktemp for args (sample: consult.md)
grep -q 'mktemp.*_args\|mktemp -p.*ARGS_DIR' "$PLUGIN_ROOT/commands/consult.md" \
  || { echo "FAIL: commands/consult.md doesn't use mktemp for args path" >&2; exit 1; }
pass "10. commands/consult.md uses mktemp for args path"

# Invariant 11: at least one bin script calls cw_args_file_consume
grep -l 'cw_args_file_consume' "$PLUGIN_ROOT/bin"/*.sh >/dev/null \
  || { echo "FAIL: no bin script calls cw_args_file_consume" >&2; exit 1; }
pass "11. cw_args_file_consume called by at least one bin script"

# Invariant 12: CLAUDE.md has v0.31.0 status + release-gate rows
grep -q "v0\.31\.0:" "$PLUGIN_ROOT/CLAUDE.md" \
  || { echo "FAIL: CLAUDE.md missing v0.31.0 status row" >&2; exit 1; }
grep -q "v0\.31\.0 strict-dogfood" "$PLUGIN_ROOT/CLAUDE.md" \
  || { echo "FAIL: CLAUDE.md missing v0.31.0 release-gate row" >&2; exit 1; }
pass "12. CLAUDE.md has v0.31.0 status + release-gate rows"

echo "test_v0_31_0_static_wiring: 12 invariants locked"
