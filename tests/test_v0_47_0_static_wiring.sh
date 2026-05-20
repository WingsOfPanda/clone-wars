#!/usr/bin/env bash
# tests/test_v0_47_0_static_wiring.sh
# Version-stamped static-wiring lock for v0.47.0 — simplification sweep part 2.
# Skip-guards when plugin.json is not at 0.47.0 (so it passes via skip
# during v0.46.x work). Activates and locks 5 invariants when version
# matches.
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib/assert.sh

PLUGIN_JSON=".claude-plugin/plugin.json"
[[ -f "$PLUGIN_JSON" ]] || { echo "FAIL: $PLUGIN_JSON missing" >&2; exit 1; }

CURRENT_VERSION=$(grep -E '"version"' "$PLUGIN_JSON" | head -1 \
  | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')

if [[ "$CURRENT_VERSION" != "0.47.0" ]]; then
  echo "SKIP: plugin.json version $CURRENT_VERSION != 0.47.0 (v0.47.0 invariants inactive)"
  exit 0
fi

# Invariant 1: marketplace.json both version lines = 0.47.0
MKT=".claude-plugin/marketplace.json"
MKT_HITS=$(grep -cE '"version"[[:space:]]*:[[:space:]]*"0\.47\.0"' "$MKT" || true)
[[ "$MKT_HITS" -ge 2 ]] \
  || { echo "FAIL: marketplace.json should have ≥2 lines reading version 0.47.0 (got $MKT_HITS)" >&2; exit 1; }
pass "1. plugin.json + marketplace.json both at 0.47.0"

# Invariant 2: cw_deep_research_json_field defined in lib/deep-research.sh (#2)
# Negative-check: no _cw_dr_json_field references anywhere (rename was atomic).
LIB="lib/deep-research.sh"
grep -qE '^cw_deep_research_json_field\(\)' "$LIB" \
  || { echo "FAIL: $LIB missing cw_deep_research_json_field definition" >&2; exit 1; }
LEFTOVER=$(grep -rnE '_cw_dr_json_field' lib/ bin/ tests/ 2>/dev/null | grep -v 'test_v0_47_0_static_wiring.sh' || true)
[[ -z "$LEFTOVER" ]] \
  || { echo "FAIL: leftover _cw_dr_json_field references:" >&2; echo "$LEFTOVER" >&2; exit 1; }
pass "2. lib/deep-research.sh exports cw_deep_research_json_field (no underscore leftover)"

# Invariant 3: cw_outbox_path_in defined in lib/ipc.sh (#5-partial)
IPC="lib/ipc.sh"
grep -qE '^cw_outbox_path_in\(\)' "$IPC" \
  || { echo "FAIL: $IPC missing cw_outbox_path_in definition" >&2; exit 1; }
pass "3. lib/ipc.sh exports cw_outbox_path_in"

# Invariant 4: .claude/hooks/_lib.sh exists and defines cw_hook_file_path_from_stdin (#8)
HOOKLIB=".claude/hooks/_lib.sh"
[[ -f "$HOOKLIB" ]] \
  || { echo "FAIL: $HOOKLIB missing" >&2; exit 1; }
grep -qE '^cw_hook_file_path_from_stdin\(\)' "$HOOKLIB" \
  || { echo "FAIL: $HOOKLIB missing cw_hook_file_path_from_stdin definition" >&2; exit 1; }
pass "4. .claude/hooks/_lib.sh exports cw_hook_file_path_from_stdin"

# Invariant 5: both project hooks source _lib.sh and don't open-code the file_path grep (#8)
for h in .claude/hooks/post-edit-hardcoded-paths-lint.sh .claude/hooks/post-version-bump-lock-check.sh; do
  grep -qE 'source.*_lib\.sh' "$h" \
    || { echo "FAIL: $h does not source _lib.sh" >&2; exit 1; }
  if grep -qE "grep -oE.*\"file_path\"" "$h"; then
    echo "FAIL: $h still has open-coded file_path grep" >&2
    exit 1
  fi
done
pass "5. both project hooks source _lib.sh and skip open-coded file_path grep"

pass "test_v0_47_0_static_wiring: 5 invariants locked"
