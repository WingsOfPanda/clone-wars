#!/usr/bin/env bash
# tests/test_v0_27_0_static_wiring.sh — version-stamped invariant lock for v0.27.0.
# Never edit — adjust at v0.28.0 by creating a new static-wiring test.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

# Invariant 1: plugin.json version = 0.27.0
grep -qE '"version"[[:space:]]*:[[:space:]]*"0\.27\.0"' "$PLUGIN_ROOT/.claude-plugin/plugin.json" \
  || { echo "FAIL: plugin.json version != 0.27.0" >&2; exit 1; }
pass "1. plugin.json version 0.27.0"

# Invariant 2: marketplace.json has 2 v0.27.0 fields
count=$(grep -cE '"version"[[:space:]]*:[[:space:]]*"0\.27\.0"' "$PLUGIN_ROOT/.claude-plugin/marketplace.json")
[[ "$count" == "2" ]] \
  || { echo "FAIL: marketplace.json expected 2 v0.27.0 fields, got $count" >&2; exit 1; }
pass "2. marketplace.json has 2 v0.27.0 version fields"

# Invariant 3: 5 deep-research bin scripts present + executable
for s in deep-research-init deep-research-experiment-send deep-research-experiment-wait deep-research-score deep-research-teardown; do
  [[ -x "$PLUGIN_ROOT/bin/$s.sh" ]] \
    || { echo "FAIL: bin/$s.sh missing or not executable" >&2; exit 1; }
done
pass "3. 5 deep-research bin scripts present + executable"

# Invariant 4: lib/deep-research.sh sources cleanly + exposes v0.27.0 helpers
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/commanders.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"

for fn in \
  cw_deep_research_pick_roster \
  cw_deep_research_format_metric_block \
  cw_deep_research_check_stagnation \
  cw_deep_research_check_time_budget \
  cw_deep_research_extract_metric \
  cw_deep_research_extract_approaches \
  cw_deep_research_validate_result_json; do
  declare -F "$fn" >/dev/null \
    || { echo "FAIL: $fn not exposed from lib/deep-research.sh" >&2; exit 1; }
done
pass "4. lib/deep-research.sh exposes 7 v0.27.0 helpers"

# Invariant 5: removed v0.26.0 helpers MUST NOT be present
for fn in \
  cw_deep_research_compute_per_branch_timeout \
  cw_deep_research_allocate_commanders; do
  if declare -F "$fn" >/dev/null; then
    echo "FAIL: $fn should be removed in v0.27.0 but is still defined" >&2; exit 1
  fi
done
pass "5. removed v0.26.0 helpers not present"

# Invariant 6: experiment.md prompt template exists + BUG #3 fixed
TEMPLATE="$PLUGIN_ROOT/config/prompt-templates/deep-research/experiment.md"
[[ -f "$TEMPLATE" ]] || { echo "FAIL: experiment.md template missing" >&2; exit 1; }
if grep -q "cd into your branch dir" "$TEMPLATE"; then
  echo "FAIL: BUG #3 not fixed; 'cd into your branch dir' still present" >&2; exit 1
fi
grep -q "{{METRIC_BLOCK}}" "$TEMPLATE" \
  || { echo "FAIL: {{METRIC_BLOCK}} placeholder missing" >&2; exit 1; }
grep -q "{{EXP_ID}}" "$TEMPLATE" \
  || { echo "FAIL: {{EXP_ID}} placeholder missing" >&2; exit 1; }
if grep -q "{{ALLOW_NET}}" "$TEMPLATE"; then
  echo "FAIL: {{ALLOW_NET}} placeholder still present (should be hardcoded)" >&2; exit 1
fi
pass "6. prompt template: BUG #3 fix + METRIC_BLOCK + EXP_ID present, ALLOW_NET hardcoded"

# Invariant 7: directive frontmatter doesn't advertise removed flags
DIRECTIVE="$PLUGIN_ROOT/commands/deep-research.md"
[[ -f "$DIRECTIVE" ]] || { echo "FAIL: directive missing" >&2; exit 1; }
grep -qE '^argument-hint:' "$DIRECTIVE" \
  || { echo "FAIL: argument-hint frontmatter missing" >&2; exit 1; }
# Argument-hint line must NOT advertise the removed flags
arg_hint=$(grep '^argument-hint:' "$DIRECTIVE")
for removed_flag in "--max-rounds" "--branches-per-round" "--time-budget" "--cost-warning"; do
  if [[ "$arg_hint" == *"$removed_flag"* ]]; then
    echo "FAIL: argument-hint advertises removed flag: $removed_flag" >&2; exit 1
  fi
