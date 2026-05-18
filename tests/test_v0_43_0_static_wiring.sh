#!/usr/bin/env bash
# tests/test_v0_43_0_static_wiring.sh
# Version-stamped static-wiring lock for v0.43.0. Skip-guards when
# plugin.json is not at 0.43.0 (so it passes via skip during v0.42.x
# work). Activates and locks 9 invariants when version matches.
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib/assert.sh

PLUGIN_JSON=".claude-plugin/plugin.json"
[[ -f "$PLUGIN_JSON" ]] || { echo "FAIL: $PLUGIN_JSON missing" >&2; exit 1; }

CURRENT_VERSION=$(grep -E '"version"' "$PLUGIN_JSON" | head -1 \
  | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')

if [[ "$CURRENT_VERSION" != "0.43.0" ]]; then
  echo "SKIP: plugin.json version $CURRENT_VERSION != 0.43.0 (v0.43.0 invariants inactive)"
  exit 0
fi

# Invariant 1: marketplace.json both version lines = 0.43.0
MKT=".claude-plugin/marketplace.json"
MKT_HITS=$(grep -cE '"version"[[:space:]]*:[[:space:]]*"0\.43\.0"' "$MKT")
[[ "$MKT_HITS" -ge 2 ]] \
  || { echo "FAIL: marketplace.json should have ≥2 lines reading version 0.43.0 (got $MKT_HITS)" >&2; exit 1; }
pass "1. plugin.json + marketplace.json both at 0.43.0"

# Invariant 2 (Lane A): finalize.sh re-renders summary unconditionally BEFORE the ## Halt append.
FIN="bin/deep-research-finalize.sh"
awk '
  /cw_deep_research_render_summary "\$ART" \| cw_atomic_write/ { saw_render=1 }
  /^## Halt$/                                                  { saw_halt=1 }
  END { exit (saw_render && saw_halt) ? 0 : 1 }
' "$FIN" \
  || { echo "FAIL: finalize.sh missing unconditional render_summary call before ## Halt append" >&2; exit 1; }
pass "2. finalize.sh re-renders session-summary unconditionally on halt"

# Invariant 3 (Lane B): teardown.sh contains BOTH orphan-sweep find pattern AND winner symlink.
TD="bin/deep-research-teardown.sh"
grep -qE 'find "\$ART_DIR/shared" .*-name .\*\.tmp' "$TD" \
  || { echo "FAIL: teardown.sh missing shared/ *.tmp sweep" >&2; exit 1; }
grep -qE 'ln -sfn .* "\$ART_DIR/winner"' "$TD" \
  || { echo "FAIL: teardown.sh missing winner symlink creation" >&2; exit 1; }
pass "3. teardown.sh sweeps shared/ orphans + creates winner symlink"

# Invariant 4 (Lane C): experiment-send.sh parses --smoke-test flag.
ES="bin/deep-research-experiment-send.sh"
grep -qE '\-\-smoke-test=\*|\-\-smoke-test\)' "$ES" \
  || { echo "FAIL: experiment-send.sh missing --smoke-test flag parser" >&2; exit 1; }
grep -qE 'CW_SMOKE_TEST=1 timeout' "$ES" \
  || { echo "FAIL: experiment-send.sh missing smoke-test execution with timeout" >&2; exit 1; }
pass "4. experiment-send.sh parses --smoke-test + executes with timeout"

# Invariant 5 (Lane D): resume.md Step 5 references phase=abandoned via lane_abandon helper.
RES="commands/deep-research-resume.md"
grep -qE 'cw_deep_research_lane_abandon' "$RES" \
  || { echo "FAIL: resume.md missing cw_deep_research_lane_abandon call" >&2; exit 1; }
grep -qE 'phase=abandoned' "$RES" \
  || { echo "FAIL: resume.md missing phase=abandoned reference" >&2; exit 1; }
pass "5. resume.md Step 5 wires lane-abandon decision via cw_deep_research_lane_abandon"

# Invariant 6 (Lane E): commands/deep-research.md has halt.flag format spec section.
DIR="commands/deep-research.md"
grep -qE '^## halt\.flag format|^### halt\.flag format' "$DIR" \
  || { echo "FAIL: directive missing halt.flag format spec section" >&2; exit 1; }
grep -qE 'halted_by=user\|yoda' "$DIR" \
  || { echo "FAIL: directive halt.flag spec missing 'halted_by=user|yoda'" >&2; exit 1; }
pass "6. commands/deep-research.md carries halt.flag format spec section"

# Invariant 7 (Lane E): Phase 4.a has context-file guidance note (Item 9).
PHASE4A=$(awk '/^### Phase 4 — |^#### 4\.a/,/^### Phase 5/' "$DIR")
echo "$PHASE4A" | grep -qE '\-\-context-file' \
  || { echo "FAIL: Phase 4.a missing --context-file reference" >&2; exit 1; }
echo "$PHASE4A" | grep -qiE 'do.{0,5}not.*write.{0,30}context\.md|NOT.{0,30}context\.md' \
  || { echo "FAIL: Phase 4.a missing 'do not write context.md' clause" >&2; exit 1; }
pass "7. commands/deep-research.md Phase 4.a carries context-file guidance note"

# Invariant 8 (Lane E): abort.sh writes halt.flag in structured key=value format.
AB="bin/deep-research-abort.sh"
grep -qE "printf 'halted_by=user" "$AB" \
  || { echo "FAIL: abort.sh missing halted_by=user printf" >&2; exit 1; }
grep -qE "printf 'halted_at=" "$AB" \
  || { echo "FAIL: abort.sh missing halted_at= printf" >&2; exit 1; }
grep -qE "printf 'reason=" "$AB" \
  || { echo "FAIL: abort.sh missing reason= printf" >&2; exit 1; }
pass "8. bin/deep-research-abort.sh writes halt.flag in structured key=value format"

# Invariant 9: CLAUDE.md Current focus names v0.43.0
grep -qE 'Most recent merge:.*v0\.43\.0' CLAUDE.md \
  || { echo "FAIL: CLAUDE.md Current focus should name v0.43.0" >&2; exit 1; }
pass "9. CLAUDE.md Current focus names v0.43.0"

pass "test_v0_43_0_static_wiring: 9 invariants locked"
