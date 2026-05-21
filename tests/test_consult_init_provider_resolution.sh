#!/usr/bin/env bash
# tests/test_consult_init_provider_resolution.sh
# bin/consult-init.sh roster resolution. Covers two surfaces:
# A. providers-available.txt gating (medic-detected): missing remark, N=1
#    rejected, N=2/N=3 accepted, gemini filtered.
# B. providers-active.txt preference (user-selected): falls back to available
#    when active absent, prefers active subset, drops stale entries.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
REPO_HASH=$(bash -c "source '$PLUGIN_ROOT/lib/state.sh' && cw_repo_hash")
INIT="$PLUGIN_ROOT/bin/consult-init.sh"

stage_available() {
  local cw_dir="$1"; shift
  mkdir -p "$cw_dir"
  {
    echo "# fixture"
    for p in "$@"; do echo "$p"; done
  } > "$cw_dir/providers-available.txt"
}

stage_active() {
  local cw_dir="$1"; shift
  {
    echo "# user selected"
    for p in "$@"; do echo "$p"; done
  } > "$cw_dir/providers-active.txt"
}

troopers_path() {
  find "$1/state/$REPO_HASH" -type f -name 'troopers.txt' | head -n1
}

# --- A. providers-available.txt gating ---

# A.1 missing remark → rc=2 with medic-redirect
mkdir -p "$TMP/a1/cw"
out=$(CLONE_WARS_HOME="$TMP/a1/cw" bash "$INIT" "test topic" 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "2" "missing remark -> rc=2"
assert_contains "$out" "run /clone-wars:medic" "stderr mentions medic"
pass "A.1 missing remark -> exit 2"

# A.2 N=1 (only claude) → rc=1 with redirect
stage_available "$TMP/a2/cw" claude
out=$(CLONE_WARS_HOME="$TMP/a2/cw" bash "$INIT" "test topic" 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "N=1 -> rc=1"
assert_contains "$out" "ask claude directly" "stderr suggests direct ask"
pass "A.2 N=1 -> exit 1 with redirect"

# A.3 N=2 (claude+codex) → cody, rex (input order)
stage_available "$TMP/a3/cw" claude codex
CLONE_WARS_HOME="$TMP/a3/cw" bash "$INIT" "test topic" >/dev/null 2>&1
TROOPERS=$(troopers_path "$TMP/a3/cw")
[[ -f "$TROOPERS" ]] || { echo "FAIL: A.3 troopers.txt not written"; exit 1; }
mapfile -t lines < <(grep -vE '^[[:space:]]*(#|$)' "$TROOPERS")
assert_eq "${#lines[@]}" "2" "A.3 N=2 -> 2 lines"
assert_contains "${lines[0]}" $'claude\tcody' "A.3 first line claude->cody"
assert_contains "${lines[1]}" $'codex\trex'   "A.3 second line codex->rex"
pass "A.3 N=2 (claude+codex) -> cody + rex"

# A.4 N=2 (claude+opencode) → cody + wolffe
stage_available "$TMP/a4/cw" claude opencode
CLONE_WARS_HOME="$TMP/a4/cw" bash "$INIT" "test topic" >/dev/null 2>&1
TROOPERS=$(troopers_path "$TMP/a4/cw")
mapfile -t lines < <(grep -vE '^[[:space:]]*(#|$)' "$TROOPERS")
assert_eq "${#lines[@]}" "2" "A.4 N=2 (claude+opencode) -> 2 lines"
assert_contains "${lines[0]}" $'claude\tcody'     "A.4 first line claude->cody"
assert_contains "${lines[1]}" $'opencode\twolffe' "A.4 second line opencode->wolffe"
pass "A.4 N=2 (claude+opencode) -> cody + wolffe"

# A.5 N=3 (all three) → 3 lines in input order
stage_available "$TMP/a5/cw" claude codex opencode
CLONE_WARS_HOME="$TMP/a5/cw" bash "$INIT" "test topic" >/dev/null 2>&1
TROOPERS=$(troopers_path "$TMP/a5/cw")
mapfile -t lines < <(grep -vE '^[[:space:]]*(#|$)' "$TROOPERS")
assert_eq "${#lines[@]}" "3" "A.5 N=3 -> 3 lines"
assert_contains "${lines[0]}" $'claude\tcody'
assert_contains "${lines[1]}" $'codex\trex'
assert_contains "${lines[2]}" $'opencode\twolffe'
pass "A.5 N=3 -> cody + rex + wolffe"

# A.6 gemini in remark → filtered out (N=4 → N=3)
stage_available "$TMP/a6/cw" gemini claude codex opencode
CLONE_WARS_HOME="$TMP/a6/cw" bash "$INIT" "test topic" >/dev/null 2>&1
TROOPERS=$(troopers_path "$TMP/a6/cw")
mapfile -t lines < <(grep -vE '^[[:space:]]*(#|$)' "$TROOPERS")
assert_eq "${#lines[@]}" "3" "A.6 N=4 with gemini -> 3 lines (gemini filtered)"
if grep -qE '^gemini' "$TROOPERS"; then
  echo "FAIL: gemini should be filtered out of troopers.txt"
  cat "$TROOPERS"
  exit 1
fi
pass "A.6 gemini filtered (N=4 -> N=3)"

# --- B. providers-active.txt preference ---

# B.1 falls back to providers-available when active.txt absent (v0.18.0 regression guard).
stage_available "$TMP/b1/cw" codex claude
out_topic=$(CLONE_WARS_HOME="$TMP/b1/cw" bash "$INIT" "v018 fallback regression")
TD="$TMP/b1/cw/state/$REPO_HASH/$out_topic"
assert_file_exists "$TD/_consult/troopers.txt" "B.1 troopers.txt written"
TROOPERS_BODY=$(grep -vE '^[[:space:]]*(#|$)' "$TD/_consult/troopers.txt")
assert_eq "$(echo "$TROOPERS_BODY" | wc -l)" "2" "B.1 all detected providers form roster"
echo "$TROOPERS_BODY" | grep -qE $'^codex\t'  || { echo "FAIL: B.1 codex row missing"  >&2; exit 1; }
echo "$TROOPERS_BODY" | grep -qE $'^claude\t' || { echo "FAIL: B.1 claude row missing" >&2; exit 1; }
[[ ! -f "$TMP/b1/cw/providers-active.txt" ]] \
  || { echo "FAIL: B.1 providers-active.txt should not be auto-created" >&2; exit 1; }
pass "B.1 fallback to providers-available when active absent"

# B.2 prefers providers-active.txt subset over providers-available.txt.
stage_available "$TMP/b2/cw" codex claude opencode
stage_active "$TMP/b2/cw" codex claude
out_topic=$(CLONE_WARS_HOME="$TMP/b2/cw" bash "$INIT" "v018 active subset wins")
TD="$TMP/b2/cw/state/$REPO_HASH/$out_topic"
TROOPERS_BODY=$(grep -vE '^[[:space:]]*(#|$)' "$TD/_consult/troopers.txt")
assert_eq "$(echo "$TROOPERS_BODY" | wc -l)" "2" "B.2 active subset produces N=2 roster"
echo "$TROOPERS_BODY" | grep -qE $'^codex\t'    || { echo "FAIL: B.2 codex row missing"     >&2; exit 1; }
echo "$TROOPERS_BODY" | grep -qE $'^claude\t'   || { echo "FAIL: B.2 claude row missing"    >&2; exit 1; }
echo "$TROOPERS_BODY" | grep -qE $'^opencode\t' && { echo "FAIL: B.2 opencode should not be in roster" >&2; exit 1; } || true
pass "B.2 prefers providers-active.txt over providers-available.txt"

# B.3 filters stale entries from providers-active.txt (gemini dropped).
stage_available "$TMP/b3/cw" codex claude
stage_active "$TMP/b3/cw" codex claude gemini
out_topic=$(CLONE_WARS_HOME="$TMP/b3/cw" bash "$INIT" "v018 stale entry filter")
TD="$TMP/b3/cw/state/$REPO_HASH/$out_topic"
TROOPERS_BODY=$(grep -vE '^[[:space:]]*(#|$)' "$TD/_consult/troopers.txt")
assert_eq "$(echo "$TROOPERS_BODY" | wc -l)" "2" "B.3 stale entry filtered, 2 valid providers remain"
echo "$TROOPERS_BODY" | grep -qE $'^codex\t'  || { echo "FAIL: B.3 codex row missing"  >&2; exit 1; }
echo "$TROOPERS_BODY" | grep -qE $'^claude\t' || { echo "FAIL: B.3 claude row missing" >&2; exit 1; }
echo "$TROOPERS_BODY" | grep -qE $'^gemini\t' && { echo "FAIL: B.3 gemini should be filtered" >&2; exit 1; } || true
pass "B.3 filters stale entries from providers-active.txt"

echo "test_consult_init_provider_resolution: 9 cases passed"
