#!/usr/bin/env bash
# tests/test_state.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/state.sh

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 1. Default root is $PWD/.clone-wars when CLONE_WARS_HOME is unset (v0.31.0:
#    project-local state — the directive's Bash blocks run in the conductor's
#    invocation cwd, so $PWD resolves there. CLONE_WARS_HOME stays as a
#    test/debug seam — Case 2 below covers it).
unset CLONE_WARS_HOME
assert_eq "$(cw_state_root)" "$PWD/.clone-wars" "default root (v0.31.0 project-local)"
pass "default root"

# 2. Override via CLONE_WARS_HOME. (Uses a sandboxed path; cw_state_root
#    returns the value verbatim — no fs operations on the path.)
CLONE_WARS_HOME="$TMP/cw-test" assert_eq "$(CLONE_WARS_HOME="$TMP/cw-test" cw_state_root)" "$TMP/cw-test" "override"
pass "override root"

# 3. cw_state_ensure creates root + standard subdirs and is idempotent.
CLONE_WARS_HOME="$TMP/cw" cw_state_ensure
assert_file_exists "$TMP/cw" "root created"
assert_file_exists "$TMP/cw/state" "state subdir"
assert_file_exists "$TMP/cw/archive" "archive subdir"
# Idempotent: second call doesn't error.
CLONE_WARS_HOME="$TMP/cw" cw_state_ensure
pass "ensure idempotent"

# 4. cw_repo_hash is sha256 of realpath(pwd), 64 hex chars.
H=$(cw_repo_hash)
[[ "${#H}" -eq 64 ]] || { echo "FAIL: hash length ${#H}, want 64" >&2; exit 1; }
[[ "$H" =~ ^[0-9a-f]{64}$ ]] || { echo "FAIL: hash not hex: $H" >&2; exit 1; }
pass "repo_hash hex64"

# 5. Same cwd → same hash; different cwd → different hash.
H2=$(cw_repo_hash)
assert_eq "$H" "$H2" "stable across calls"
pass "repo_hash stable"

(cd "$TMP" && H3=$(cw_repo_hash); [[ "$H3" != "$H" ]]) || { echo "FAIL: different cwd produced same hash" >&2; exit 1; }
pass "repo_hash differs by cwd"

# 6. cw_repo_state_dir composes state-root + repo-hash.
EXPECTED="$(cw_state_root)/state/$(cw_repo_hash)"
assert_eq "$(cw_repo_state_dir)" "$EXPECTED" "repo_state_dir composition"
pass "repo_state_dir composes state/<hash>"

# 7. cw_topic_state_dir appends the topic.
assert_eq "$(cw_topic_state_dir foo)" "$EXPECTED/foo" "topic_state_dir composition"
pass "topic_state_dir composes state/<hash>/<topic>"

# 8. cw_atomic_write — writes stdin, leaves no .tmp leak, dest contains content.
# Source log.sh because cw_atomic_write calls log_error on failure paths.
source ../lib/log.sh
DEST="$TMP/atomic-write-test.txt"
printf 'hello\nworld\n' | cw_atomic_write "$DEST"
[[ -f "$DEST" ]] || { echo "FAIL: cw_atomic_write didn't create dest" >&2; exit 1; }
[[ "$(cat "$DEST")" == $'hello\nworld' ]] || { echo "FAIL: dest content mismatch" >&2; exit 1; }
shopt -s nullglob
TMP_LEAKS=("$TMP"/atomic-write-test.txt.tmp.*)
(( ${#TMP_LEAKS[@]} == 0 )) || { echo "FAIL: tmp leaked: ${TMP_LEAKS[*]}" >&2; exit 1; }
shopt -u nullglob
pass "atomic_write writes content with no tmp leak"

# 9. cw_atomic_write — overwrite is atomic (concurrent writers don't truncate).
N=10
PIDS=()
for ((i = 0; i < N; i++)); do
  ( printf 'writer-%d\n' "$i" | cw_atomic_write "$DEST" ) &
  PIDS+=("$!")
done
for p in "${PIDS[@]}"; do wait "$p"; done
[[ "$(cat "$DEST")" =~ ^writer-[0-9]+$ ]] || { echo "FAIL: concurrent atomic_write produced corrupted dest: $(cat "$DEST")" >&2; exit 1; }
shopt -s nullglob
TMP_LEAKS=("$TMP"/atomic-write-test.txt.tmp.*)
(( ${#TMP_LEAKS[@]} == 0 )) || { echo "FAIL: tmp leaked after concurrent writes: ${TMP_LEAKS[*]}" >&2; exit 1; }
shopt -u nullglob
pass "atomic_write survives $N concurrent writers"

# --- cw_repo_hash_for ---
TMP_RH=$(mktemp -d); trap 'rm -rf "$TMP_RH" "${OLD_TRAP:-}"' EXIT
mkdir -p "$TMP_RH/dir-a" "$TMP_RH/dir-b"

# Case 1: explicit cwd produces deterministic hash
h1=$(cw_repo_hash_for "$TMP_RH/dir-a")
h2=$(cw_repo_hash_for "$TMP_RH/dir-a")
[[ "$h1" == "$h2" ]] || { echo "FAIL: cw_repo_hash_for must be deterministic (got '$h1' vs '$h2')" >&2; exit 1; }
[[ ${#h1} -eq 64 ]] || { echo "FAIL: cw_repo_hash_for must return 64-char SHA256 (got len ${#h1})" >&2; exit 1; }
pass "cw_repo_hash_for is deterministic + 64-char SHA256"

# Case 2: equivalence with cw_repo_hash when cwd matches $PWD
( cd "$TMP_RH/dir-a" && [[ "$(cw_repo_hash)" == "$(cw_repo_hash_for "$PWD")" ]] ) \
  || { echo "FAIL: cw_repo_hash and cw_repo_hash_for \$PWD must agree" >&2; exit 1; }
pass "cw_repo_hash equals cw_repo_hash_for \$PWD"

# Case 3: distinct cwds produce distinct hashes
h_a=$(cw_repo_hash_for "$TMP_RH/dir-a")
h_b=$(cw_repo_hash_for "$TMP_RH/dir-b")
[[ "$h_a" != "$h_b" ]] || { echo "FAIL: distinct cwds must hash differently" >&2; exit 1; }
pass "cw_repo_hash_for distinguishes different cwds"
