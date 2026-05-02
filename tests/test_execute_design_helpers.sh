#!/usr/bin/env bash
# tests/test_execute_design_helpers.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/log.sh
source ../lib/state.sh
source ../lib/execute_design.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

# 1. topic_dir + art_dir return absolute paths under $CLONE_WARS_HOME/state/.
RH=$(cw_repo_hash)
got=$(cw_execute_design_topic_dir my-topic)
assert_eq "$got" "$CLONE_WARS_HOME/state/$RH/my-topic" "topic_dir"
got=$(cw_execute_design_art_dir my-topic)
assert_eq "$got" "$CLONE_WARS_HOME/state/$RH/my-topic/_execute" "art_dir"
pass "topic_dir + art_dir"

# 2. assert_topic accepts valid slugs, rejects invalid.
( cw_execute_design_assert_topic my-topic ) || { echo "FAIL: valid slug rejected" >&2; exit 1; }
out=$( cw_execute_design_assert_topic "../bad" 2>&1 ) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: path-traversal accepted" >&2; exit 1; }
out=$( cw_execute_design_assert_topic "Bad-Topic" 2>&1 ) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: uppercase accepted" >&2; exit 1; }
pass "assert_topic"

# 3. derive_topic strips date prefix + -design.md suffix.
got=$(cw_execute_design_derive_topic "docs/superpowers/specs/2026-05-02-foo-bar-design.md")
assert_eq "$got" "foo-bar" "derive_topic strips prefix+suffix"
got=$(cw_execute_design_derive_topic "/abs/path/2026-04-29-x-design.md")
assert_eq "$got" "x" "derive_topic abs path"
# Filename without date prefix → return basename minus -design.md (caller decides)
got=$(cw_execute_design_derive_topic "anything-design.md")
assert_eq "$got" "anything" "derive_topic missing date prefix"
# Filename without -design.md suffix → return basename minus extension
got=$(cw_execute_design_derive_topic "raw.md")
assert_eq "$got" "raw" "derive_topic missing -design suffix"
# Empty / no-extension → empty string (caller refuses)
got=$(cw_execute_design_derive_topic "")
assert_eq "$got" "" "derive_topic empty input"
pass "derive_topic"

# 4. audit_doc — PASS for a complete spec, FAIL for one with TBDs and missing sections.
GOOD="$TMP/good.md"
cat > "$GOOD" <<'MD'
# Foo Spec
**Status:** Design
## Goal
Build foo.
## Architecture
Use bar pattern.
## Testing strategy
Unit tests under tests/test_foo.sh; integration via fixtures/.
## Success criteria
1. tests pass
2. medic OK
MD
out=$(cw_execute_design_audit_doc "$GOOD") && rc=0 || rc=$?
[[ "$rc" -eq 0 ]] || { echo "FAIL: good spec scored FAIL: $out" >&2; exit 1; }
echo "$out" | grep -q '^VERDICT=PASS' || { echo "FAIL: missing VERDICT=PASS in: $out" >&2; exit 1; }
pass "audit_doc PASS on complete spec"

BAD="$TMP/bad.md"
cat > "$BAD" <<'MD'
# Bad Spec
## Goal
TBD
## Architecture
fill in later
MD
out=$(cw_execute_design_audit_doc "$BAD") && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: bad spec scored PASS: $out" >&2; exit 1; }
echo "$out" | grep -q '^VERDICT=FAIL' || { echo "FAIL: missing VERDICT=FAIL in: $out" >&2; exit 1; }
echo "$out" | grep -q 'no_testing_section'   || { echo "FAIL: testing section not flagged" >&2; exit 1; }
echo "$out" | grep -q 'no_success_section'   || { echo "FAIL: success criteria not flagged" >&2; exit 1; }
echo "$out" | grep -q 'tbd_marker'           || { echo "FAIL: TBD not flagged" >&2; exit 1; }
echo "$out" | grep -q 'fill_in_later_marker' || { echo "FAIL: 'fill in later' not flagged" >&2; exit 1; }
pass "audit_doc FAIL on incomplete spec with structured issues"

# 5. Missing file → exit 2 with usage-style error.
out=$(cw_execute_design_audit_doc "$TMP/nope.md" 2>&1) && rc=0 || rc=$?
[[ "$rc" -eq 2 ]] || { echo "FAIL: missing file did not exit 2: rc=$rc out=$out" >&2; exit 1; }
pass "audit_doc rc=2 on missing file"
