#!/usr/bin/env bash
# tests/test_v0_46_0_static_wiring.sh
# Version-stamped static-wiring lock for v0.46.0 — simplification sweep.
# Skip-guards when plugin.json is not at 0.46.0 (so it passes via skip
# during v0.45.x work). Activates and locks 7 invariants when version
# matches.
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib/assert.sh

PLUGIN_JSON=".claude-plugin/plugin.json"
[[ -f "$PLUGIN_JSON" ]] || { echo "FAIL: $PLUGIN_JSON missing" >&2; exit 1; }

CURRENT_VERSION=$(grep -E '"version"' "$PLUGIN_JSON" | head -1 \
  | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')

if [[ "$CURRENT_VERSION" != "0.46.0" ]]; then
  echo "SKIP: plugin.json version $CURRENT_VERSION != 0.46.0 (v0.46.0 invariants inactive)"
  exit 0
fi

# Invariant 1: marketplace.json both version lines = 0.46.0
MKT=".claude-plugin/marketplace.json"
MKT_HITS=$(grep -cE '"version"[[:space:]]*:[[:space:]]*"0\.46\.0"' "$MKT" || true)
[[ "$MKT_HITS" -ge 2 ]] \
  || { echo "FAIL: marketplace.json should have ≥2 lines reading version 0.46.0 (got $MKT_HITS)" >&2; exit 1; }
pass "1. plugin.json + marketplace.json both at 0.46.0"

# Invariant 2: lib/deep-research.sh defines cw_deep_research_art_dir (#4)
LIB="lib/deep-research.sh"
grep -qE '^cw_deep_research_art_dir\(\)' "$LIB" \
  || { echo "FAIL: $LIB missing cw_deep_research_art_dir definition" >&2; exit 1; }
pass "2. lib/deep-research.sh exports cw_deep_research_art_dir"

# Invariant 3: lib/deep-research.sh defines cw_deep_research_metric_primary (#3)
grep -qE '^cw_deep_research_metric_primary\(\)' "$LIB" \
  || { echo "FAIL: $LIB missing cw_deep_research_metric_primary definition" >&2; exit 1; }
pass "3. lib/deep-research.sh exports cw_deep_research_metric_primary"

# Invariant 4: lib/deep-research.sh defines cw_deep_research_trooper_event (#9)
grep -qE '^cw_deep_research_trooper_event\(\)' "$LIB" \
  || { echo "FAIL: $LIB missing cw_deep_research_trooper_event definition" >&2; exit 1; }
pass "4. lib/deep-research.sh exports cw_deep_research_trooper_event"

# Invariant 5: lib/ipc.sh defines cw_jsonl_string_field (#1)
IPC="lib/ipc.sh"
grep -qE '^cw_jsonl_string_field\(\)' "$IPC" \
  || { echo "FAIL: $IPC missing cw_jsonl_string_field definition" >&2; exit 1; }
pass "5. lib/ipc.sh exports cw_jsonl_string_field"

# Invariant 6: no manual state_root+repo_hash+topic+_deep-research concat
# remains in bin/deep-research-*.sh (#4 enforcement). The pattern would
# look like `state_root=$(cw_state_root)` immediately followed (within ~3
# lines) by a path that splices repo_hash and /_deep-research.
# Pragmatic detection: grep for the literal string the migration replaced.
# shellcheck disable=SC2016 — single-quoted regex; $ chars are part of the pattern, not shell vars.
HITS_4=$(grep -lE '"\$state_root/state/\$repo_hash/\$TOPIC"' bin/deep-research-*.sh 2>/dev/null || true)
[[ -z "$HITS_4" ]] \
  || { echo "FAIL: manual state_root+repo_hash+TOPIC concat remains in: $HITS_4" >&2; exit 1; }
pass "6. no manual state_root+repo_hash+_deep-research concat in bin/deep-research-*.sh"

# Invariant 7: no raw pane_id regex grep outside lib/ipc.sh (#6)
HITS_6=$(grep -lE "'\"pane_id\"\[\[:space:\]\]\*:\[\[:space:\]\]\*\"%\[0-9\]\+\"'" bin/ lib/ 2>/dev/null | grep -v 'lib/ipc.sh' || true)
[[ -z "$HITS_6" ]] \
  || { echo "FAIL: open-coded pane_id grep remains in: $HITS_6" >&2; exit 1; }
pass "7. no open-coded pane_id grep outside lib/ipc.sh"

pass "test_v0_46_0_static_wiring: 7 invariants locked"
