#!/usr/bin/env bash
# v0.36.0 — cw_run_dir + cw_run_dir_last helpers
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# v0.31.0+: cw_state_root prefers $CLONE_WARS_HOME when set, else $PWD/.clone-wars.
# Unset the env var here so we exercise the project-local code path that
# v0.36.0 actually fixes (parallel-session isolation via per-project paths).
unset CLONE_WARS_HOME
cd "$TMP"

source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"

ROOT_DOT_CW="$TMP/.clone-wars"
RUN_ROOT="$ROOT_DOT_CW/_run"

# Case 1: cw_run_dir returns a fresh dir each call (mktemp uniqueness)
d1=$(cw_run_dir consult)
d2=$(cw_run_dir consult)
[[ -d "$d1" && -d "$d2" && "$d1" != "$d2" ]] \
  || { echo "FAIL: case 1 expected two distinct dirs, got d1=$d1 d2=$d2"; exit 1; }
[[ "$d1" == "$RUN_ROOT/consult."* ]] \
  || { echo "FAIL: case 1 d1 not under $RUN_ROOT/consult.*: $d1"; exit 1; }
pass "1. cw_run_dir mktemps a unique dir per call under \$state_root/_run/"

# Case 2: stale dirs swept; fresh ones preserved
stale="$RUN_ROOT/consult.STALE1"
fresh="$RUN_ROOT/consult.FRESH1"
mkdir -p "$stale" "$fresh"
touch -d "@$(($(date +%s) - 100000))" "$stale"   # 100k seconds = >24h old
touch "$fresh"
cw_run_dir consult >/dev/null   # triggers sweep
[[ ! -d "$stale" ]] || { echo "FAIL: case 2 stale dir not swept: $stale"; exit 1; }
[[ -d "$fresh"  ]] || { echo "FAIL: case 2 fresh dir wrongly swept: $fresh"; exit 1; }
pass "2. stale (>24h) dirs swept; fresh dirs preserved"

# Case 3: _run/.gitignore auto-created with '*'
rm -rf "$RUN_ROOT"
cw_run_dir consult >/dev/null
[[ -f "$RUN_ROOT/.gitignore" ]] \
  || { echo "FAIL: case 3 .gitignore not created"; exit 1; }
grep -qE '^\*$' "$RUN_ROOT/.gitignore" \
  || { echo "FAIL: case 3 .gitignore missing '*' line"; cat "$RUN_ROOT/.gitignore"; exit 1; }
pass "3. _run/.gitignore auto-created with '*'"

# Case 4: cw_run_dir_last reads the most-recent dir; errors when .last missing
d=$(cw_run_dir consult)
last=$(cw_run_dir_last)
assert_eq "$last" "$d" "case 4: cw_run_dir_last returns the path cw_run_dir just wrote"
rm -f "$RUN_ROOT/.last"
rc=0
cw_run_dir_last 2>/dev/null || rc=$?
[[ "$rc" != 0 ]] || { echo "FAIL: case 4 cw_run_dir_last should error when .last missing"; exit 1; }
pass "4. cw_run_dir_last reads .last; errors when missing"

echo "test_run_dir_helper: 4 cases passed"
