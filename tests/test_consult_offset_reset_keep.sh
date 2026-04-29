#!/usr/bin/env bash
# tests/test_consult_offset_reset_keep.sh — Task 7 (v0.3.0).
# Verifies --keep-findings flag on consult-offset-reset.sh.
# Used by Patterns 1/3 (full re-prompts), NOT the question loop.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"
export CLAUDE_PLUGIN_ROOT="$(cd .. && pwd)"

source ../lib/state.sh
RH=$(cw_repo_hash)
TOPIC=$(../bin/consult-init.sh "keep-findings test" 2>/dev/null)
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"

# Stage artifacts that --keep-findings should preserve.
mkdir -p "$TD/rex-codex"
echo "preserved findings"  > "$TD/rex-codex/findings.md"
echo "preserved verify"    > "$TD/rex-codex/verify.md"
echo "preserved diff"      > "$TD/_consult/diff.md"
echo "preserved rex_only"  > "$TD/_consult/rex_only_items.txt"
echo "preserved cody_only" > "$TD/_consult/cody_only_items.txt"
echo "preserved draft"     > "$TD/_consult/adjudicated-draft.md"
{ echo "OFFSET=42"; echo "FS=question"; } > "$TD/_consult/research-rex.txt"
echo "PENDING question payload" > "$TD/_consult/question-rex.txt"

../bin/consult-offset-reset.sh "$TOPIC" rex research --keep-findings

# State file removed (always).
[[ ! -f "$TD/_consult/research-rex.txt" ]] || { echo "FAIL: state file should be removed" >&2; exit 1; }
pass "state file removed"

# Pending question payload always cleared (it's been handled).
[[ ! -f "$TD/_consult/question-rex.txt" ]] || { echo "FAIL: question payload should be cleared" >&2; exit 1; }
pass "question payload cleared"

# Trooper-owned files preserved with --keep-findings.
[[ -f "$TD/rex-codex/findings.md" ]] || { echo "FAIL: findings.md was deleted" >&2; exit 1; }
pass "findings.md preserved with --keep-findings"

# Cascade artifacts preserved.
[[ -f "$TD/_consult/diff.md"      ]] || { echo "FAIL: diff.md deleted"      >&2; exit 1; }
[[ -f "$TD/_consult/rex_only_items.txt"  ]] || { echo "FAIL: rex_only deleted"  >&2; exit 1; }
[[ -f "$TD/_consult/cody_only_items.txt" ]] || { echo "FAIL: cody_only deleted" >&2; exit 1; }
[[ -f "$TD/_consult/adjudicated-draft.md" ]] || { echo "FAIL: draft deleted"     >&2; exit 1; }
pass "cascade artifacts preserved with --keep-findings"

# Verify-phase symmetry.
{ echo "OFFSET=99"; echo "VS=question"; } > "$TD/_consult/verify-rex.txt"
../bin/consult-offset-reset.sh "$TOPIC" rex verify --keep-findings

[[ ! -f "$TD/_consult/verify-rex.txt" ]] || { echo "FAIL: verify state file should be removed" >&2; exit 1; }
[[ -f "$TD/rex-codex/verify.md" ]] || { echo "FAIL: verify.md was deleted" >&2; exit 1; }
[[ -f "$TD/_consult/adjudicated-draft.md" ]] || { echo "FAIL: draft deleted in verify-phase" >&2; exit 1; }
pass "verify --keep-findings preserves verify.md + draft"

# Without --keep-findings, full cascade still works (existing v0.2 behavior).
echo "OFFSET=1" > "$TD/_consult/research-rex.txt"
../bin/consult-offset-reset.sh "$TOPIC" rex research
[[ ! -f "$TD/rex-codex/findings.md" ]] || { echo "FAIL: findings.md should be removed without flag" >&2; exit 1; }
[[ ! -f "$TD/_consult/diff.md" ]]      || { echo "FAIL: diff.md should be removed without flag" >&2; exit 1; }
pass "without flag, full cascade still removes findings.md + diff.md"
