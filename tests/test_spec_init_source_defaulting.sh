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
EXPLICIT="$TMP/cw/state/$REPO_HASH/topic-explicit/_consult/synthesis.md"
mkdir -p "$(dirname "$EXPLICIT")"
echo "## Synthesis" > "$EXPLICIT"
OUT=$(../bin/spec-init.sh "$EXPLICIT")
echo "$OUT" | grep -q '^TOPIC=topic-explicit$' || { echo "FAIL: explicit path TOPIC wrong: $OUT" >&2; exit 1; }
echo "$OUT" | grep -q "^SEED=$EXPLICIT$" || { echo "FAIL: explicit path SEED wrong: $OUT" >&2; exit 1; }
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

# Case 4: explicit nonexistent path → exit 2 (bad arg).
../bin/spec-init.sh "$TMP/nope.md" && RC=0 || RC=$?
[[ "$RC" -eq 2 ]] || { echo "FAIL: nonexistent explicit path should exit 2, got $RC" >&2; exit 1; }
pass "explicit nonexistent path → exit 2"

# Case 5: no archive, only state has a synthesis → state entry wins.
rm -rf "$CLONE_WARS_HOME/archive" "$CLONE_WARS_HOME/state"
mkdir -p "$CLONE_WARS_HOME/state/$REPO_HASH/topic-state-only/_consult"
echo "## Synthesis" > "$CLONE_WARS_HOME/state/$REPO_HASH/topic-state-only/_consult/synthesis.md"
OUT=$(../bin/spec-init.sh)
echo "$OUT" | grep -q '^TOPIC=topic-state-only$' || { echo "FAIL: state-only fallback missed: $OUT" >&2; exit 1; }
pass "no-arg falls back to state when archive empty"

# Case 6: explicit path NOT under */_consult/synthesis.md → exit 2 (bad arg).
NOT_SYNTH="$TMP/random.md"
echo "## Not a synthesis" > "$NOT_SYNTH"
../bin/spec-init.sh "$NOT_SYNTH" && RC=0 || RC=$?
[[ "$RC" -eq 2 ]] || { echo "FAIL: non-synthesis path should exit 2, got $RC" >&2; exit 1; }
pass "explicit non-synthesis path → exit 2 (path-layout assertion)"
