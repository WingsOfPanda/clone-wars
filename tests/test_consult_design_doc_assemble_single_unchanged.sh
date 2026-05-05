#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/log.sh
source ../lib/state.sh
export CLAUDE_PLUGIN_ROOT="$(cd .. && pwd)"; PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT"
source ../lib/consult.sh

TMP=$(mktemp -d -t cw-asm-single.XXXXXX); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/dd" "$TMP/_consult"
for k in architecture components data-flow error-handling testing; do
  printf '## %s\n\nbody\n' "$k" > "$TMP/dd/$k.md"
done
printf '## Agreed findings\n\n- claim 1\n' > "$TMP/_consult/synthesis.md"

CW_TEST_DATE=2026-05-04 cw_consult_design_doc_assemble \
  "$TMP/dd" "$TMP/out.md" "Sample Topic" "" "$TMP/_consult/synthesis.md"

diff -u fixtures/v0.10-single-repo-design.md "$TMP/out.md" \
  || { echo "FAIL: single-repo assembly diverged from v0.10 baseline"; exit 1; }
pass "single-repo assembly byte-equal to v0.10 baseline"
