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

# v0.4.2 — hash suffix (2nd arg).
P=$(cw_consult_design_doc_filename "lru-vs-lfu" "abc123")
assert_eq "$P" "docs/clone-wars/specs/2026-04-29-lru-vs-lfu-abc123-design.md" "filename with hash"
pass "v0.4.2: hash suffix appended"

# Empty hash arg falls back to v0.4.x form.
P=$(cw_consult_design_doc_filename "lru-vs-lfu" "")
assert_eq "$P" "docs/clone-wars/specs/2026-04-29-lru-vs-lfu-design.md" "empty hash falls back"
pass "v0.4.2: empty hash falls back to v0.4.x form"

# Non-hex hash rejects.
if cw_consult_design_doc_filename "ok-slug" "ZZZZZZ" 2>/dev/null; then
  echo "FAIL: non-hex hash should reject"; exit 1
fi
pass "v0.4.2: non-hex hash rejects"

# Wrong-length hash rejects (must be exactly 6 chars when present).
if cw_consult_design_doc_filename "ok-slug" "ab1" 2>/dev/null; then
  echo "FAIL: 3-char hash should reject"; exit 1
fi
pass "v0.4.2: wrong-length hash rejects"
