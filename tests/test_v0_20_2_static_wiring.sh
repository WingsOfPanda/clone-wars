#!/usr/bin/env bash
# tests/test_v0_20_2_static_wiring.sh
# v0.20.2 stale-string fixes — static wiring assertions across:
# - Fix 1a: bin/consult-drilldown.sh signature change (no synthesis.md;
#   takes <design-doc-path> as positional arg 5; valid arg counts 7/8/9/10)
# - Fix 1b: commands/consult.md Step 13 derives via canonical_path helper
#   and passes "$DESIGN_DOC" to every consult-drilldown.sh invocation
# - Fix 2:  Pattern numbering 1,2,3 (was 1,3,4)
# - Fix 3:  /spec purged from lib/consult.sh
# - Fix 4:  drill template no longer says "synthesis"
# - Fix 5:  helper signature comment uses <design-doc-path>
# - Fix 6:  plugin.json + marketplace.json at 0.20.2
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib/assert.sh

# ---- Fix 1a: bin/consult-drilldown.sh signature change ----
drill_src=$(cat bin/consult-drilldown.sh)
[[ "$drill_src" != *'synthesis.md'* ]] || { echo "FAIL: drilldown still references synthesis.md"; exit 1; }
[[ "$drill_src" == *'DESIGN_DOC='* ]]   || { echo "FAIL: drilldown missing DESIGN_DOC unpack"; exit 1; }
[[ "$drill_src" == *'<design-doc-path>'* ]] || { echo "FAIL: drilldown usage missing <design-doc-path>"; exit 1; }
[[ "$drill_src" == *'design-doc not found'* ]] || { echo "FAIL: drilldown missing 'design-doc not found' validation"; exit 1; }

# Arg-count guard updated to 7|8|9|10
[[ "$drill_src" == *'$# -eq 7'* ]]  || { echo "FAIL: drilldown arg-count guard not bumped to 7+"; exit 1; }
[[ "$drill_src" == *'$# -eq 10'* ]] || { echo "FAIL: drilldown arg-count guard missing 10"; exit 1; }
pass "Fix 1a: bin/consult-drilldown.sh signature wired"

# ---- Fix 1b: commands/consult.md Step 13 derives + threads $DESIGN_DOC ----
dir_src=$(cat commands/consult.md)
[[ "$dir_src" == *'cw_consult_design_doc_canonical_path'* ]] \
  || { echo "FAIL: directive missing canonical_path helper call"; exit 1; }
[[ "$dir_src" == *'$DESIGN_DOC'* ]] \
  || { echo "FAIL: directive doesn't pass \$DESIGN_DOC to drilldown"; exit 1; }
# All 4 example invocations of consult-drilldown.sh in Step 13 should
# include $DESIGN_DOC as a positional arg. Sentinel check: count of
# "$DESIGN_DOC" must be ≥ count of consult-drilldown.sh invocation lines
# (each backslash-continued invocation has one $DESIGN_DOC line under it).
n_invocations=$(grep -c 'CLAUDE_PLUGIN_ROOT/bin/consult-drilldown.sh' commands/consult.md || true)
n_designdoc_inv=$(grep -cE '^[[:space:]]+"\$DESIGN_DOC"[[:space:]]*\\?$' commands/consult.md || true)
[[ "$n_designdoc_inv" -ge "$n_invocations" ]] \
  || { echo "FAIL: \$DESIGN_DOC threaded count ($n_designdoc_inv) < drilldown invocations ($n_invocations)"; exit 1; }
pass "Fix 1b: commands/consult.md Step 13 derives + threads \$DESIGN_DOC"

# ---- Fix 2: Pattern numbering contiguous 1,2,3 (no 4, no skipped 2) ----
patterns=$(grep -E '^### Pattern [0-9]+:' commands/consult.md | awk '{print $3}' | tr -d ':')
expected=$'1\n2\n3'
[[ "$patterns" == "$expected" ]] \
  || { echo "FAIL: Pattern numbering not 1,2,3 (got: $(echo "$patterns" | tr '\n' ',' ))"; exit 1; }
# No orphan "Pattern 4" cross-references
n_pattern4=$(grep -cE '\bPattern 4\b' commands/consult.md || true)
[[ "$n_pattern4" == "0" ]] \
  || { echo "FAIL: $n_pattern4 orphan Pattern 4 cross-references remain"; exit 1; }
pass "Fix 2: Pattern numbering 1,2,3 contiguous + no orphan refs"

# ---- Fix 3: /spec purged from lib/consult.sh ----
hits=$(grep -c '/spec ' lib/consult.sh || true)
[[ "$hits" == "0" ]] || { echo "FAIL: lib/consult.sh has $hits /spec references (expected 0)"; exit 1; }
pass "Fix 3: lib/consult.sh /spec references purged"

# ---- Fix 4: drill template no longer says "synthesis" ----
tmpl=$(cat config/prompt-templates/consult/drilldown.md)
[[ "$tmpl" != *'synthesis'* ]] || { echo "FAIL: drill template still says 'synthesis'"; exit 1; }
[[ "$tmpl" == *'design doc'* ]] || { echo "FAIL: drill template missing 'design doc'"; exit 1; }
pass "Fix 4: drill template prose updated"

# ---- Fix 5: helper signature comment uses <design-doc-path> ----
prompts_src=$(cat lib/consult-prompts.sh)
[[ "$prompts_src" != *'<synthesis-path>'* ]] \
  || { echo "FAIL: lib/consult-prompts.sh still has <synthesis-path>"; exit 1; }
[[ "$prompts_src" == *'<design-doc-path>'* ]] \
  || { echo "FAIL: lib/consult-prompts.sh missing <design-doc-path>"; exit 1; }
pass "Fix 5: helper signature comment renamed"

# ---- Fix 6: version bump in both manifests ----
# v0.20.3+: accept any 0.20.x (or higher minor) so this test stays useful
# after subsequent version bumps. The exact version-lock for the current
# release lives in that release's own static-wiring test.
grep -qE '"version": "0\.[0-9]+\.[0-9]+"' .claude-plugin/plugin.json \
  || { echo "FAIL: .claude-plugin/plugin.json missing semver-shaped version"; exit 1; }
grep -qE '"version": "0\.[0-9]+\.[0-9]+"' .claude-plugin/marketplace.json \
  || { echo "FAIL: .claude-plugin/marketplace.json missing semver-shaped version"; exit 1; }
pass "Fix 6: version present in both manifests (semver-shaped)"

echo "ALL PASS — v0.20.2 stale-string sweep wiring locked"
