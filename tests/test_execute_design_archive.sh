#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
TOPIC=archive-fixture
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
mkdir -p "$TD/_execute"
echo "design" > "$TD/_execute/design.md"
echo "plan"   > "$TD/_execute/plan.md"

../bin/execute-design-archive.sh "$TOPIC"

ARCHIVE_BASE="$CLONE_WARS_HOME/archive/$RH/$TOPIC"
[[ -d "$ARCHIVE_BASE" ]] || { echo "FAIL: archive base missing" >&2; exit 1; }
n=$(ls "$ARCHIVE_BASE" | grep -c '^_execute-' || true)
[[ "$n" -eq 1 ]] || { echo "FAIL: expected exactly one _execute-* dir, got $n" >&2; exit 1; }
[[ ! -d "$TD/_execute" ]] || { echo "FAIL: source _execute/ still present" >&2; exit 1; }
pass "archive moves _execute → archive/_execute-<ts>"

# Refuses if _execute/ missing.
err=$(../bin/execute-design-archive.sh "$TOPIC" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: should refuse already-archived" >&2; exit 1; }
pass "archive refuses already-archived"

# 3. Same-second collision: invoke twice within one second using fixed TS via mocked date.
# (We can't mock `date` cleanly without a wrapper, so instead we exercise the counter
# by pre-creating the conflict target.)
mkdir -p "$TD/_execute"
echo "rerun" > "$TD/_execute/design.md"
# Pre-create today's expected target so the first archive will collide.
TS=$(date -u +'%Y%m%dT%H%M%SZ')
mkdir -p "$ARCHIVE_BASE/_execute-$TS"
../bin/execute-design-archive.sh "$TOPIC"
# Now there should be at least 2 _execute-* dirs (the pre-created one + the -2 suffix).
n2=$(ls "$ARCHIVE_BASE" | grep -c '^_execute-' || true)
[[ "$n2" -ge 2 ]] || { echo "FAIL: collision counter didn't fire; got $n2 dirs" >&2; exit 1; }
ls "$ARCHIVE_BASE" | grep -q '^_execute-.*-2$' \
  || { echo "FAIL: counter-suffix dir missing" >&2; exit 1; }
pass "archive same-second collision uses counter suffix"
