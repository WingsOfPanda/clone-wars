#!/usr/bin/env bash
# tests/test_consult_archive.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
TOPIC=consult-fixture-arch
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
mkdir -p "$TD/_consult"
echo "synthesis content" > "$TD/_consult/synthesis.md"

# 1. Archive moves _consult to archive/, removes topic dir.
../bin/consult-archive.sh "$TOPIC"
[[ ! -d "$TD/_consult" ]] || { echo "FAIL: _consult survived" >&2; exit 1; }
[[ ! -d "$TD"           ]] || { echo "FAIL: topic dir survived" >&2; exit 1; }
arch=$(find "$CLONE_WARS_HOME/archive/$RH/$TOPIC" -maxdepth 1 -type d -name '_consult-*' 2>/dev/null | head -n1)
[[ -n "$arch" ]] || { echo "FAIL: _consult not archived" >&2; exit 1; }
[[ -f "$arch/synthesis.md" ]] || { echo "FAIL: synthesis.md not in archive" >&2; exit 1; }
pass "archive moves _consult, removes topic dir"

# 2. Re-running archive on missing _consult → rc=1.
err=$(../bin/consult-archive.sh "$TOPIC" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: missing _consult should reject" >&2; exit 1; }
pass "archive fails loud on missing _consult"

# 3. Bad topic rejected.
err=$(../bin/consult-archive.sh "../bad" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: bad topic accepted" >&2; exit 1; }
pass "bad topic rejected"

# 4. Same-second collision: invoke twice within one second using fixed TS via mocked date.
# (We can't mock `date` cleanly without a wrapper, so instead we exercise the counter
# by pre-creating the conflict target.)
mkdir -p "$TD/_consult"
echo "rerun" > "$TD/_consult/synthesis.md"
ARCHIVE_BASE="$CLONE_WARS_HOME/archive/$RH/$TOPIC"
# Pre-create today's expected target so the first archive will collide.
TS=$(date -u +'%Y%m%dT%H%M%SZ')
mkdir -p "$ARCHIVE_BASE/_consult-$TS"
../bin/consult-archive.sh "$TOPIC"
# Now there should be at least 2 _consult-* dirs (the pre-created one + the -2 suffix).
n2=$(ls "$ARCHIVE_BASE" | grep -c '^_consult-' || true)
[[ "$n2" -ge 2 ]] || { echo "FAIL: collision counter didn't fire; got $n2 dirs" >&2; exit 1; }
ls "$ARCHIVE_BASE" | grep -q '^_consult-.*-2$' \
  || { echo "FAIL: counter-suffix dir missing" >&2; exit 1; }
pass "archive same-second collision uses counter suffix"
