#!/usr/bin/env bash
# tests/test_spawn_rollback.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/log.sh
source ../lib/state.sh
source ../lib/ipc.sh

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

# 1. Simulate a half-built state dir from a failed spawn.
SRC=$(cw_trooper_dir rex codex demo)
mkdir -p "$SRC"
echo 'partial' > "$SRC/identity.md"

# 2. Invoke the rollback (same call the FAIL branch will make).
DST=$(cw_state_archive rex codex demo FAILED)

# 3. Source dir is gone.
[[ ! -d "$SRC" ]] || { echo "FAIL: state dir still present after rollback: $SRC" >&2; exit 1; }
pass "state dir removed"

# 4. Archive exists with -FAILED suffix and preserved contents.
assert_file_exists "$DST" "FAILED archive created"
[[ "$DST" =~ -FAILED$ ]] || { echo "FAIL: archive missing FAILED suffix: $DST" >&2; exit 1; }
assert_file_exists "$DST/identity.md" "archived files preserved"
pass "archive has FAILED suffix and contents"

# 5. Re-spawn semantics: state slot freed, fresh trooper_dir is creatable.
mkdir -p "$SRC"
[[ -d "$SRC" ]] || { echo "FAIL: cannot recreate state dir post-rollback" >&2; exit 1; }
pass "state slot freed for retry"

# 6. Static wiring check: bin/spawn.sh's FAIL branch invokes
#    cw_state_archive with the FAILED suffix. Without this, the lib
#    semantics above are correct but the production spawn path could
#    silently regress (e.g., if someone reverts the FAIL-branch edit).
grep -qE 'cw_state_archive[[:space:]]+"\$COMMANDER"[[:space:]]+"\$MODEL"[[:space:]]+"\$TOPIC"[[:space:]]+FAILED' \
  ../bin/spawn.sh \
  || { echo "FAIL: bin/spawn.sh FAIL branch missing 'cw_state_archive ... FAILED' call" >&2; exit 1; }
pass "bin/spawn.sh FAIL branch wired to rollback"

echo "  ALL: ok"
