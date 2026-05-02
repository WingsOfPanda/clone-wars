#!/usr/bin/env bash
# tests/test_execute_design_helpers.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/log.sh
source ../lib/state.sh
source ../lib/consult.sh         # for cw_consult_outbox_match_endbyte (re-use)
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
