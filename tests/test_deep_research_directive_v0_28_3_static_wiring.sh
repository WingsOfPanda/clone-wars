#!/usr/bin/env bash
# tests/test_deep_research_directive_v0_28_3_static_wiring.sh
# v0.28.3 directive prose lock — Phase 3 split into 3a (preflight) + 3b
# (parallel dispatch with --target-pane).
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
DIRECTIVE="$PLUGIN_ROOT/commands/deep-research.md"

[[ -f "$DIRECTIVE" ]] || { echo "FAIL: $DIRECTIVE not found" >&2; exit 1; }

# 1. Phase 3a heading present
grep -qE '^### Phase 3a — Preflight pane allocation' "$DIRECTIVE" \
  || { echo "FAIL: Phase 3a heading missing" >&2; exit 1; }
pass "1. Phase 3a heading present"

# 2. Phase 3b heading present
grep -qE '^### Phase 3b — Parallel dispatch' "$DIRECTIVE" \
  || { echo "FAIL: Phase 3b heading missing" >&2; exit 1; }
pass "2. Phase 3b heading present"

# 3. Phase 3a invokes preflight-layout.sh with --art-dir + --troopers-from
grep -q 'preflight-layout.sh' "$DIRECTIVE" \
  || { echo "FAIL: directive doesn't reference preflight-layout.sh" >&2; exit 1; }
grep -qF -e '--art-dir' "$DIRECTIVE" \
  || { echo "FAIL: directive doesn't pass --art-dir to preflight-layout.sh" >&2; exit 1; }
grep -qF -e '--troopers-from' "$DIRECTIVE" \
  || { echo "FAIL: directive doesn't pass --troopers-from to preflight-layout.sh" >&2; exit 1; }
pass "3. preflight-layout.sh invoked with --art-dir + --troopers-from"

# 4. cw_deep_research_write_preflight_sidecar referenced
grep -q 'cw_deep_research_write_preflight_sidecar' "$DIRECTIVE" \
  || { echo "FAIL: directive doesn't call cw_deep_research_write_preflight_sidecar" >&2; exit 1; }
pass "4. cw_deep_research_write_preflight_sidecar referenced"

# 5. Phase 3b spawn block uses --target-pane + --preflight-art-dir
grep -qF -e '--target-pane' "$DIRECTIVE" \
  || { echo "FAIL: spawn block missing --target-pane" >&2; exit 1; }
grep -qF -e '--preflight-art-dir' "$DIRECTIVE" \
  || { echo "FAIL: spawn block missing --preflight-art-dir" >&2; exit 1; }
pass "5. spawn block uses --target-pane + --preflight-art-dir"

# 6. SPAWN_RETRY_COUNT wiring present (Stage 1 retry)
grep -q 'SPAWN_RETRY_COUNT' "$DIRECTIVE" \
  || { echo "FAIL: SPAWN_RETRY_COUNT missing" >&2; exit 1; }
pass "6. SPAWN_RETRY_COUNT retry wiring present"

# 7. Stage 2 partial-success path present
grep -qE 'Stage 2 partial-success|Proceed degraded' "$DIRECTIVE" \
  || { echo "FAIL: Stage 2 partial-success branch missing" >&2; exit 1; }
pass "7. Stage 2 partial-success branch present"

# 8. NEGATIVE assertion: no legacy bare `bin/spawn.sh <cmdr> codex "$DEEP_TOPIC"`
# without --target-pane. Each spawn.sh occurrence must have --target-pane on
# the same line OR within 5 lines downstream (multi-line dispatch template).
legacy=$(awk '
  /bin\/spawn\.sh/ {
    if ($0 ~ /--target-pane/) next
    line=NR; near=0
    for (i=1; i<=5; i++) {
      if ((getline buf) <= 0) break
      if (buf ~ /--target-pane/) { near=1; break }
    }
    if (!near) print line
  }
' "$DIRECTIVE" || true)
if [[ -n "$legacy" ]]; then
  echo "FAIL: directive contains spawn.sh reference NOT paired with --target-pane within 5 lines:" >&2
  echo "  line(s): $legacy" >&2
  exit 1
fi
pass "8. no legacy spawn.sh call without --target-pane"

# 9. Phase 4.a step 1 atomic troopers.txt write still present
# (v0.28.2 invariant 5 — must be preserved)
grep -qE 'troopers\.txt\.tmp.*mv|mv.*troopers\.txt\.tmp' "$DIRECTIVE" \
  || { echo "FAIL: Phase 4.a atomic troopers.txt write disappeared (v0.28.2 invariant 5 broken)" >&2; exit 1; }
pass "9. Phase 4.a atomic troopers.txt write preserved (v0.28.2 invariant 5)"

echo "test_deep_research_directive_v0_28_3_static_wiring: 9 invariants locked"
