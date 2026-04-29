#!/usr/bin/env bash
# tests/test_consult_synthesize_bin.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
TOPIC=consult-fixture-syn
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
mkdir -p "$TD/_consult" "$TD/rex-codex" "$TD/cody-claude"

# Pre-populate state.
echo "topic text" > "$TD/_consult/topic.txt"
cat > "$TD/_consult/research-rex.txt"  <<EOF
OFFSET=0
FS=ok
EOF
cat > "$TD/_consult/research-cody.txt" <<EOF
OFFSET=0
FS=ok
EOF
cat > "$TD/_consult/verify-rex.txt"  <<EOF
OFFSET=0
VS=ok
EOF
cat > "$TD/_consult/verify-cody.txt" <<EOF
OFFSET=0
VS=ok
EOF
cat > "$TD/_consult/diff.md" <<'MD'
## Agreed
- [src/x.py:5] both | Both confirm.
## Rex-only
## Cody-only
MD

# 1. adjudicated.md missing → rc=1.
err=$(../bin/consult-synthesize.sh "$TOPIC" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && echo "$err" | grep -q 'adjudicated.md' \
  || { echo "FAIL: missing adjudicated.md should reject" >&2; exit 1; }
pass "synthesize refuses without adjudicated.md"

# 2. adjudicated.md with PENDING → rc=1.
cat > "$TD/_consult/adjudicated.md" <<'MD'
## Cross-verified
## Adjudicated
- PENDING: [src/y.py:10] needs resolution
## Contested
## Not-verified
MD
err=$(../bin/consult-synthesize.sh "$TOPIC" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && echo "$err" | grep -q 'PENDING' \
  || { echo "FAIL: PENDING should block" >&2; exit 1; }
pass "synthesize refuses with PENDING items"

# 3. Resolved adjudicated.md → rc=0; synthesis.md created.
sed -i 's/^- PENDING:/- CONFIRMED:/' "$TD/_consult/adjudicated.md"
../bin/consult-synthesize.sh "$TOPIC" >/dev/null
[[ -f "$TD/_consult/synthesis.md" ]] || { echo "FAIL: synthesis.md missing" >&2; exit 1; }
grep -q '^# Consultation: topic text' "$TD/_consult/synthesis.md" || { echo "FAIL: synthesis title missing" >&2; exit 1; }
pass "synthesize writes synthesis.md when no PENDING"

# 4. Re-running on existing synthesis.md → rc=1.
err=$(../bin/consult-synthesize.sh "$TOPIC" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: re-run on existing synthesis should reject" >&2; exit 1; }
pass "synthesize fails loud on existing synthesis.md"
