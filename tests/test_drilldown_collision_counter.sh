#!/usr/bin/env bash
# tests/test_drilldown_collision_counter.sh
# Regression for v0.20.4: bin/consult-drilldown.sh resolve_out_path
# must preserve the section name on collision (the bash-glob strip
# in the v0.20.3- shape lost the section name).
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

# Simulate the post-fix collision-counter logic from resolve_out_path.
# Test 1: fresh path with no digit suffix — strip is a no-op.
base="drilldown-mysection-rex"
if [[ "$base" =~ ^(.+)-[0-9]+$ ]]; then base="${BASH_REMATCH[1]}"; fi
[[ "$base" == "drilldown-mysection-rex" ]] \
  || { echo "FAIL: fresh strip altered base: '$base'" >&2; exit 1; }
pass "fresh path strip is no-op"

# Test 2: path with -2 suffix — strip leaves "drilldown-mysection-rex".
base="drilldown-mysection-rex-2"
if [[ "$base" =~ ^(.+)-[0-9]+$ ]]; then base="${BASH_REMATCH[1]}"; fi
[[ "$base" == "drilldown-mysection-rex" ]] \
  || { echo "FAIL: -2 strip yielded '$base', expected 'drilldown-mysection-rex'" >&2; exit 1; }
pass "trailing -2 stripped, section name preserved"

# Test 3: path with year-shaped infix — must NOT be stripped (pre-fix bug).
base="drilldown-foo-2025-arch-rex"
if [[ "$base" =~ ^(.+)-[0-9]+$ ]]; then base="${BASH_REMATCH[1]}"; fi
[[ "$base" == "drilldown-foo-2025-arch-rex" ]] \
  || { echo "FAIL: year-shaped infix wrongly stripped to '$base'" >&2; exit 1; }
pass "year-shaped infix NOT stripped (regression vs bash-glob bug)"

# Test 4: 2-digit counter -42 also strips cleanly.
base="drilldown-foo-rex-42"
if [[ "$base" =~ ^(.+)-[0-9]+$ ]]; then base="${BASH_REMATCH[1]}"; fi
[[ "$base" == "drilldown-foo-rex" ]] \
  || { echo "FAIL: -42 strip yielded '$base', expected 'drilldown-foo-rex'" >&2; exit 1; }
pass "2-digit counter -42 stripped cleanly"

pass "drilldown collision counter regression tests pass"
