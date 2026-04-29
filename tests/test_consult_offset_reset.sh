#!/usr/bin/env bash
# tests/test_consult_offset_reset.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

# Build a fake topic with all the artifacts reset should cascade.
RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
TOPIC=consult-fixture
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
mkdir -p "$TD/_consult"
echo "OFFSET=42" > "$TD/_consult/research-rex.txt"
echo "OFFSET=88" > "$TD/_consult/research-cody.txt"
echo "old diff"  > "$TD/_consult/diff.md"
echo "rex item"  > "$TD/_consult/rex_only_items.txt"
echo "cody item" > "$TD/_consult/cody_only_items.txt"
echo "draft"     > "$TD/_consult/adjudicated-draft.md"

# Add a stub trooper findings.md so we can assert the Rev1 cascade removes it.
mkdir -p "$TD/rex-codex" "$TD/cody-claude"
echo "stale rex findings" > "$TD/rex-codex/findings.md"
echo "cody findings"      > "$TD/cody-claude/findings.md"

# 1. Reset rex research → removes research-rex.txt + diff.md + both _only files + draft + rex-codex/findings.md.
../bin/consult-offset-reset.sh "$TOPIC" rex research
[[ ! -f "$TD/_consult/research-rex.txt"     ]] || { echo "FAIL: research-rex.txt survived" >&2; exit 1; }
[[ ! -f "$TD/_consult/diff.md"               ]] || { echo "FAIL: diff.md survived" >&2; exit 1; }
[[ ! -f "$TD/_consult/rex_only_items.txt"   ]] || { echo "FAIL: rex_only_items.txt survived" >&2; exit 1; }
[[ ! -f "$TD/_consult/cody_only_items.txt"  ]] || { echo "FAIL: cody_only_items.txt survived" >&2; exit 1; }
[[ ! -f "$TD/_consult/adjudicated-draft.md" ]] || { echo "FAIL: adjudicated-draft.md survived" >&2; exit 1; }
# Codex Rev1 #2: the trooper's findings.md must also be removed (else stale verdict marks FS=ok).
[[ ! -f "$TD/rex-codex/findings.md"         ]] || { echo "FAIL: rex's stale findings.md survived" >&2; exit 1; }
# But cody's research state is left alone — both the per-commander state file AND cody's findings.md.
[[ -f "$TD/_consult/research-cody.txt" ]] || { echo "FAIL: cody state was wrongly removed" >&2; exit 1; }
[[ -f "$TD/cody-claude/findings.md"     ]] || { echo "FAIL: cody's findings.md was wrongly removed" >&2; exit 1; }
pass "reset rex research cascades to derived artifacts AND trooper findings.md"

# 2. Idempotent: reset on missing file is rc=0, no error.
../bin/consult-offset-reset.sh "$TOPIC" rex research
pass "reset is idempotent on already-reset state"

# 3. Verify-phase reset touches verify state + adjudicated-draft + rex's verify.md.
echo "OFFSET=99"   > "$TD/_consult/verify-rex.txt"
echo "draft2"      > "$TD/_consult/adjudicated-draft.md"
echo "stale rex verify"  > "$TD/rex-codex/verify.md"
echo "cody verify"       > "$TD/cody-claude/verify.md"
../bin/consult-offset-reset.sh "$TOPIC" rex verify
[[ ! -f "$TD/_consult/verify-rex.txt"        ]] || { echo "FAIL: verify-rex.txt survived" >&2; exit 1; }
[[ ! -f "$TD/_consult/adjudicated-draft.md"  ]] || { echo "FAIL: draft survived verify reset" >&2; exit 1; }
[[ ! -f "$TD/rex-codex/verify.md"            ]] || { echo "FAIL: rex's stale verify.md survived" >&2; exit 1; }
[[ -f "$TD/_consult/research-cody.txt"        ]] || { echo "FAIL: research-cody wrongly affected" >&2; exit 1; }
[[ -f "$TD/cody-claude/verify.md"             ]] || { echo "FAIL: cody's verify.md wrongly removed" >&2; exit 1; }
pass "reset rex verify cascades to verify+draft AND rex's verify.md"

# 4. Bad phase rejected.
err=$(../bin/consult-offset-reset.sh "$TOPIC" rex bogus 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && echo "$err" | grep -q 'phase' \
  || { echo "FAIL: bad phase should reject" >&2; exit 1; }
pass "bad phase rejected"

# 5. Bad topic (path-traversal) rejected.
err=$(../bin/consult-offset-reset.sh "../etc/passwd" rex research 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: path-traversal accepted" >&2; exit 1; }
pass "path-traversal topic rejected"
