#!/usr/bin/env bash
# tests/test_deploy_dag_parse.sh
# E2E test for bin/deploy-dag-parse.sh — happy paths + failure modes.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

# Test A: 3-repo linear DAG
DOC1="$SANDBOX/doc1.md"
OUT1="$SANDBOX/out1"; mkdir -p "$OUT1"
cat > "$DOC1" <<'EOF'
# Test Doc

## Execution DAG

1. auth — set up auth schema
2. api — depends on auth (depends on 1)
3. ui — frontend wiring (depends on 2)

## Other Section
EOF
"$PLUGIN_ROOT/bin/deploy-dag-parse.sh" "$DOC1" "$OUT1" || { echo "FAIL: linear DAG parse rc!=0" >&2; exit 1; }
assert_file_exists "$OUT1/dag-waves.txt" "linear: dag-waves.txt written"
assert_file_exists "$OUT1/dag-edges.txt" "linear: dag-edges.txt written"
mapfile -t WAVES < "$OUT1/dag-waves.txt"
[[ ${#WAVES[@]} -eq 3 ]] || { echo "FAIL: linear should have 3 wave lines (got ${#WAVES[@]})" >&2; exit 1; }
# v0.21.0: 5-field TSV (path column inserted between repo and desc; sentinel 'none' when absent)
assert_eq "${WAVES[0]}" $'1\t1\tauth\tnone\tset up auth schema' "linear wave 1"
assert_eq "${WAVES[1]}" $'2\t2\tapi\tnone\tdepends on auth' "linear wave 2"
assert_eq "${WAVES[2]}" $'3\t3\tui\tnone\tfrontend wiring' "linear wave 3"
pass "deploy-dag-parse linear DAG"

# Test B: diamond DAG
DOC2="$SANDBOX/doc2.md"
OUT2="$SANDBOX/out2"; mkdir -p "$OUT2"
cat > "$DOC2" <<'EOF'
## Execution DAG

1. shared — define interfaces
2. left — implement left side (depends on 1)
3. right — implement right side (depends on 1)
4. join — wire both sides (depends on 2, 3)
EOF
"$PLUGIN_ROOT/bin/deploy-dag-parse.sh" "$DOC2" "$OUT2" || { echo "FAIL: diamond DAG parse rc!=0" >&2; exit 1; }
mapfile -t WAVES2 < "$OUT2/dag-waves.txt"
[[ ${#WAVES2[@]} -eq 4 ]] || { echo "FAIL: diamond should have 4 wave lines (got ${#WAVES2[@]})" >&2; exit 1; }
[[ "${WAVES2[0]}" == 1$'\t'1$'\t'shared* ]] || { echo "FAIL: diamond wave 1 not shared: ${WAVES2[0]}" >&2; exit 1; }
nwave2=$(awk -F$'\t' '$1==2' "$OUT2/dag-waves.txt" | wc -l)
[[ "$nwave2" -eq 2 ]] || { echo "FAIL: diamond wave 2 should have 2 nodes" >&2; exit 1; }
nwave3=$(awk -F$'\t' '$1==3' "$OUT2/dag-waves.txt" | wc -l)
[[ "$nwave3" -eq 1 ]] || { echo "FAIL: diamond wave 3 should have 1 node" >&2; exit 1; }
pass "deploy-dag-parse diamond DAG"

# Test C: missing DAG section → rc=1
DOC3="$SANDBOX/doc3.md"
OUT3="$SANDBOX/out3"; mkdir -p "$OUT3"
cat > "$DOC3" <<'EOF'
# No DAG here

Just regular content.
EOF
err=$("$PLUGIN_ROOT/bin/deploy-dag-parse.sh" "$DOC3" "$OUT3" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: missing DAG should rc!=0" >&2; exit 1; }
echo "$err" | grep -qi 'execution dag' || { echo "FAIL: error should mention DAG: $err" >&2; exit 1; }
pass "deploy-dag-parse rejects missing DAG section"

# Test D: cycle → rc=1
DOC4="$SANDBOX/doc4.md"
OUT4="$SANDBOX/out4"; mkdir -p "$OUT4"
cat > "$DOC4" <<'EOF'
## Execution DAG

1. a — first (depends on 2)
2. b — second (depends on 1)
EOF
err=$("$PLUGIN_ROOT/bin/deploy-dag-parse.sh" "$DOC4" "$OUT4" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: cycle should rc!=0" >&2; exit 1; }
echo "$err" | grep -qi 'cycle' || { echo "FAIL: cycle error unclear: $err" >&2; exit 1; }
pass "deploy-dag-parse rejects cycle"

# Test E: malformed DAG-shaped line → rc=1
# The parser is permissive about non-DAG content (e.g., intro prose like
# "The order is:") — it only ATTEMPTS to parse lines starting with digit+period.
# But once a line looks like a DAG entry, it must parse cleanly. Here the
# line "2. — missing repo" trips the digit-period prefix but fails the
# repo-slug regex (requires [a-z0-9-]+ before the em-dash).
DOC5="$SANDBOX/doc5.md"
OUT5="$SANDBOX/out5"; mkdir -p "$OUT5"
cat > "$DOC5" <<'EOF'
## Execution DAG

1. valid — first
2. — missing repo slug here
EOF
err=$("$PLUGIN_ROOT/bin/deploy-dag-parse.sh" "$DOC5" "$OUT5" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: malformed should rc!=0" >&2; exit 1; }
echo "$err" | grep -qi 'malformed' || { echo "FAIL: error should mention malformed: $err" >&2; exit 1; }
pass "deploy-dag-parse rejects DAG-shaped malformed line"

# Test F: permissive about non-DAG content (intro prose between header + entries)
DOC6="$SANDBOX/doc6.md"
OUT6="$SANDBOX/out6"; mkdir -p "$OUT6"
cat > "$DOC6" <<'EOF'
## Execution DAG

The recommended order:

1. shared — define interfaces
2. impl — build (depends on 1)

Note: keep wave 1 small.
EOF
"$PLUGIN_ROOT/bin/deploy-dag-parse.sh" "$DOC6" "$OUT6" || { echo "FAIL: intro prose should be tolerated" >&2; exit 1; }
mapfile -t WAVES6 < "$OUT6/dag-waves.txt"
[[ ${#WAVES6[@]} -eq 2 ]] || { echo "FAIL: expected 2 nodes (got ${#WAVES6[@]})" >&2; exit 1; }
pass "deploy-dag-parse tolerates intro/footer prose around DAG entries"
