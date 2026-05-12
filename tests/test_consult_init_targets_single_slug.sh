#!/usr/bin/env bash
# tests/test_consult_init_targets_single_slug.sh
#
# bin/consult-init.sh --targets <one-slug> <topic>
# When --targets provides exactly 1 slug (the "I'm in a hub and the topic
# only affects one sub-repo" case), multi-repo.txt must be "single-sub"
# (not "multi"). This drives bin/consult-walk-assemble.sh to emit the
# singular **Target Sub-Project:** header that /clone-wars:deploy parses
# via cw_deploy_extract_target (v0.10.0).
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

mkdir -p "$CLONE_WARS_HOME"
cat > "$CLONE_WARS_HOME/providers-available.txt" <<EOF
codex
claude
EOF

# Fake hub with two sibling sub-repos, but the topic only targets one.
mkdir -p "$TMP/hub/arsperfusion" "$TMP/hub/ars-gateway"
touch "$TMP/hub/arsperfusion/CLAUDE.md" "$TMP/hub/ars-gateway/CLAUDE.md"

INIT="$(cd .. && pwd)/bin/consult-init.sh"
LIB="$(cd .. && pwd)/lib/state.sh"

cd "$TMP/hub"
RH=$(bash -c "source '$LIB'; cw_repo_hash")

# --- 1 slug → multi-repo.txt = single-sub ---
TOPIC_OUT=$("$INIT" --targets arsperfusion "halftime preselect")
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC_OUT"
assert_file_exists "$TD/_consult/targets.txt"     "targets.txt written"
assert_file_exists "$TD/_consult/multi-repo.txt"  "multi-repo.txt written"
mode=$(cat "$TD/_consult/multi-repo.txt")
[[ "$mode" == "single-sub" ]] \
  || { echo "FAIL: 1-slug should produce single-sub; got [$mode]" >&2; exit 1; }
# targets.txt has 1 data row (plus comment line).
data_rows=$(grep -cv '^#' "$TD/_consult/targets.txt")
[[ "$data_rows" == "1" ]] \
  || { echo "FAIL: targets.txt should have 1 data row; got $data_rows" >&2; exit 1; }
TAB=$(printf '\t')
grep -qE "^arsperfusion${TAB}.*arsperfusion/CLAUDE\.md$" "$TD/_consult/targets.txt" \
  || { echo "FAIL: arsperfusion row missing or wrong path" >&2; cat "$TD/_consult/targets.txt" >&2; exit 1; }
pass "1-slug --targets writes multi-repo.txt = single-sub"

# --- 2 slugs → multi-repo.txt = multi (regression guard) ---
TOPIC_OUT2=$("$INIT" --targets arsperfusion,ars-gateway "session storage migration")
TD2="$CLONE_WARS_HOME/state/$RH/$TOPIC_OUT2"
mode2=$(cat "$TD2/_consult/multi-repo.txt")
[[ "$mode2" == "multi" ]] \
  || { echo "FAIL: 2-slug should produce multi; got [$mode2]" >&2; exit 1; }
pass "2-slug --targets still produces multi-repo.txt = multi (regression guard)"
