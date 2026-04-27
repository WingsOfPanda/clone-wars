#!/usr/bin/env bash
# tests/test_commanders.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/state.sh
source ../lib/commanders.sh

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"
mkdir -p "$CLONE_WARS_HOME/state/$(cw_repo_hash)"

# 1. cw_commanders_path uses the user override if present, else falls back
#    to the shipped default at $PLUGIN_ROOT/config/commanders.yaml.
export PLUGIN_ROOT="$(cd .. && pwd)"
PATH_OUT=$(cw_commanders_path)
[[ "$PATH_OUT" == "$PLUGIN_ROOT/config/commanders.yaml" ]] || {
  echo "FAIL: commanders_path didn't fall back to plugin default; got '$PATH_OUT'" >&2; exit 1; }
pass "commanders_path falls back to plugin default"

# 2. User override takes precedence.
mkdir -p "$CLONE_WARS_HOME"
cat > "$CLONE_WARS_HOME/commanders.yaml" <<'YAML'
commanders:
  - alpha
  - beta
YAML
PATH_OUT=$(cw_commanders_path)
assert_eq "$PATH_OUT" "$CLONE_WARS_HOME/commanders.yaml" "user-owned commanders.yaml wins"
pass "user override takes precedence"

# 3. cw_commanders_pool parses the user-owned list, skipping comments + empties.
cat > "$CLONE_WARS_HOME/commanders.yaml" <<'YAML'
# This is a comment
commanders:
  - alpha
  # nested comment
  - beta

  - gamma
YAML
mapfile -t POOL < <(cw_commanders_pool)
assert_eq "${#POOL[@]}" "3" "pool has 3 entries"
assert_eq "${POOL[0]}" "alpha" "first entry"
assert_eq "${POOL[1]}" "beta"  "second entry"
assert_eq "${POOL[2]}" "gamma" "third entry"
pass "pool parsing skips comments and empties"

# Need lib/ipc.sh for cw_pane_meta_write (so test state dirs have valid pane.json
# that the new lib/commanders.sh code path will read).
source ../lib/ipc.sh

# 4. cw_commander_in_use returns 0 iff the commander has a state dir under topic.
TOPIC_DIR="$CLONE_WARS_HOME/state/$(cw_repo_hash)/demo"
mkdir -p "$TOPIC_DIR/alpha-codex"
cw_pane_meta_write alpha codex demo '%101'
cw_commander_in_use alpha demo && pass "alpha is in use on demo" \
  || { echo "FAIL: alpha should be in use on demo" >&2; exit 1; }
cw_commander_in_use beta demo  && { echo "FAIL: beta should NOT be in use on demo" >&2; exit 1; } \
  || pass "beta is NOT in use on demo"

# 4b. HYPHENATED-MODEL REGRESSION (Codex review finding): a deployment with
#     a hyphenated model key like 'claude-haiku' must be detected via its
#     pane.json's "commander" field, NOT via name-parsing the dir. The pre-fix
#     last-hyphen strip would misread alpha-claude-haiku as commander='alpha-claude'
#     and silently let `alpha` be re-spawned.
HYPHEN_DIR="$CLONE_WARS_HOME/state/$(cw_repo_hash)/hyphen-topic"
mkdir -p "$HYPHEN_DIR/alpha-claude-haiku"
cw_pane_meta_write alpha claude-haiku hyphen-topic '%102'
cw_commander_in_use alpha hyphen-topic \
  && pass "alpha detected as in-use on hyphen-topic (via pane.json)" \
  || { echo "FAIL: alpha (deployed as alpha-claude-haiku) not detected as in-use" >&2
       echo "       last-hyphen strip would misread it as 'alpha-claude'" >&2
       exit 1; }

# 5. cw_commanders_in_use_globally lists deployed commanders across topics
#    AND correctly resolves hyphenated-model dirs to the right commander.
mkdir -p "$CLONE_WARS_HOME/state/$(cw_repo_hash)/other-topic/beta-claude"
cw_pane_meta_write beta claude other-topic '%103'
mapfile -t GLOBAL < <(cw_commanders_in_use_globally | sort)
[[ " ${GLOBAL[*]} " == *' alpha '* ]] || {
  echo "FAIL: globally-deployed alpha missing from list: '${GLOBAL[*]}'" >&2; exit 1; }
[[ " ${GLOBAL[*]} " == *' beta '* ]] || {
  echo "FAIL: globally-deployed beta missing from list: '${GLOBAL[*]}'" >&2; exit 1; }
# Crucially: alpha (deployed as alpha-claude-haiku in test 4b) must show
# up as 'alpha', not as 'alpha-claude' — proving the parser uses pane.json
# instead of last-hyphen strip across the global enumeration too.
[[ " ${GLOBAL[*]} " != *' alpha-claude '* ]] || {
  echo "FAIL: hyphenated-model leakage: 'alpha-claude' appeared instead of 'alpha'" >&2
  echo "       global list was: '${GLOBAL[*]}'" >&2; exit 1; }
pass "in_use_globally correctly resolves hyphenated-model dirs"

# 6. cw_commander_pick_random excludes globally-used names first.
#    Pool: alpha, beta, gamma. Used globally: alpha, beta. Pick should be gamma.
PICK=$(cw_commander_pick_random new-topic)
assert_eq "$PICK" "gamma" "pick prefers globally-unused names"
pass "pick_random excludes globally-used names (first pass)"

# 7. When every pool name is globally used, fall back to topic-unused.
mkdir -p "$CLONE_WARS_HOME/state/$(cw_repo_hash)/saturated/gamma-codex"
cw_pane_meta_write gamma codex saturated '%104'
# Now alpha+beta+gamma are all globally used. New topic 'fresh-topic' has
# none of them in-use locally, so pick should still succeed (fallback).
PICK2=$(cw_commander_pick_random fresh-topic)
[[ -n "$PICK2" ]] || { echo "FAIL: pick returned empty when fallback should succeed" >&2; exit 1; }
[[ "$PICK2" == "alpha" || "$PICK2" == "beta" || "$PICK2" == "gamma" ]] \
  || { echo "FAIL: pick returned unexpected name '$PICK2'" >&2; exit 1; }
pass "pick_random falls back to topic-unused when all pool is globally used"

# 8. When pool is empty / all in-use within the target topic, pick returns 1.
#    Saturate 'overcrowded' with all three pool members.
for c in alpha beta gamma; do
  mkdir -p "$CLONE_WARS_HOME/state/$(cw_repo_hash)/overcrowded/${c}-codex"
  cw_pane_meta_write "$c" codex overcrowded "%${c:0:1}99"
done
PICK3=$(cw_commander_pick_random overcrowded 2>/dev/null) && CODE=0 || CODE=$?
assert_eq "$CODE" "1" "pick returns rc=1 when topic saturated"
pass "pick_random fails closed when no pool name is available"

echo "  ALL: ok"