done
# --allow-net may appear in DANGER prose explaining v0.26 → v0.27 change, but
# must not appear in the argument-hint frontmatter line itself.
if [[ "$arg_hint" == *"--allow-net"* ]]; then
  echo "FAIL: argument-hint advertises removed --allow-net flag" >&2; exit 1
fi
pass "7. directive argument-hint free of removed flags"

# Invariant 8: directive references all 5 bin scripts
for s in deep-research-init deep-research-experiment-send deep-research-experiment-wait deep-research-score deep-research-teardown; do
  grep -q "$s.sh" "$DIRECTIVE" \
    || { echo "FAIL: directive doesn't reference $s.sh" >&2; exit 1; }
done
pass "8. directive references all 5 deep-research bin scripts"

# Invariant 9: cw_consult_art_dir routes deep-research-* → _deep-research/
got=$(cw_consult_art_dir "deep-research-foo")
[[ "$got" == */_deep-research ]] \
  || { echo "FAIL: art_dir routing wrong: $got" >&2; exit 1; }
pass "9. cw_consult_art_dir routes deep-research-* correctly"

# Invariant 10: cw_consult_topic_validate accepts deep-research-*
cw_consult_topic_validate "deep-research-foo" \
  || { echo "FAIL: topic_validate rejects deep-research-foo" >&2; exit 1; }
pass "10. cw_consult_topic_validate accepts deep-research-* prefix"

# Invariant 11: cw_consult_wait second case block includes experiment) (BUG #2 fix)
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/contracts.sh"
source "$PLUGIN_ROOT/lib/consult-wait.sh"
fn_body=$(declare -f cw_consult_wait)
# Count 'experiment)' occurrences — v0.26.0 had 1 (entry dispatch); v0.27.0
# adds a second occurrence in the done-event handler block.
exp_count=$(echo "$fn_body" | grep -cE 'experiment\)')
(( exp_count >= 2 )) \
  || { echo "FAIL: cw_consult_wait has only $exp_count 'experiment)' branches; expected ≥2 (BUG #2 fix)" >&2; exit 1; }
pass "11. cw_consult_wait second case block includes experiment) (BUG #2 fix)"

# Invariant 12: CLAUDE.md has v0.27.0 status row + release-gate row
grep -q "v0.27.0:" "$PLUGIN_ROOT/CLAUDE.md" \
  || { echo "FAIL: CLAUDE.md missing v0.27.0 status row" >&2; exit 1; }
grep -q "v0.27.0 strict-dogfood" "$PLUGIN_ROOT/CLAUDE.md" \
  || { echo "FAIL: CLAUDE.md missing v0.27.0 release-gate row" >&2; exit 1; }
pass "12. CLAUDE.md has v0.27.0 status + release-gate rows"

# Invariant 13: README has /clone-wars:deep-research row + DANGER block
grep -q "/clone-wars:deep-research" "$PLUGIN_ROOT/README.md" \
  || { echo "FAIL: README missing /clone-wars:deep-research command row" >&2; exit 1; }
grep -q "DANGER block — \`/clone-wars:deep-research\`" "$PLUGIN_ROOT/README.md" \
  || { echo "FAIL: README missing DANGER block heading" >&2; exit 1; }
pass "13. README has deep-research command row + DANGER block"

# Invariant 14: init refuses removed flags + accepts --seed-from
TMPHOME=$(mktemp -d); trap 'rm -rf "$TMPHOME"' EXIT
echo "codex" > "$TMPHOME/providers-available.txt"
if CLONE_WARS_HOME="$TMPHOME" "$PLUGIN_ROOT/bin/deep-research-init.sh" --max-rounds 3 "x" 2>/dev/null; then
  echo "FAIL: init accepted removed --max-rounds flag" >&2; exit 1
fi
seed_doc="$TMPHOME/seed.md"; echo "# fake" > "$seed_doc"
slug_seed=$(CLONE_WARS_HOME="$TMPHOME" "$PLUGIN_ROOT/bin/deep-research-init.sh" --seed-from "$seed_doc" "valid topic")
[[ -n "$slug_seed" ]] || { echo "FAIL: init rejected valid --seed-from invocation" >&2; exit 1; }
pass "14. init refuses removed --max-rounds; accepts --seed-from"

echo "test_v0_27_0_static_wiring: 14 invariants locked"
