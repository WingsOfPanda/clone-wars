#!/usr/bin/env bash
# tests/test_ipc_archive.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/state.sh
source ../lib/ipc.sh

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

# Simulate a trooper state dir: state/<repo-hash>/<topic>/<commander>-<model>/
ROOT="$CLONE_WARS_HOME/state/$(cw_repo_hash)/demo/rex-codex"
mkdir -p "$ROOT"
echo 'sentinel' > "$ROOT/identity.md"

# 1. Default suffix-less archive — current behavior preserved.
DST=$(cw_state_archive rex codex demo)
assert_file_exists "$DST" "default archive created"
assert_file_exists "$DST/identity.md" "files moved into archive"
[[ ! -d "$ROOT" ]] || { echo "FAIL: source dir still present" >&2; exit 1; }
[[ "$DST" =~ /demo/rex-codex-[0-9TZ]+$ ]] || { echo "FAIL: default suffix shape wrong: $DST" >&2; exit 1; }
pass "default archive shape and move semantics"

# 2. Suffix appended when supplied.
mkdir -p "$ROOT"
echo 'sentinel-2' > "$ROOT/identity.md"
DST2=$(cw_state_archive rex codex demo FAILED)
[[ "$DST2" =~ /demo/rex-codex-[0-9TZ]+-FAILED$ ]] || {
  echo "FAIL: suffix not appended: $DST2" >&2; exit 1; }
assert_file_exists "$DST2/identity.md" "suffix archive moved files"
pass "suffix appended"

# 3. Same-second collision is resolved by the counter loop.
mkdir -p "$ROOT"; echo 'a' > "$ROOT/identity.md"
DST_A=$(cw_state_archive rex codex demo)
mkdir -p "$ROOT"; echo 'b' > "$ROOT/identity.md"
DST_B=$(cw_state_archive rex codex demo)
[[ "$DST_A" != "$DST_B" ]] || { echo "FAIL: collision not resolved: both = $DST_A" >&2; exit 1; }
assert_file_exists "$DST_A/identity.md" "first archive intact"
assert_file_exists "$DST_B/identity.md" "second archive intact"
pass "collision resolution"

echo "  ALL: ok"
