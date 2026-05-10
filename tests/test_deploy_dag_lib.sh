#!/usr/bin/env bash
# tests/test_deploy_dag_lib.sh
# Unit tests for lib/deploy-dag.sh helpers.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/deploy-dag.sh"

# --- cw_deploy_dag_parse_line ---

# Simple line: no path, no deps (v0.21.0: 5-field TSV)
line="1. foo — initial setup"
result=$(cw_deploy_dag_parse_line "$line")
assert_eq "$result" $'1\tfoo\tnone\tinitial setup\tnone' "parse_line: simple"

# With single dep
line="2. bar — depends on foo (depends on 1)"
result=$(cw_deploy_dag_parse_line "$line")
assert_eq "$result" $'2\tbar\tnone\tdepends on foo\t1' "parse_line: single dep"

# With multiple deps
line="3. baz — bridge layer (depends on 1, 2)"
result=$(cw_deploy_dag_parse_line "$line")
assert_eq "$result" $'3\tbaz\tnone\tbridge layer\t1,2' "parse_line: multiple deps"

# Malformed: missing step number
err=$(cw_deploy_dag_parse_line "foo — bad" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: malformed line should rc!=0" >&2; exit 1; }
pass "parse_line: malformed rejects"

# --- cw_deploy_dag_topological ---

# Linear: 1 → 2 → 3
EDGES_TSV=$(mktemp)
WAVES_TSV=$(mktemp)
trap 'rm -f "$EDGES_TSV" "$WAVES_TSV"' EXIT
printf '1\t2\n2\t3\n' > "$EDGES_TSV"
cw_deploy_dag_topological "$EDGES_TSV" 1 2 3 > "$WAVES_TSV"
mapfile -t lines < "$WAVES_TSV"
assert_eq "${lines[0]}" $'1\t1' "topological linear: wave 1 = node 1"
assert_eq "${lines[1]}" $'2\t2' "topological linear: wave 2 = node 2"
assert_eq "${lines[2]}" $'3\t3' "topological linear: wave 3 = node 3"

# Parallel wave: 1, 2, 3 with no deps
: > "$EDGES_TSV"
cw_deploy_dag_topological "$EDGES_TSV" 1 2 3 > "$WAVES_TSV"
nwave1=$(awk -F$'\t' '$1==1' "$WAVES_TSV" | wc -l)
assert_eq "$nwave1" "3" "topological parallel: 3 nodes in wave 1"

# Cycle: 1 → 2 → 1
printf '1\t2\n2\t1\n' > "$EDGES_TSV"
err=$(cw_deploy_dag_topological "$EDGES_TSV" 1 2 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: cycle should rc!=0" >&2; exit 1; }
echo "$err" | grep -qi 'cycle' || { echo "FAIL: cycle error msg unclear: $err" >&2; exit 1; }
pass "topological: cycle detected"

# --- cw_deploy_dag_unique_repos ---

WAVES=$(mktemp)
printf '1\t1\tfoo\tdesc1\n1\t2\tbar\tdesc2\n2\t3\tfoo\tdesc3\n' > "$WAVES"
result=$(cw_deploy_dag_unique_repos "$WAVES" | sort)
expected=$'bar\nfoo'
assert_eq "$result" "$expected" "unique_repos: dedupes + sorts"
rm -f "$WAVES"

# --- cw_deploy_dag_fan_in_repos ---

EDGES=$(mktemp)
WAVES2=$(mktemp)
# diamond: 4 has 2 incoming (from 2, 3); should be flagged
# edges: 1→2, 1→3, 2→4, 3→4
printf '1\t2\n1\t3\n2\t4\n3\t4\n' > "$EDGES"
# waves: 1 in wave 1; 2,3 in wave 2; 4 in wave 3 (with repo "join")
printf '1\t1\troot\tx\n2\t2\tleft\tx\n2\t3\tright\tx\n3\t4\tjoin\tx\n' > "$WAVES2"
result=$(cw_deploy_dag_fan_in_repos "$EDGES" "$WAVES2")
assert_eq "$result" "join" "fan_in_repos: identifies join node (fan-in=2)"
rm -f "$EDGES" "$WAVES2"

pass "lib/deploy-dag.sh helpers all green"
