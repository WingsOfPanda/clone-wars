#!/usr/bin/env bash
# tests/test_v0_44_0_static_wiring.sh
# Version-stamped static-wiring lock for v0.44.0. Skip-guards when
# plugin.json is not at 0.44.0 (so it passes via skip during v0.43.x
# work). Activates and locks 6 invariants when version matches.
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib/assert.sh

PLUGIN_JSON=".claude-plugin/plugin.json"
[[ -f "$PLUGIN_JSON" ]] || { echo "FAIL: $PLUGIN_JSON missing" >&2; exit 1; }

CURRENT_VERSION=$(grep -E '"version"' "$PLUGIN_JSON" | head -1 \
  | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')

if [[ "$CURRENT_VERSION" != "0.44.0" ]]; then
  echo "SKIP: plugin.json version $CURRENT_VERSION != 0.44.0 (v0.44.0 invariants inactive)"
  exit 0
fi

# Invariant 1: marketplace.json both version lines = 0.44.0
MKT=".claude-plugin/marketplace.json"
MKT_HITS=$(grep -cE '"version"[[:space:]]*:[[:space:]]*"0\.44\.0"' "$MKT")
[[ "$MKT_HITS" -ge 2 ]] \
  || { echo "FAIL: marketplace.json should have ≥2 lines reading version 0.44.0 (got $MKT_HITS)" >&2; exit 1; }
pass "1. plugin.json + marketplace.json both at 0.44.0"

# Invariant 2 (Lane A): lib/deep-research.sh defines cw_deep_research_format_sota_block
LIB="lib/deep-research.sh"
grep -qE '^cw_deep_research_format_sota_block\(\)' "$LIB" \
  || { echo "FAIL: $LIB missing cw_deep_research_format_sota_block definition" >&2; exit 1; }
pass "2. lib/deep-research.sh exports cw_deep_research_format_sota_block"

# Invariant 3 (Lane B): commands/deep-research.md carries Phase 1.5 SOTA sweep heading
DIR="commands/deep-research.md"
grep -qE '^### Phase 1\.5 — SOTA sweep$' "$DIR" \
  || { echo "FAIL: directive missing '### Phase 1.5 — SOTA sweep' heading" >&2; exit 1; }
pass "3. commands/deep-research.md carries Phase 1.5 SOTA sweep heading"

# Invariant 4 (Lane C): bin/deep-research-experiment-send.sh references $ART_DIR/sota.md
ES="bin/deep-research-experiment-send.sh"
grep -qE 'ART_DIR/sota\.md|SOTA_MD=' "$ES" \
  || { echo "FAIL: experiment-send.sh missing sota.md read" >&2; exit 1; }
pass "4. experiment-send.sh reads sota.md from art dir"

# Invariant 5 (Lane C): template carries the {{SOTA_BLOCK}} placeholder
TPL="config/prompt-templates/deep-research/experiment.md"
grep -qE '\{\{SOTA_BLOCK\}\}' "$TPL" \
  || { echo "FAIL: dispatch template missing {{SOTA_BLOCK}} placeholder" >&2; exit 1; }
pass "5. dispatch template carries {{SOTA_BLOCK}} placeholder"

# Invariant 6: CLAUDE.md Current focus names v0.44.0
grep -qE 'Most recent merge:.*v0\.44\.0' CLAUDE.md \
  || { echo "FAIL: CLAUDE.md Current focus should name v0.44.0" >&2; exit 1; }
pass "6. CLAUDE.md Current focus names v0.44.0"

pass "test_v0_44_0_static_wiring: 6 invariants locked"
