#!/usr/bin/env bash
# tests/test_spec_init_source_defaulting.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"
export CLAUDE_PLUGIN_ROOT="$(cd .. && pwd)"
source ../lib/state.sh
REPO_HASH=$(cw_repo_hash)

# Case 1: explicit valid path → echoes TOPIC + SEED.
SEED1="$TMP/explicit-synthesis.md"
mkdir -p "$TMP/state/$REPO_HASH/topic-explicit/_consult"
ARCHIVED1="$TMP/cw/state/$REPO_HASH/topic-explicit/_consult/synthesis.md"
mkdir -p "$(dirname "$ARCHIVED1")"
echo "## Synthesis" > "$ARCHIVED1"
OUT=$(../bin/spec-init.sh "$ARCHIVED1")
echo "$OUT" | grep -q '^TOPIC=topic-explicit$' || { echo "FAIL: explicit path TOPIC wrong: $OUT" >&2; exit 1; }
echo "$OUT" | grep -q "^SEED=$ARCHIVED1$" || { echo "FAIL: explicit path SEED wrong: $OUT" >&2; exit 1; }
pass "explicit seed path resolves topic + seed"

# Case 2: no arg, archive scan finds most recent.
mkdir -p "$CLONE_WARS_HOME/archive/$REPO_HASH/topic-archived/_consult"
echo "## Synthesis" > "$CLONE_WARS_HOME/archive/$REPO_HASH/topic-archived/_consult/synthesis.md"
sleep 1  # ensure mtime distinct
mkdir -p "$CLONE_WARS_HOME/archive/$REPO_HASH/topic-newer/_consult"
echo "## Synthesis" > "$CLONE_WARS_HOME/archive/$REPO_HASH/topic-newer/_consult/synthesis.md"
OUT=$(../bin/spec-init.sh)
echo "$OUT" | grep -q '^TOPIC=topic-newer$' || { echo "FAIL: archive-scan TOPIC wrong: $OUT" >&2; exit 1; }
pass "no-arg defaulting picks most recent archived synthesis"

# Case 3: no arg + no synthesis anywhere → exit 1.
rm -rf "$CLONE_WARS_HOME/archive" "$CLONE_WARS_HOME/state"
../bin/spec-init.sh && RC=0 || RC=$?
[[ "$RC" -eq 1 ]] || { echo "FAIL: empty state should exit 1, got $RC" >&2; exit 1; }
pass "no seed anywhere → exit 1"

# Case 4: explicit nonexistent path → exit 1.
../bin/spec-init.sh "$TMP/nope.md" && RC=0 || RC=$?
[[ "$RC" -eq 1 ]] || { echo "FAIL: nonexistent explicit path should exit 1, got $RC" >&2; exit 1; }
pass "explicit nonexistent path → exit 1"
