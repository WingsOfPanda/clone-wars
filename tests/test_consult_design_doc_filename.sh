#!/usr/bin/env bash
# tests/test_consult_design_doc_filename.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/state.sh
source ../lib/consult.sh

# Stub the date so tests are deterministic.
export CW_TEST_DATE=2026-04-29

# Happy path.
P=$(cw_consult_design_doc_filename "lru-vs-lfu") || { echo "FAIL: rc nonzero on valid slug"; exit 1; }
assert_eq "$P" "docs/clone-wars/specs/2026-04-29-lru-vs-lfu-design.md" "filename for valid slug"
pass "filename happy path"

# Empty slug rejects.
if cw_consult_design_doc_filename "" 2>/dev/null; then echo "FAIL: empty slug should reject"; exit 1; fi
pass "empty slug rejects"

# Slash in slug rejects.
if cw_consult_design_doc_filename "foo/bar" 2>/dev/null; then echo "FAIL: slash should reject"; exit 1; fi
pass "slash rejects"

# Uppercase rejects.
if cw_consult_design_doc_filename "FooBar" 2>/dev/null; then echo "FAIL: uppercase should reject"; exit 1; fi
pass "uppercase rejects"
