#!/usr/bin/env bash
# tests/test_v0_25_0_static_wiring.sh — v0.25.0 invariant lock for /clone-wars:meditate.
#
# Locks 11 invariants:
#   1. commands/meditate.md exists with frontmatter (description + allowed-tools)
#   2. 7 new bin/meditate-*.sh files exist + executable
#   3. lib/meditate.sh exposes the 3 required functions
#   4. 3 prompt templates exist under config/prompt-templates/meditate/
#   5. lib/consult-wait.sh cw_consult_wait case statement includes 'adversary'
#   6. lib/contracts.sh cw_consult_timeout case statement includes 'adversary'
#   7. lib/consult.sh cw_consult_art_dir is prefix-aware (handles meditate-)
#   8. commands/meditate.md references the 5 confidence-gate signals S1..S5
#   9. adversary prompt template contains literal "break confidence" phrasing
#  10. commands/meditate.md does NOT contain literal "## Recommendation"
#      (anti-regression — meditate is not consult)
#  11. plugin.json semver-shape at 0.25.x

set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"

# 1. commands/meditate.md exists with frontmatter
[[ -f "$PLUGIN_ROOT/commands/meditate.md" ]] \
  || { echo "FAIL: commands/meditate.md missing" >&2; exit 1; }
grep -q '^description:' "$PLUGIN_ROOT/commands/meditate.md" \
  || { echo "FAIL: commands/meditate.md missing description: frontmatter" >&2; exit 1; }
grep -q '^allowed-tools:' "$PLUGIN_ROOT/commands/meditate.md" \
  || { echo "FAIL: commands/meditate.md missing allowed-tools: frontmatter" >&2; exit 1; }
pass "commands/meditate.md exists with description + allowed-tools frontmatter"

# 2. 7 bin scripts
for s in meditate-init meditate-research-send meditate-synth-preliminary \
         meditate-adversary-send meditate-synth-final meditate-teardown \
         meditate-adversary-wait; do
  [[ -x "$PLUGIN_ROOT/bin/$s.sh" ]] \
    || { echo "FAIL: bin/$s.sh missing or not executable" >&2; exit 1; }
done
pass "all 7 bin/meditate-*.sh scripts present + executable"

# 3. lib/meditate.sh + 3 public functions
[[ -f "$PLUGIN_ROOT/lib/meditate.sh" ]] \
  || { echo "FAIL: lib/meditate.sh missing" >&2; exit 1; }
for fn in cw_meditate_art_dir cw_meditate_classify_topic cw_meditate_parse_lit_flag; do
  grep -qE "^${fn}\(\)" "$PLUGIN_ROOT/lib/meditate.sh" \
    || { echo "FAIL: $fn missing in lib/meditate.sh" >&2; exit 1; }
done
pass "lib/meditate.sh exposes 3 required functions"

# 4. 3 prompt templates
for tpl in research.md adversary.md landscape-skeleton.md; do
  [[ -f "$PLUGIN_ROOT/config/prompt-templates/meditate/$tpl" ]] \
    || { echo "FAIL: prompt template missing: $tpl" >&2; exit 1; }
done
pass "3 meditate prompt templates present"

# 5. cw_consult_wait case includes 'adversary'
grep -qE '^[[:space:]]+adversary\)' "$PLUGIN_ROOT/lib/consult-wait.sh" \
  || { echo "FAIL: lib/consult-wait.sh has no 'adversary)' case" >&2; exit 1; }
pass "lib/consult-wait.sh case statement includes 'adversary'"

# 6. cw_consult_timeout case includes 'adversary'
grep -qE '^[[:space:]]+adversary\)' "$PLUGIN_ROOT/lib/contracts.sh" \
  || { echo "FAIL: lib/contracts.sh has no 'adversary)' case" >&2; exit 1; }
pass "lib/contracts.sh cw_consult_timeout case includes 'adversary'"

# 7. cw_consult_art_dir is prefix-aware
grep -q 'meditate-\*' "$PLUGIN_ROOT/lib/consult.sh" \
  || { echo "FAIL: lib/consult.sh cw_consult_art_dir not prefix-aware (no 'meditate-*' pattern)" >&2; exit 1; }
pass "cw_consult_art_dir is prefix-aware (handles meditate-)"

# 8. commands/meditate.md references S1..S5
for sig in S1 S2 S3 S4 S5; do
  grep -qE "\b$sig\b" "$PLUGIN_ROOT/commands/meditate.md" \
    || { echo "FAIL: commands/meditate.md missing signal reference: $sig" >&2; exit 1; }
done
pass "commands/meditate.md references all 5 confidence-gate signals"

# 9. adversary prompt has "break confidence" literal
grep -qF 'break confidence' "$PLUGIN_ROOT/config/prompt-templates/meditate/adversary.md" \
  || { echo "FAIL: adversary.md missing 'break confidence' phrasing" >&2; exit 1; }
pass "adversary.md contains 'break confidence' phrasing"

# 10. commands/meditate.md has no "## Recommendation" (anti-regression)
if grep -qE '^## Recommendation' "$PLUGIN_ROOT/commands/meditate.md"; then
  echo "FAIL: commands/meditate.md has '## Recommendation' header (should be ## Conclusion)" >&2
  exit 1
fi
pass "commands/meditate.md has no '## Recommendation' header"

# 11. plugin.json semver-shape (loosened per v0.20.2 lesson)
PJ="$PLUGIN_ROOT/.claude-plugin/plugin.json"
grep -qE '"version": "[0-9]+\.[0-9]+\.[0-9]+"' "$PJ" \
  || { echo "FAIL: plugin.json version field not semver-shape" >&2; exit 1; }
pass "plugin.json version field present + semver-shape"

pass "v0.25.0 static wiring complete (11 invariants locked)"
