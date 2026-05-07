#!/usr/bin/env bash
# tests/test_spec_resume_state.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/spec.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
DD="$TMP/dd"

# Missing dir — empty stdout, rc=0.
mapfile -t L < <(cw_spec_resume_state "$DD")
[[ "${#L[@]}" -eq 0 ]] || { echo "FAIL: missing dir should be empty (got ${#L[@]} entries)"; exit 1; }
pass "missing dir → empty"

# 2 approved sections + 1 zero-byte (not counted) + 1 drilldown in _scratch/
# (not matched by the non-recursive glob; resume_state's drilldown-* exclusion
# is also kept as defensive belt-and-suspenders for legacy / hand-placed files).
mkdir -p "$DD" "$DD/_scratch"
echo "content" > "$DD/architecture.md"
echo "content" > "$DD/components.md"
: > "$DD/data-flow.md"                            # zero-byte — not counted
echo "x" > "$DD/_scratch/drilldown-arch-rex.md"   # in _scratch/ — not matched by *.md
echo "x" > "$DD/drilldown-legacy-rex.md"          # at top level — excluded by drilldown-* gate

mapfile -t L < <(cw_spec_resume_state "$DD")
[[ "${#L[@]}" -eq 2 ]] || { echo "FAIL: expected 2 approved, got ${#L[@]} (${L[*]})"; exit 1; }
printf '%s\n' "${L[@]}" | grep -q '^architecture$' || { echo "FAIL: missing arch"; exit 1; }
printf '%s\n' "${L[@]}" | grep -q '^components$'   || { echo "FAIL: missing components"; exit 1; }
if printf '%s\n' "${L[@]}" | grep -q 'drilldown'; then echo "FAIL: drilldown leaked"; exit 1; fi
pass "approved sections listed; zero-byte + drilldowns (top-level + _scratch/) excluded"
