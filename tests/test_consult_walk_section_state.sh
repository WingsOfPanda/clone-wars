#!/usr/bin/env bash
# tests/test_consult_walk_section_state.sh
#
# cw_consult_walk_section_state <draft-dir>
# Lists the approved (non-skipped) section names that already exist as
# draft files. Used to resume a partial walk after a conductor restart.
# A section file containing only "_(skipped)_" still counts as "decided"
# but emits with a "skipped:" prefix so the directive can re-offer it.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

source ../lib/consult-walk.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
DD="$TMP/.draft"
mkdir -p "$DD"

# Empty dir → empty stdout, rc=0.
got=$(cw_consult_walk_section_state "$DD")
[[ -z "$got" ]] || { echo "FAIL: empty draft dir should produce no output, got=[$got]" >&2; exit 1; }

# Stage three sections: goal approved, architecture skipped, components approved.
printf '## Goal\n\nDescribe the world after this lands.\n' > "$DD/goal.md"
printf '_(skipped)_\n' > "$DD/architecture.md"
printf '## Components\n\n- file A\n- file B\n' > "$DD/components.md"

got=$(cw_consult_walk_section_state "$DD")

# Order is alphabetical (sort).
echo "$got" | head -1 | grep -qE '^architecture$'        && \
echo "$got" | sed -n '2p' | grep -qE '^components$'      && \
echo "$got" | sed -n '3p' | grep -qE '^goal$'            || {
  echo "FAIL: state order or membership; got=[$got]" >&2
  exit 1
}

# Also assert: the helper must distinguish skipped from approved when the
# caller calls with a "--with-status" flag.
got=$(cw_consult_walk_section_state --with-status "$DD")
TAB=$(printf '\t')
echo "$got" | grep -qE "^architecture${TAB}skipped$" || { echo "FAIL: missing skipped tag for architecture; got=[$got]" >&2; exit 1; }
echo "$got" | grep -qE "^goal${TAB}approved$"        || { echo "FAIL: missing approved tag for goal; got=[$got]" >&2; exit 1; }

# Missing arg → rc=2.
cw_consult_walk_section_state >/dev/null 2>&1 && { echo "FAIL: empty arg should rc=2" >&2; exit 1; } || rc=$?
[[ "$rc" -eq 2 ]] || { echo "FAIL: empty arg rc=$rc" >&2; exit 1; }

# Nonexistent dir → rc=1.
cw_consult_walk_section_state "$TMP/nonexistent" >/dev/null 2>&1 && { echo "FAIL: nonexistent dir should rc=1" >&2; exit 1; } || rc=$?
[[ "$rc" -eq 1 ]] || { echo "FAIL: nonexistent dir rc=$rc" >&2; exit 1; }

pass "cw_consult_walk_section_state: lists approved/skipped sections from draft dir"
