#!/usr/bin/env bash
# tests/test_consult_slug_regex_constant.sh
#
# Asserts that lib/state.sh defines a single CW_SLUG_REGEX_BASE constant and
# that no other lib/ or bin/ file carries a bare [A-Za-z0-9._-]+ literal —
# the regex character class for sub-project / leaf slug validation must be
# composed from the constant, not duplicated.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
source "$PLUGIN_ROOT/lib/state.sh"

# (a) Constant defined and exact value
[[ -n "${CW_SLUG_REGEX_BASE:-}" ]] || { echo "FAIL: CW_SLUG_REGEX_BASE unset"; exit 1; }
[[ "$CW_SLUG_REGEX_BASE" == '[A-Za-z0-9._-]+' ]] \
  || { echo "FAIL: unexpected value: $CW_SLUG_REGEX_BASE"; exit 1; }
pass "CW_SLUG_REGEX_BASE defined as '[A-Za-z0-9._-]+'"

# (b) No drift: bare regex literal must not appear in any lib/ or bin/ file
#     (except lib/state.sh which OWNS the constant)
hits=$(grep -rE '\[A-Za-z0-9._-\]\+' "$PLUGIN_ROOT/lib" "$PLUGIN_ROOT/bin" \
       | grep -v 'lib/state.sh' || true)
if [[ -n "$hits" ]]; then
  echo "FAIL: bare slug regex still present in non-state.sh files:"
  echo "$hits"
  exit 1
fi
pass "no bare [A-Za-z0-9._-]+ literals outside lib/state.sh"
