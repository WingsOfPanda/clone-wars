#!/usr/bin/env bash
# tests/test_consult_adjudicate.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
TOPIC=consult-fixture-adj
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
mkdir -p "$TD/_consult" "$TD/rex-codex" "$TD/cody-claude"

# v0.15.0: cw_consult_write_adjudicated discovers N + commander list from
# troopers.txt; consult-init writes this in real runs. Stage it for the test.
printf 'codex\trex\nclaude\tcody\n' > "$TD/_consult/troopers.txt"

# Set up state files.
cat > "$TD/_consult/research-rex.txt"  <<'EOF'
OFFSET=0
FS=ok
EOF
cat > "$TD/_consult/research-cody.txt" <<'EOF'
OFFSET=0
FS=ok
EOF
cat > "$TD/_consult/verify-rex.txt"  <<'EOF'
OFFSET=0
VS=ok
EOF
cat > "$TD/_consult/verify-cody.txt" <<'EOF'
OFFSET=0
VS=ok
EOF
touch "$TD/_consult/rex_only_items.txt" "$TD/_consult/cody_only_items.txt"

cat > "$TD/rex-codex/verify.md" <<'MD'
# Verify
## Verdicts
1. AGREE [src/x.py:5] tokens stored in plaintext.
   src/x.py:5 confirms
2. DISPUTE [src/y.py:10] some other claim.
   src/y.py:10 actually does the opposite
MD
cat > "$TD/cody-claude/verify.md" <<'MD'
# Verify
## Verdicts
1. AGREE [src/z.py:7] callback validated.
   line 7 has the assert
MD

# 1. Adjudicate writes DRAFT, not the resolved file.
../bin/consult-adjudicate.sh "$TOPIC"
[[ -f "$TD/_consult/adjudicated-draft.md" ]] || { echo "FAIL: draft missing" >&2; exit 1; }
[[ ! -f "$TD/_consult/adjudicated.md" ]]    || { echo "FAIL: resolved file should not exist yet" >&2; exit 1; }
grep -q '^## Cross-verified' "$TD/_consult/adjudicated-draft.md"  || { echo "FAIL: missing Cross-verified"  >&2; exit 1; }
grep -q '^## Adjudicated'    "$TD/_consult/adjudicated-draft.md"  || { echo "FAIL: missing Adjudicated"    >&2; exit 1; }
grep -q 'PENDING:'           "$TD/_consult/adjudicated-draft.md"  || { echo "FAIL: missing PENDING entry" >&2; exit 1; }
pass "adjudicate writes draft only"

# 2. Re-running adjudicate overwrites the draft (idempotent).
echo "stale" > "$TD/_consult/adjudicated-draft.md"
../bin/consult-adjudicate.sh "$TOPIC"
grep -q '^## Cross-verified' "$TD/_consult/adjudicated-draft.md" || { echo "FAIL: re-run did not regenerate draft" >&2; exit 1; }
pass "adjudicate re-run overwrites draft"

# 3. Codex #4 fixture: existing adjudicated.md (Master Yoda's resolution) is NEVER touched.
cat > "$TD/_consult/adjudicated.md" <<'MD'
## Cross-verified
- [src/x.py:5] confirmed by both
## Adjudicated
- CONFIRMED: [src/y.py:10] verified by Master Yoda reading source
## Contested
## Not-verified
MD
ORIGINAL=$(cat "$TD/_consult/adjudicated.md")

../bin/consult-adjudicate.sh "$TOPIC"

NEW=$(cat "$TD/_consult/adjudicated.md")
assert_eq "$NEW" "$ORIGINAL" "Master Yoda's adjudicated.md preserved across re-adjudicate"
pass "adjudicate never overwrites Master Yoda's adjudicated.md (Codex #4 fixture)"
