#!/usr/bin/env bash
# tests/test_consult_init_persists_hub_mode.sh
# Verifies that bin/consult-init.sh writes _consult/hub-mode.txt with the
# correct value for super-hub and single-repo conductor cwds.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/log.sh
source ../lib/state.sh
source ../lib/consult.sh

PLUGIN_ROOT=$(cd .. && pwd)

# Track everything we create so the EXIT trap nukes it all.
SUPER=$(mktemp -d -t cw-init-super.XXXXXX)
TMP_HOME=$(mktemp -d -t cw-init-hub.XXXXXX)
SINGLE=$(mktemp -d -t cw-init-single.XXXXXX)
TMP_HOME2=$(mktemp -d -t cw-init-home2.XXXXXX)
trap 'rm -rf "$SUPER" "$TMP_HOME" "$SINGLE" "$TMP_HOME2"' EXIT

# ------------------------------------------------------------------
# Super-hub fixture: 2-level git nesting (super-hub → hub_x → leaf{1,2}).
# ------------------------------------------------------------------
git init -q "$SUPER"
mkdir -p "$SUPER/hub_x/leaf1" "$SUPER/hub_x/leaf2"
git init -q "$SUPER/hub_x"
git init -q "$SUPER/hub_x/leaf1"
git init -q "$SUPER/hub_x/leaf2"

export CLONE_WARS_HOME="$TMP_HOME"

(
  cd "$SUPER" && \
  CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  "$PLUGIN_ROOT/bin/consult-init.sh" "test super-hub topic"
) > "$TMP_HOME/topic.out"
TOPIC=$(cat "$TMP_HOME/topic.out")
HASH=$( cd "$SUPER" && CLONE_WARS_HOME="$TMP_HOME" \
        bash -c 'source "'"$PLUGIN_ROOT"'/lib/log.sh"; source "'"$PLUGIN_ROOT"'/lib/state.sh"; cw_repo_hash' )
ART="$TMP_HOME/state/$HASH/$TOPIC/_consult"
[[ -f "$ART/hub-mode.txt" ]] || { echo "FAIL: hub-mode.txt missing at $ART"; exit 1; }
mode=$(tr -d '[:space:]' < "$ART/hub-mode.txt")
assert_eq "$mode" "super-hub" "super-hub fixture writes hub-mode.txt = super-hub"
pass "super-hub fixture → hub-mode.txt = super-hub"

# ------------------------------------------------------------------
# Single-repo fixture: plain git dir, no git children.
# ------------------------------------------------------------------
git init -q "$SINGLE"
export CLONE_WARS_HOME="$TMP_HOME2"

(
  cd "$SINGLE" && \
  CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  "$PLUGIN_ROOT/bin/consult-init.sh" "single-repo topic"
) > "$TMP_HOME2/topic.out"
TOPIC2=$(cat "$TMP_HOME2/topic.out")
HASH2=$( cd "$SINGLE" && CLONE_WARS_HOME="$TMP_HOME2" \
         bash -c 'source "'"$PLUGIN_ROOT"'/lib/log.sh"; source "'"$PLUGIN_ROOT"'/lib/state.sh"; cw_repo_hash' )
ART2="$TMP_HOME2/state/$HASH2/$TOPIC2/_consult"
[[ -f "$ART2/hub-mode.txt" ]] || { echo "FAIL: hub-mode.txt missing at $ART2"; exit 1; }
mode2=$(tr -d '[:space:]' < "$ART2/hub-mode.txt")
assert_eq "$mode2" "single-repo" "single-repo fixture writes hub-mode.txt = single-repo"
pass "single-repo fixture → hub-mode.txt = single-repo"
