#!/usr/bin/env bash
# tests/test_consult_emit_soft_dag.sh
#
# cw_consult_emit_soft_dag formats a numbered prose DAG from TSV input.
# Each row: <step>\t<repo>\t<description>\t<deps-csv|none>
# Output:    "<step>. <repo> Part X — <description>" + "(depends on N)" if any.
# Soft format — human-readable, copy-pastable into strict grammar by hand.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

source ../lib/consult-walk.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
TSV="$TMP/dag.tsv"

# Single step, no deps.
cat > "$TSV" <<EOF
1	ARS-TaskServe	add registry.yaml field	none
EOF
got=$(cw_consult_emit_soft_dag "$TSV")
expected="1. ARS-TaskServe — add registry.yaml field"
[[ "$got" == "$expected" ]] || { echo "FAIL single-no-deps: got=[$got] expected=[$expected]" >&2; exit 1; }

# Three interleaved steps with chain deps.
cat > "$TSV" <<EOF
1	ARS-TaskServe	add registry.yaml field	none
2	ARS-LVMGateway	consume new field in dispatcher	1
3	ARS-TaskServe	switch dispatcher callers to new field	2
EOF
got=$(cw_consult_emit_soft_dag "$TSV")
expected=$(cat <<EOF
1. ARS-TaskServe — add registry.yaml field
2. ARS-LVMGateway — consume new field in dispatcher (depends on 1)
3. ARS-TaskServe — switch dispatcher callers to new field (depends on 2)
EOF
)
[[ "$got" == "$expected" ]] || { echo "FAIL chain: got=[$got] expected=[$expected]" >&2; exit 1; }

# Multi-dep step.
cat > "$TSV" <<EOF
1	repo-a	produce A	none
2	repo-b	produce B	none
3	repo-c	consume A and B	1,2
EOF
got=$(cw_consult_emit_soft_dag "$TSV")
assert_contains "$got" "3. repo-c — consume A and B (depends on 1, 2)" "multi-dep formatted with comma+space"

# Empty file → empty output, rc=0.
: > "$TSV"
got=$(cw_consult_emit_soft_dag "$TSV")
[[ -z "$got" ]] || { echo "FAIL empty TSV: got=[$got]" >&2; exit 1; }

# Missing arg → rc=2.
cw_consult_emit_soft_dag >/dev/null 2>&1 && { echo "FAIL: empty arg should error" >&2; exit 1; } || rc=$?
[[ "$rc" -eq 2 ]] || { echo "FAIL: empty arg rc=$rc (expected 2)" >&2; exit 1; }

# Missing file → rc=1.
cw_consult_emit_soft_dag "$TMP/nonexistent.tsv" >/dev/null 2>&1 && { echo "FAIL: nonexistent file" >&2; exit 1; } || rc=$?
[[ "$rc" -eq 1 ]] || { echo "FAIL: nonexistent rc=$rc (expected 1)" >&2; exit 1; }

pass "cw_consult_emit_soft_dag formats numbered prose with comma-list deps"
