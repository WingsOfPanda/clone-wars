#!/usr/bin/env bash
# tests/test_consult_init_handles_stale_active.sh
#
# v0.18.0: providers-active.txt may list a provider that's no longer
# consult-eligible (e.g. user uninstalled binary, or row removed from
# contracts.yaml). The existing cw_consult_eligible_providers filter
# drops the stale entry; consult-init proceeds with the surviving
# subset as long as N >= 2.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"
mkdir -p "$CLONE_WARS_HOME"

cat > "$CLONE_WARS_HOME/providers-available.txt" <<EOF
codex
claude
EOF

# Stage providers-active.txt with one stale entry ("gemini" is not in
# cw_consult_eligible_providers' allow-list of codex|claude|opencode).
cat > "$CLONE_WARS_HOME/providers-active.txt" <<EOF
codex
claude
gemini
EOF

INIT="$(cd .. && pwd)/bin/consult-init.sh"
LIB="$(cd .. && pwd)/lib/state.sh"
RH=$(bash -c "source '$LIB'; cw_repo_hash")

TOPIC=$("$INIT" "v018 stale entry filter")
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"

assert_file_exists "$TD/_consult/troopers.txt" "troopers.txt written"
TROOPERS_BODY=$(grep -vE '^[[:space:]]*(#|$)' "$TD/_consult/troopers.txt")
ROW_COUNT=$(echo "$TROOPERS_BODY" | wc -l)
assert_eq "$ROW_COUNT" "2" "stale entry filtered, 2 valid providers remain"

echo "$TROOPERS_BODY" | grep -qE $'^codex\t'  || { echo "FAIL: codex row missing"  >&2; exit 1; }
echo "$TROOPERS_BODY" | grep -qE $'^claude\t' || { echo "FAIL: claude row missing" >&2; exit 1; }
echo "$TROOPERS_BODY" | grep -qE $'^gemini\t' && { echo "FAIL: gemini should be filtered" >&2; exit 1; } || true

pass "bin/consult-init.sh filters stale entries from providers-active.txt"
