#!/usr/bin/env bash
# tests/test_v0_40_0_static_wiring.sh
# Version-stamped static-wiring lock for v0.40.0. Skip-guards when
# plugin.json is not at 0.40.0 (so it passes via skip during v0.39.x
# work). Activates and locks 7 invariants when version matches.
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib/assert.sh

PLUGIN_JSON=".claude-plugin/plugin.json"
[[ -f "$PLUGIN_JSON" ]] || { echo "FAIL: $PLUGIN_JSON missing" >&2; exit 1; }

CURRENT_VERSION=$(grep -E '"version"' "$PLUGIN_JSON" | head -1 \
  | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')

if [[ "$CURRENT_VERSION" != "0.40.0" ]]; then
  echo "SKIP: plugin.json version $CURRENT_VERSION != 0.40.0 (v0.40.0 invariants inactive)"
  exit 0
fi

# Invariant 1: marketplace.json both version lines = 0.40.0
MKT=".claude-plugin/marketplace.json"
MKT_HITS=$(grep -cE '"version"[[:space:]]*:[[:space:]]*"0\.40\.0"' "$MKT")
[[ "$MKT_HITS" -ge 2 ]] \
  || { echo "FAIL: marketplace.json should have ≥2 lines reading version 0.40.0 (got $MKT_HITS)" >&2; exit 1; }
pass "1. plugin.json + marketplace.json both at 0.40.0"

# Invariant 2: hook reads stdin
HOOK="hooks/user-prompt-submit-active-session.sh"
grep -qE '^PAYLOAD=\$\(cat' "$HOOK" \
  || { echo "FAIL: hook should read stdin into PAYLOAD via 'cat'" >&2; exit 1; }
pass "2. hook reads stdin payload"

# Invariant 3: hook extracts .session_id (jq AND sed fallback both present)
# shellcheck disable=SC2016  # literal jq filter, single-quoted intentionally
grep -qE "jq -r '\.session_id" "$HOOK" \
  || { echo "FAIL: hook missing jq extractor for .session_id" >&2; exit 1; }
grep -qE '"session_id"' "$HOOK" \
  || { echo "FAIL: hook missing sed-fallback for .session_id" >&2; exit 1; }
pass "3. hook extracts .session_id (jq + sed fallback)"

# Invariant 4: hook find pattern matches active-<SESSION_ID>.txt (not bare)
# shellcheck disable=SC2016  # literal regex
grep -qE 'find ".*STATE_ROOT".*-name "active-\$\{SESSION_ID\}\.txt"' "$HOOK" \
  || { echo "FAIL: hook find should target -name \"active-\${SESSION_ID}.txt\"" >&2; exit 1; }
pass "4. hook find targets active-\${SESSION_ID}.txt"

# Invariant 5: init.sh writes session-stamped marker
INIT="bin/deep-research-init.sh"
# shellcheck disable=SC2016  # literal regex
grep -qE 'active-\$\{session_id\}\.txt' "$INIT" \
  || { echo "FAIL: init.sh should write active-\${session_id}.txt" >&2; exit 1; }
pass "5. deep-research-init.sh writes active-\${session_id}.txt"

# Invariant 6: cw_state_init writes .session_id
IPC="lib/ipc.sh"
# shellcheck disable=SC2016  # literal regex
grep -qE '\$dir/\.session_id' "$IPC" \
  || { echo "FAIL: cw_state_init should write \$dir/.session_id" >&2; exit 1; }
pass "6. cw_state_init writes \$dir/.session_id"

# Invariant 7: CLAUDE.md Current focus names v0.40.0
grep -qE 'Most recent merge:.*v0\.40\.0' CLAUDE.md \
  || { echo "FAIL: CLAUDE.md Current focus should name v0.40.0" >&2; exit 1; }
pass "7. CLAUDE.md Current focus names v0.40.0"

pass "test_v0_40_0_static_wiring: 7 invariants locked"
