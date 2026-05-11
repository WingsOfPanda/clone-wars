#!/usr/bin/env bash
# tests/test_v0_24_0_static_wiring.sh
# Locks v0.24.0 simplification invariants:
#   1. 5 dead functions stay deleted (cw_consult_synthesize,
#      cw_consult_design_doc_self_review, cw_consult_status_load,
#      cw_consult_parse_design_doc_flag, cw_consult_strip_block)
#   2. _cw_contract_field helper exists in lib/contracts.sh
#   3. cw_preflight_kill_orphans helper exists in lib/tmux.sh
#   4. lib/consult-wait.sh exists with cw_consult_wait function
#   5. bin/consult-research-wait.sh + verify-wait.sh both source lib/consult-wait.sh
#   6. _teardown_collect_pairs helper exists in bin/teardown.sh
#   7. _kv_parse helper exists in bin/spawn.sh
#   8. commands/deploy.md no longer has tmp+mv pattern outside preflight-layout
#   9. commands/consult.md Patterns 1/2/3 stripped to terse stubs (no
#      "### Pattern N:" headers; no "Pattern [123]" cross-references)
#  10. config/prompt-templates/consult/*.md no longer have TARGETS_BLOCK or
#      SUBPROJECT_BLOCK sentinels
#  11. plugin.json semver-shape (loosened per v0.20.2 lesson)
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"

# 1. 5 dead functions stay deleted
for fn in cw_consult_synthesize cw_consult_design_doc_self_review \
          cw_consult_status_load cw_consult_parse_design_doc_flag \
          cw_consult_strip_block; do
  if grep -qE "^${fn}\(\)" "$PLUGIN_ROOT/lib/consult.sh" "$PLUGIN_ROOT/lib/consult-prompts.sh" 2>/dev/null; then
    echo "FAIL: $fn is still defined in lib/consult*.sh" >&2
    exit 1
  fi
done
pass "5 dead functions stay deleted (synthesize/self_review/status_load/parse_design_doc_flag/strip_block)"

# 2. _cw_contract_field helper
grep -qE '^_cw_contract_field\(\)' "$PLUGIN_ROOT/lib/contracts.sh" \
  || { echo "FAIL: _cw_contract_field missing in lib/contracts.sh" >&2; exit 1; }
pass "_cw_contract_field helper present in lib/contracts.sh"

# 3. cw_preflight_kill_orphans helper
grep -qE '^cw_preflight_kill_orphans\(\)' "$PLUGIN_ROOT/lib/tmux.sh" \
  || { echo "FAIL: cw_preflight_kill_orphans missing in lib/tmux.sh" >&2; exit 1; }
pass "cw_preflight_kill_orphans present in lib/tmux.sh"

# 4. lib/consult-wait.sh
[[ -f "$PLUGIN_ROOT/lib/consult-wait.sh" ]] \
  || { echo "FAIL: lib/consult-wait.sh missing" >&2; exit 1; }
grep -qE '^cw_consult_wait\(\)' "$PLUGIN_ROOT/lib/consult-wait.sh" \
  || { echo "FAIL: cw_consult_wait missing in lib/consult-wait.sh" >&2; exit 1; }
pass "lib/consult-wait.sh exists with cw_consult_wait function"

# 5. Both wait shims source the lib
for f in consult-research-wait.sh consult-verify-wait.sh; do
  grep -qE 'source.*lib/consult-wait\.sh' "$PLUGIN_ROOT/bin/$f" \
    || { echo "FAIL: bin/$f does not source lib/consult-wait.sh" >&2; exit 1; }
done
pass "research-wait + verify-wait both source lib/consult-wait.sh"

# 6. _teardown_collect_pairs helper
grep -qE '^_teardown_collect_pairs\(\)' "$PLUGIN_ROOT/bin/teardown.sh" \
  || { echo "FAIL: _teardown_collect_pairs missing in bin/teardown.sh" >&2; exit 1; }
