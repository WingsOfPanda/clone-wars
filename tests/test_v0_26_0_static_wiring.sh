#!/usr/bin/env bash
# tests/test_v0_26_0_static_wiring.sh — version-stamped invariant lock for v0.26.0.
# Never edit — adjust at v0.27.0 by creating a new static-wiring test.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

# Invariant 1: plugin.json version = 0.26.0
grep -qE '"version"[[:space:]]*:[[:space:]]*"0\.26\.0"' "$PLUGIN_ROOT/.claude-plugin/plugin.json" \
  || { echo "FAIL: plugin.json version != 0.26.0" >&2; exit 1; }
pass "1. plugin.json version 0.26.0"

# Invariant 2: marketplace.json has 2 v0.26.0 fields
count=$(grep -cE '"version"[[:space:]]*:[[:space:]]*"0\.26\.0"' "$PLUGIN_ROOT/.claude-plugin/marketplace.json")
[[ "$count" == "2" ]] \
  || { echo "FAIL: marketplace.json expected 2 v0.26.0 fields, got $count" >&2; exit 1; }
pass "2. marketplace.json has 2 v0.26.0 version fields"

# Invariant 3: 5 new bin scripts present + executable
for s in deep-research-init deep-research-experiment-send deep-research-experiment-wait deep-research-score deep-research-teardown; do
  [[ -x "$PLUGIN_ROOT/bin/$s.sh" ]] \
    || { echo "FAIL: bin/$s.sh missing or not executable" >&2; exit 1; }
done
pass "3. 5 deep-research bin scripts present + executable"

# Invariant 4: lib/deep-research.sh sources cleanly + exposes expected functions
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/commanders.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"

for fn in \
  cw_deep_research_compute_per_branch_timeout \
  cw_deep_research_extract_metric \
  cw_deep_research_validate_result_json \
  cw_deep_research_extract_approaches \
  cw_deep_research_allocate_commanders; do
  declare -F "$fn" >/dev/null \
    || { echo "FAIL: $fn not exposed from lib/deep-research.sh" >&2; exit 1; }
done
pass "4. lib/deep-research.sh exposes 5 expected helpers"

# Invariant 5: experiment.md prompt template exists
[[ -f "$PLUGIN_ROOT/config/prompt-templates/deep-research/experiment.md" ]] \
  || { echo "FAIL: experiment.md template missing" >&2; exit 1; }
pass "5. config/prompt-templates/deep-research/experiment.md present"

# Invariant 6: commands/deep-research.md frontmatter argument-hint shape
grep -qE '^argument-hint:.*<topic-with-explicit-metric>' "$PLUGIN_ROOT/commands/deep-research.md" \
  || { echo "FAIL: argument-hint shape wrong" >&2; exit 1; }
pass "6. directive frontmatter has expected argument-hint"

# Invariant 7: directive references all 5 bin scripts
for s in deep-research-init deep-research-experiment-send deep-research-experiment-wait deep-research-score deep-research-teardown; do
  grep -q "$s.sh" "$PLUGIN_ROOT/commands/deep-research.md" \
    || { echo "FAIL: directive doesn't reference $s.sh" >&2; exit 1; }
done
pass "7. directive references all 5 deep-research bin scripts"

# Invariant 8: cw_consult_art_dir routes deep-research-* → _deep-research/
got=$(cw_consult_art_dir "deep-research-foo")
[[ "$got" == */_deep-research ]] \
  || { echo "FAIL: art_dir routing wrong: $got" >&2; exit 1; }
pass "8. cw_consult_art_dir routes deep-research-* correctly"

# Invariant 9: cw_consult_topic_validate accepts deep-research-*
cw_consult_topic_validate "deep-research-foo" \
  || { echo "FAIL: topic_validate rejects deep-research-foo" >&2; exit 1; }
pass "9. cw_consult_topic_validate accepts deep-research-* prefix"

# Invariant 10: cw_consult_wait knows experiment kind
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/contracts.sh"
source "$PLUGIN_ROOT/lib/consult-wait.sh"
declare -f cw_consult_wait | grep -q "experiment)" \
  || { echo "FAIL: cw_consult_wait missing experiment case" >&2; exit 1; }
pass "10. cw_consult_wait recognizes experiment kind"

# Invariant 11: CLAUDE.md has v0.26.0 status row + release-gate row
grep -q "v0.26.0:" "$PLUGIN_ROOT/CLAUDE.md" \
  || { echo "FAIL: CLAUDE.md missing v0.26.0 status row" >&2; exit 1; }
grep -q "v0.26.0 strict-dogfood" "$PLUGIN_ROOT/CLAUDE.md" \
  || { echo "FAIL: CLAUDE.md missing v0.26.0 release-gate row" >&2; exit 1; }
pass "11. CLAUDE.md has v0.26.0 status + release-gate rows"

# Invariant 12: README has /clone-wars:deep-research row + DANGER block
grep -q "/clone-wars:deep-research" "$PLUGIN_ROOT/README.md" \
  || { echo "FAIL: README missing /clone-wars:deep-research command row" >&2; exit 1; }
grep -q "DANGER block — \`/clone-wars:deep-research\`" "$PLUGIN_ROOT/README.md" \
  || { echo "FAIL: README missing DANGER block heading" >&2; exit 1; }
pass "12. README has deep-research command row + DANGER block"

# Invariant 13: cw_consult_timeout experiment default = 1800s
got=$(cw_consult_timeout experiment)
[[ "$got" == "1800" ]] \
  || { echo "FAIL: experiment timeout expected 1800, got $got" >&2; exit 1; }
pass "13. cw_consult_timeout experiment = 1800"

# Invariant 14: deep-research-init refuses when codex absent
TMPHOME=$(mktemp -d)
trap 'rm -rf "$TMPHOME"' EXIT
mkdir -p "$TMPHOME"
# No codex line — providers-available.txt has only claude
echo "claude" > "$TMPHOME/providers-available.txt"
if CLONE_WARS_HOME="$TMPHOME" "$PLUGIN_ROOT/bin/deep-research-init.sh" "test topic" 2>/dev/null; then
  echo "FAIL: init should refuse without codex" >&2; exit 1
fi
pass "14. deep-research-init.sh refuses without codex"

echo "test_v0_26_0_static_wiring: 14 invariants locked"
