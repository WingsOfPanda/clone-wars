#!/usr/bin/env bash
# tests/test_v0_20_4_static_wiring.sh
# Locks v0.20.4 simplification + bug-fix invariants.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"

# 1. spawn.sh MODE chained-|| split into separate guards (finding #11).
SPAWN="$PLUGIN_ROOT/bin/spawn.sh"
! grep -qE 'MODE=\$\(cw_contract_default_mode "\$MODEL"\)\s*\|\|\s*MODE=full' "$SPAWN" \
  || { echo "FAIL: spawn.sh:150 still has chained-|| MODE=full" >&2; exit 1; }
grep -qE '\[\[ -n "\$MODE" \]\] \|\| MODE=\$\(cw_contract_default_mode "\$MODEL"\)' "$SPAWN" \
  || { echo "FAIL: spawn.sh missing first-guard MODE assignment" >&2; exit 1; }
pass "spawn.sh MODE fallthrough split into separate guards"

# 2. consult-drilldown.sh collision counter uses BASH_REMATCH regex (finding #33).
DRILL="$PLUGIN_ROOT/bin/consult-drilldown.sh"
! grep -qE '\$\{base%-\[0-9\]\*\}' "$DRILL" \
  || { echo "FAIL: drilldown still uses bash-glob \${base%-[0-9]*} strip" >&2; exit 1; }
grep -qE 'BASH_REMATCH' "$DRILL" \
  || { echo "FAIL: drilldown collision counter missing BASH_REMATCH regex" >&2; exit 1; }
pass "consult-drilldown.sh collision counter uses regex strip"

# 3. deploy.md has exactly ONE source-defaulting find invocation, scoped by REPO_HASH (finding #27).
DEPLOY_MD="$PLUGIN_ROOT/commands/deploy.md"
n_find=$(grep -cE 'find "\$STATE_ROOT' "$DEPLOY_MD" || true)
[[ "$n_find" -eq 1 ]] \
  || { echo "FAIL: deploy.md has $n_find 'find \"\$STATE_ROOT' invocations (expected 1)" >&2; exit 1; }
n_unscoped=$(grep -cE 'find "\$STATE_ROOT" ' "$DEPLOY_MD" || true)
[[ "$n_unscoped" -eq 0 ]] \
  || { echo "FAIL: deploy.md has $n_unscoped unscoped 'find \"\$STATE_ROOT\" ' invocations (expected 0)" >&2; exit 1; }
grep -qE 'find "\$STATE_ROOT/state/\$REPO_HASH"' "$DEPLOY_MD" \
  || { echo "FAIL: deploy.md source-defaulting find missing REPO_HASH scope" >&2; exit 1; }
pass "deploy.md source-defaulting block is single + repo-hash-scoped"

# 4. preflight-layout.sh emits log_warn near CMDR_TO_CWD load (finding #14).
PREFLIGHT="$PLUGIN_ROOT/bin/preflight-layout.sh"
awk '/declare -A CMDR_TO_CWD/{f=1; n=0} f{n++; if (n>15) f=0} f && /log_warn.*cwd-map/{found=1} END{exit !found}' "$PREFLIGHT" \
  || { echo "FAIL: preflight-layout.sh missing log_warn within 15 lines of CMDR_TO_CWD declaration" >&2; exit 1; }
pass "preflight-layout.sh warns on malformed cwd-map lines"

# 5. lib/consult.sh dead helpers removed (findings #1 + #2).
CONSULT="$PLUGIN_ROOT/lib/consult.sh"
! grep -qE '^cw_consult_design_doc_filename\(\)' "$CONSULT" \
  || { echo "FAIL: cw_consult_design_doc_filename still defined" >&2; exit 1; }
! grep -qE '^cw_consult_design_doc_assemble\(\)' "$CONSULT" \
  || { echo "FAIL: cw_consult_design_doc_assemble still defined" >&2; exit 1; }
pass "dead helpers cw_consult_design_doc_filename + _assemble removed"

# 6. commands/consult.md --design-doc deprecation block trimmed (finding #24).
CONSULT_MD="$PLUGIN_ROOT/commands/consult.md"
# Block is the prose between the parse-block opener and the next bold heading.
# Count lines from the first `--design-doc` flag mention to the next blank+bold heading.
block_lines=$(awk '
  /\*\*.*--design-doc.*flag parsing/{f=1; n=0; next}
  f && /^\*\*v0\.16\.0/{f=0; print n; exit}
  f{n++}
' "$CONSULT_MD")
[[ -n "$block_lines" && "$block_lines" -le 12 ]] \
  || { echo "FAIL: --design-doc parse block is $block_lines lines (expected ≤12)" >&2; exit 1; }
grep -qE 'obsolete in v0\.17\.0' "$CONSULT_MD" \
  || { echo "FAIL: --design-doc deprecation chat-note 'obsolete in v0.17.0' missing" >&2; exit 1; }
pass "--design-doc deprecation block trimmed (≤12 lines, chat-note preserved)"

# 7. commands/consult.md Step 8 references Step 5 template (finding #22).
awk '/^### Step 8 /{f=1; next} /^### Step 9 /{f=0} f' "$CONSULT_MD" | grep -qE 'Step 5' \
  || { echo "FAIL: Step 8 body missing reference to Step 5 wait-template" >&2; exit 1; }
pass "Step 8 wait-block dedupes against Step 5 template"

# 8. canonical N-aware examples present in ## Steps preamble (finding #23).
awk '/^## Steps/{f=1; next} /^### Step 0 /{f=0} f' "$CONSULT_MD" | grep -qE 'Canonical N-aware examples' \
  || { echo "FAIL: '## Steps' preamble missing 'Canonical N-aware examples' subsection" >&2; exit 1; }
pass "canonical N-aware examples factored into ## Steps preamble"

# 9. plugin version present + semver-shape (v0.20.5: loosened from exact
# 0.20.4 lock per the v0.20.2 lesson — survives subsequent bumps).
PJ="$PLUGIN_ROOT/.claude-plugin/plugin.json"
grep -qE '"version": "0\.[0-9]+\.[0-9]+"' "$PJ" \
  || { echo "FAIL: plugin.json missing semver-shape version field" >&2; exit 1; }
pass "plugin.json version field present + semver-shaped"

pass "v0.20.4 static wiring complete (9 invariants locked)"
