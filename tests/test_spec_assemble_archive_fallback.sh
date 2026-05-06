#!/usr/bin/env bash
# tests/test_spec_assemble_archive_fallback.sh — v0.12.2 regression.
#
# Drives bin/spec-assemble.sh against design-doc dirs nested under
# `_consult-<timestamp>/` (the archived layout produced by
# bin/consult-archive.sh) instead of the live `_consult/` path. Without
# the v0.12.2 archive-glob fallback, this fails with "design-doc dir not
# found".
#
# Verifies:
#   - design-doc dir under <topic>/_consult-<ts>/design-doc/ is found
#   - design-doc dir under archive/<repo-hash>/<topic>/_consult-<ts>/design-doc/
#     (state torn down) is also found
#   - mtime tie-breaker picks the most recent _consult-<ts>/ when several exist
set -euo pipefail
cd "$(dirname "$0")"
PLUGIN_ROOT=$(cd .. && pwd)
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Ephemeral git repo for the orchestrator's git add/commit to operate against.
EREPO="$TMP/erepo"
mkdir -p "$EREPO"
(cd "$EREPO" && git init -q && \
  git config user.email "test@example.com" && \
  git config user.name "Test User")

export CLONE_WARS_HOME="$TMP/cw"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
export CW_TEST_DATE=2026-05-06
mkdir -p "$CLONE_WARS_HOME"

source "$PLUGIN_ROOT/lib/state.sh"
EREPO_HASH=$(cd "$EREPO" && cw_repo_hash)

write_clean_sections() {
  local dd="$1"
  cat > "$dd/architecture.md" <<'MD'
The system is fine.

## Tech Stack
- bash
MD
  cat > "$dd/components.md"   <<<'Components A and B.'
  cat > "$dd/data-flow.md"    <<<'Inputs map to outputs.'
  cat > "$dd/error-handling.md" <<<'Errors propagate.'
  cat > "$dd/testing.md"      <<<'Run the suite.'
}

# === Case 1: state-side _consult-<ts>/ (live archive layout) ===
TOPIC1=consult-archive-fallback-test-1
TD1="$CLONE_WARS_HOME/state/$EREPO_HASH/$TOPIC1"
DD1="$TD1/_consult-20260506T010000Z/design-doc"
mkdir -p "$DD1"
printf 'archive fallback test 1' > "$TD1/_consult-20260506T010000Z/topic.txt"
write_clean_sections "$DD1"

(cd "$EREPO" && "$PLUGIN_ROOT/bin/spec-assemble.sh" "$TOPIC1") >/dev/null 2>&1 || \
  { echo "FAIL: spec-assemble didn't find _consult-<ts>/design-doc/ under state" >&2; exit 1; }

OUT1=$(find "$EREPO/docs/clone-wars/specs" -name "2026-05-06-archive-fallback-test-1-*.md" 2>/dev/null | head -1)
[[ -n "$OUT1" && -f "$OUT1" ]] || { echo "FAIL: no spec produced for state-side archive layout" >&2; exit 1; }
pass "spec-assemble finds design-doc under state-side _consult-<ts>/"

# === Case 2: archive-root _consult-<ts>/ (state torn down post-consult) ===
TOPIC2=consult-archive-fallback-test-2
ARCH_TD2="$CLONE_WARS_HOME/archive/$EREPO_HASH/$TOPIC2"
DD2="$ARCH_TD2/_consult-20260506T020000Z/design-doc"
mkdir -p "$DD2"
printf 'archive fallback test 2' > "$ARCH_TD2/_consult-20260506T020000Z/topic.txt"
write_clean_sections "$DD2"
# Note: NO state-side dir for TOPIC2 — must fall back to archive root.

(cd "$EREPO" && "$PLUGIN_ROOT/bin/spec-assemble.sh" "$TOPIC2") >/dev/null 2>&1 || \
  { echo "FAIL: spec-assemble didn't fall back to archive root for torn-down state" >&2; exit 1; }

OUT2=$(find "$EREPO/docs/clone-wars/specs" -name "2026-05-06-archive-fallback-test-2-*.md" 2>/dev/null | head -1)
[[ -n "$OUT2" && -f "$OUT2" ]] || { echo "FAIL: no spec produced for archive-root layout" >&2; exit 1; }
pass "spec-assemble falls back to archive/<hash>/<topic>/_consult-<ts>/ when state torn down"

# === Case 3: multiple _consult-<ts>/ dirs, most recent by mtime wins ===
TOPIC3=consult-archive-fallback-test-3
TD3="$CLONE_WARS_HOME/state/$EREPO_HASH/$TOPIC3"
DD_OLD="$TD3/_consult-20260101T000000Z/design-doc"
DD_NEW="$TD3/_consult-20260506T030000Z/design-doc"
mkdir -p "$DD_OLD" "$DD_NEW"
printf 'old run' > "$TD3/_consult-20260101T000000Z/topic.txt"
printf 'new run wins' > "$TD3/_consult-20260506T030000Z/topic.txt"
write_clean_sections "$DD_OLD"
write_clean_sections "$DD_NEW"

# Bump mtime so DD_NEW is unambiguously newer than DD_OLD.
touch "$TD3/_consult-20260506T030000Z" "$DD_NEW"
sleep 0.1
touch -d '2026-01-01' "$TD3/_consult-20260101T000000Z" "$DD_OLD"

(cd "$EREPO" && "$PLUGIN_ROOT/bin/spec-assemble.sh" "$TOPIC3") >/dev/null 2>&1 || \
  { echo "FAIL: spec-assemble failed with multiple _consult-<ts>/ dirs" >&2; exit 1; }

OUT3=$(find "$EREPO/docs/clone-wars/specs" -name "2026-05-06-archive-fallback-test-3-*.md" 2>/dev/null | head -1)
[[ -n "$OUT3" && -f "$OUT3" ]] || { echo "FAIL: no spec produced when multiple archive dirs present" >&2; exit 1; }

# Hash suffix should match "new run wins" topic, not "old run".
NEW_HASH=$(printf '%s' 'new run wins' | sha256sum | cut -c1-6)
[[ "$OUT3" == *"-${NEW_HASH}-design.md" ]] || \
  { echo "FAIL: most-recent _consult-<ts>/ tie-breaker missed; expected hash $NEW_HASH in $OUT3" >&2; exit 1; }
pass "spec-assemble picks most-recent _consult-<ts>/ by mtime when several exist"