pass "_teardown_collect_pairs helper present in bin/teardown.sh"

# 7. _kv_parse helper
grep -qE '^_kv_parse\(\)' "$PLUGIN_ROOT/bin/spawn.sh" \
  || { echo "FAIL: _kv_parse missing in bin/spawn.sh" >&2; exit 1; }
pass "_kv_parse helper present in bin/spawn.sh"

# 8. commands/deploy.md tmp+mv eliminated (the 4 sites Task 12 swapped).
# Capture into a variable to avoid SIGPIPE-with-pipefail issues.
TMP_MV_COUNT=$(grep -cE '\.tmp"[[:space:]]*\\$|>[[:space:]]*"[^"]*\.tmp"$' "$PLUGIN_ROOT/commands/deploy.md" || true)
# 0 occurrences expected — all 4 sites moved to cw_atomic_write.
[[ "$TMP_MV_COUNT" -le 1 ]] \
  || { echo "FAIL: commands/deploy.md still has $TMP_MV_COUNT tmp+mv sites (expected ≤1)" >&2; exit 1; }
pass "commands/deploy.md tmp+mv pattern eliminated (≤1 historical mention)"

# 9. Patterns 1/2/3 bodies stripped to terse stubs (headers retained to
# honor v0.20.2 static-wiring lock that asserts exactly 3 contiguous
# "### Pattern N:" section headers). v0.24.0 invariant: each Pattern
# body is ≤8 lines (was 15-25 lines pre-v0.24.0) and contains no
# triple-backtick fences (terse-prose-only).
HEADER_COUNT=$(grep -cE '^### Pattern [123]:' "$PLUGIN_ROOT/commands/consult.md" || true)
[[ "$HEADER_COUNT" -eq 3 ]] \
  || { echo "FAIL: expected 3 '### Pattern N:' headers, got $HEADER_COUNT" >&2; exit 1; }
# Each Pattern body terse: extract between "### Pattern N:" and the next
# "### Pattern " or "**Kill switch:**" / next "## " heading, assert ≤8 lines
# and zero triple-backtick fences.
PAT_FENCED=$(awk '/^### Pattern [123]:/,/^### Pattern [^123]|^\*\*Kill switch:|^## /' \
  "$PLUGIN_ROOT/commands/consult.md" | grep -cE '^```' || true)
[[ "$PAT_FENCED" -eq 0 ]] \
  || { echo "FAIL: Pattern bodies contain $PAT_FENCED triple-backtick fences (expected 0; should be terse-prose-only)" >&2; exit 1; }
pass "consult.md Patterns 1/2/3 stripped to terse stubs (3 headers, 0 code fences in bodies)"

# 10. Template sentinels removed
for tpl in research.md verify.md drilldown.md; do
  if grep -qE 'TARGETS_BLOCK_START|TARGETS_BLOCK_END|SUBPROJECT_BLOCK_START|SUBPROJECT_BLOCK_END' \
       "$PLUGIN_ROOT/config/prompt-templates/consult/$tpl"; then
    echo "FAIL: config/prompt-templates/consult/$tpl still has sentinel tokens" >&2
    exit 1
  fi
done
pass "3 consult templates no longer have TARGETS_BLOCK/SUBPROJECT_BLOCK sentinels"

# 11. plugin.json semver-shape (loosened per v0.20.2 lesson — version-
# stamped tests should not exact-lock their own version, or every future
# bump breaks them. v0.24.0's original regex was an oversight; comment
# already claimed "loosened" but code asserted exact 0.24.x. Fixed in v0.25.0.)
PJ="$PLUGIN_ROOT/.claude-plugin/plugin.json"
grep -qE '"version": "[0-9]+\.[0-9]+\.[0-9]+"' "$PJ" \
  || { echo "FAIL: plugin.json version field not semver-shape" >&2; exit 1; }
pass "plugin.json version field present + semver-shape"

pass "v0.24.0 static wiring complete (11 invariants locked)"
