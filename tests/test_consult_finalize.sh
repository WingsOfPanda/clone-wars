#!/usr/bin/env bash
# tests/test_consult_finalize.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

# Build a fake _consult/ subtree that looks like Phase 5's output.
RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
TOPIC=consult-fakeslug
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
ART="$TD/_consult"
mkdir -p "$ART"
mkdir -p "$TD/rex-codex"   "$TD/cody-claude"
echo 'topic text' > "$ART/topic.txt"

cat > "$ART/diff.md" <<'MD'
## Agreed
- [src/x.py:5] Real | Real.
## Rex-only
## Cody-only
MD

# Adjudicated WITH a PENDING item — finalize must refuse.
cat > "$ART/adjudicated.md" <<'MD'
## Cross-verified
## Adjudicated
- PENDING: [src/y.py:10] needs resolution
## Contested
## Not-verified
MD
cat > "$ART/research_status.txt" <<EOF
REX_FS=ok
CODY_FS=ok
EOF
cat > "$ART/verify_status.txt" <<EOF
REX_VS=ok
CODY_VS=ok
EOF

out=$(../bin/consult-finalize.sh "$TOPIC" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'PENDING' \
  || { echo "FAIL: PENDING should block finalize" >&2; exit 1; }
pass "finalize refuses to run with PENDING items"

# Resolve the PENDING and retry. NOTE: skip the actual teardown by setting a
# sentinel that consult-finalize.sh recognizes.
sed -i 's/^- PENDING:.*$/- CONFIRMED: [src\/y.py:10] real claim — verified/' "$ART/adjudicated.md"
export CW_CONSULT_FINALIZE_NO_TEARDOWN=1

out=$(../bin/consult-finalize.sh "$TOPIC" 2>&1) || { echo "FAIL: finalize should succeed: $out" >&2; exit 1; }

# synthesis.md was created.
[[ -f "$CLONE_WARS_HOME/archive/$RH/$TOPIC/_consult-"*"/synthesis.md" ]] \
  || [[ -f "$ART/synthesis.md" ]] \
  || { echo "FAIL: synthesis.md missing" >&2; ls -la "$ART" >&2; exit 1; }
pass "finalize wrote synthesis.md"

# synthesis.md never contains 'PENDING' as an active item.
syn=$(find "$CLONE_WARS_HOME/archive/$RH/$TOPIC" -name synthesis.md 2>/dev/null) || syn="$ART/synthesis.md"
grep -q '^- PENDING:' "$syn" && { echo "FAIL: synthesis still has PENDING" >&2; exit 1; }
pass "synthesis.md is PENDING-free"

# _consult/ has moved to archive/.
arch=$(find "$CLONE_WARS_HOME/archive/$RH/$TOPIC" -maxdepth 1 -type d -name '_consult-*' 2>/dev/null | head -n1)
[[ -n "$arch" ]] || { echo "FAIL: _consult/ not archived" >&2; ls -la "$CLONE_WARS_HOME/archive/$RH/$TOPIC" >&2 || true; exit 1; }
pass "_consult/ archived alongside trooper state"
