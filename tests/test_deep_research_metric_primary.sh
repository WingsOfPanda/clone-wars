#!/usr/bin/env bash
# tests/test_deep_research_metric_primary.sh — v0.46.0 finding #3
# Locks: cw_deep_research_metric_primary(metric_md_path) extracts the
# "**Primary metric:**" line value via awk. Returns empty on missing/malformed.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

# Case 1: present, single-token value
cat > "$SANDBOX/m1.md" <<'EOM'
**Primary metric:** accuracy
**direction:** maximize
EOM
out=$(cw_deep_research_metric_primary "$SANDBOX/m1.md")
assert_eq "$out" "accuracy" "single-token primary metric"
pass "1. present single-token metric extracted"

# Case 2: present, multi-word value
cat > "$SANDBOX/m2.md" <<'EOM'
**Primary metric:** test set accuracy
EOM
out=$(cw_deep_research_metric_primary "$SANDBOX/m2.md")
assert_eq "$out" "test set accuracy" "multi-word primary metric"
pass "2. multi-word metric extracted verbatim"

# Case 3: missing file — empty output, rc=0
set +e
out=$(cw_deep_research_metric_primary "$SANDBOX/nope.md")
rc=$?
set -e
assert_eq "$out" "" "missing file → empty output"
assert_eq "$rc" "0" "missing file → rc=0 (no exit-fail)"
pass "3. missing file → empty + rc=0"

# Case 4: malformed file (no Primary metric line) — empty output
cat > "$SANDBOX/m4.md" <<'EOM'
# header
no metric block here
EOM
out=$(cw_deep_research_metric_primary "$SANDBOX/m4.md")
assert_eq "$out" "" "malformed → empty"
pass "4. malformed file → empty output"

echo "test_deep_research_metric_primary: 4 cases passed"
