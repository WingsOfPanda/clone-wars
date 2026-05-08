#!/usr/bin/env bash
# Asserts cw_consult_design_doc_canonical_path returns the v0.16.0 path:
#   <art_dir>/design-doc/<YYYY-MM-DD>-<slug>-design.md
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/consult.sh"

ART_DIR=/tmp/cw-test-design-doc-path
TODAY=$(date -u +%Y-%m-%d)

# Slug input → expected filename pattern.
out=$(cw_consult_design_doc_canonical_path "$ART_DIR" "consult-foo-bar")
assert_eq "$out" "$ART_DIR/design-doc/$TODAY-consult-foo-bar-design.md" \
  "canonical path joins art_dir + design-doc/ + date-slug-design.md"
pass "cw_consult_design_doc_canonical_path basic shape"

# Empty slug → rc=2 + clear error.
cw_consult_design_doc_canonical_path "$ART_DIR" "" 2>/dev/null && {
  echo FAIL: empty slug should return rc=2; exit 1
}
pass "empty slug returns rc=2"

# Empty art_dir → rc=2.
cw_consult_design_doc_canonical_path "" "consult-foo" 2>/dev/null && {
  echo FAIL: empty art_dir should return rc=2; exit 1
}
pass "empty art_dir returns rc=2"
