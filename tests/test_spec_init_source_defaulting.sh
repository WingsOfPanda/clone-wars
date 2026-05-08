#!/usr/bin/env bash
# tests/test_spec_init_source_defaulting.sh
#
# v0.16.0: /spec source-defaulting collapses to a SINGLE pattern —
# `_consult/design-doc/<date>-<slug>-design.md`. Pre-v0.16 also matched
# `_consult/synthesis.md`; that pattern is dropped (per v0.14 precedent,
# no back-compat for archived consult dirs without a design-doc).
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"
export CLAUDE_PLUGIN_ROOT="$(cd .. && pwd)"
source ../lib/state.sh
REPO_HASH=$(cw_repo_hash)

# Case 1: explicit valid path → echoes TOPIC + SEED.
EXPLICIT="$TMP/cw/state/$REPO_HASH/topic-explicit/_consult/design-doc/2026-05-08-topic-explicit-design.md"
mkdir -p "$(dirname "$EXPLICIT")"
echo "## Summary" > "$EXPLICIT"
OUT=$(../bin/spec-init.sh "$EXPLICIT")
echo "$OUT" | grep -q '^TOPIC=topic-explicit$' || { echo "FAIL: explicit path TOPIC wrong: $OUT" >&2; exit 1; }
echo "$OUT" | grep -q "^SEED=$EXPLICIT$" || { echo "FAIL: explicit path SEED wrong: $OUT" >&2; exit 1; }
pass "explicit seed path resolves topic + seed"

# Case 2: no arg, archive scan finds most recent.
mkdir -p "$CLONE_WARS_HOME/archive/$REPO_HASH/topic-archived/_consult/design-doc"
echo "## Summary" > "$CLONE_WARS_HOME/archive/$REPO_HASH/topic-archived/_consult/design-doc/2026-05-08-topic-archived-design.md"
sleep 1  # ensure mtime distinct
mkdir -p "$CLONE_WARS_HOME/archive/$REPO_HASH/topic-newer/_consult/design-doc"
echo "## Summary" > "$CLONE_WARS_HOME/archive/$REPO_HASH/topic-newer/_consult/design-doc/2026-05-08-topic-newer-design.md"
OUT=$(../bin/spec-init.sh)
echo "$OUT" | grep -q '^TOPIC=topic-newer$' || { echo "FAIL: archive-scan TOPIC wrong: $OUT" >&2; exit 1; }
pass "no-arg defaulting picks most recent archived design-doc"

# Case 3: no arg + no design-doc anywhere → exit 1.
rm -rf "$CLONE_WARS_HOME/archive" "$CLONE_WARS_HOME/state"
../bin/spec-init.sh && RC=0 || RC=$?
[[ "$RC" -eq 1 ]] || { echo "FAIL: empty state should exit 1, got $RC" >&2; exit 1; }
pass "no seed anywhere → exit 1"

# Case 4: explicit nonexistent path → exit 2 (bad arg).
../bin/spec-init.sh "$TMP/nope.md" && RC=0 || RC=$?
[[ "$RC" -eq 2 ]] || { echo "FAIL: nonexistent explicit path should exit 2, got $RC" >&2; exit 1; }
pass "explicit nonexistent path → exit 2"

# Case 5: no archive, only state has a design-doc → state entry wins.
rm -rf "$CLONE_WARS_HOME/archive" "$CLONE_WARS_HOME/state"
mkdir -p "$CLONE_WARS_HOME/state/$REPO_HASH/topic-state-only/_consult/design-doc"
echo "## Summary" > "$CLONE_WARS_HOME/state/$REPO_HASH/topic-state-only/_consult/design-doc/2026-05-08-topic-state-only-design.md"
OUT=$(../bin/spec-init.sh)
echo "$OUT" | grep -q '^TOPIC=topic-state-only$' || { echo "FAIL: state-only fallback missed: $OUT" >&2; exit 1; }
pass "no-arg falls back to state when archive empty"

# Case 6: explicit path NOT under */_consult/design-doc/*-design.md → exit 2 (bad arg).
NOT_DESIGN="$TMP/random.md"
echo "## Not a design-doc" > "$NOT_DESIGN"
../bin/spec-init.sh "$NOT_DESIGN" && RC=0 || RC=$?
[[ "$RC" -eq 2 ]] || { echo "FAIL: non-design-doc path should exit 2, got $RC" >&2; exit 1; }
pass "explicit non-design-doc path → exit 2 (path-layout assertion)"

# Case 7: archive uses _consult-<timestamp>/ layout (real consult-archive.sh output)
# — discovered in v0.12.0 dogfood. Source-defaulting MUST find these.
rm -rf "$CLONE_WARS_HOME/archive" "$CLONE_WARS_HOME/state"
mkdir -p "$CLONE_WARS_HOME/archive/$REPO_HASH/topic-real-archive/_consult-20260506T090050Z/design-doc"
echo "## Summary" > "$CLONE_WARS_HOME/archive/$REPO_HASH/topic-real-archive/_consult-20260506T090050Z/design-doc/2026-05-06-topic-real-archive-design.md"
OUT=$(../bin/spec-init.sh)
echo "$OUT" | grep -q '^TOPIC=topic-real-archive$' || { echo "FAIL: timestamped-archive scan missed: $OUT" >&2; exit 1; }
pass "no-arg finds archived _consult-<timestamp>/design-doc/<date>-<slug>-design.md (v0.12.0 dogfood regression)"

# Case 8: explicit path under _consult-<timestamp>/ also passes path-layout assertion.
ARCHIVED_TS="$CLONE_WARS_HOME/archive/$REPO_HASH/topic-real-archive/_consult-20260506T090050Z/design-doc/2026-05-06-topic-real-archive-design.md"
OUT=$(../bin/spec-init.sh "$ARCHIVED_TS")
echo "$OUT" | grep -q '^TOPIC=topic-real-archive$' || { echo "FAIL: explicit _consult-<ts>/ path TOPIC wrong: $OUT" >&2; exit 1; }
pass "explicit _consult-<timestamp>/design-doc/<date>-<slug>-design.md passes path-layout assertion"

# Case 9 (v0.16.0 regression): legacy _consult/synthesis.md is NOT picked up by source-defaulting.
# Pre-v0.16 the find pattern matched both design-doc and synthesis.md; v0.16 drops the
# synthesis.md clause. Archived consult dirs without a design-doc are no longer discoverable
# via no-arg /spec (per v0.14 precedent — no back-compat).
rm -rf "$CLONE_WARS_HOME/archive" "$CLONE_WARS_HOME/state"
mkdir -p "$CLONE_WARS_HOME/archive/$REPO_HASH/topic-legacy-synthesis/_consult"
echo "## Synthesis" > "$CLONE_WARS_HOME/archive/$REPO_HASH/topic-legacy-synthesis/_consult/synthesis.md"
../bin/spec-init.sh && RC=0 || RC=$?
[[ "$RC" -eq 1 ]] || { echo "FAIL: legacy synthesis.md should NOT be picked up (v0.16); exit 1 expected, got $RC" >&2; exit 1; }
pass "v0.16: legacy _consult/synthesis.md is NOT discovered by source-defaulting"

# Case 10 (v0.16.0 regression): explicit path to legacy synthesis.md → exit 2 (path-layout assert).
LEGACY="$CLONE_WARS_HOME/archive/$REPO_HASH/topic-legacy-synthesis/_consult/synthesis.md"
../bin/spec-init.sh "$LEGACY" && RC=0 || RC=$?
[[ "$RC" -eq 2 ]] || { echo "FAIL: explicit legacy synthesis.md should exit 2 (path-layout), got $RC" >&2; exit 1; }
pass "v0.16: explicit legacy synthesis.md path → exit 2 (path-layout assertion rejects)"
