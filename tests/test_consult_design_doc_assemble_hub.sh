#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/log.sh
source ../lib/state.sh
export CLAUDE_PLUGIN_ROOT="$(cd .. && pwd)"; PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT"
source ../lib/consult.sh

TMP=$(mktemp -d -t cw-asm-hub.XXXXXX); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/dd" "$TMP/_consult"
for k in architecture components data-flow error-handling acceptance-tests dag xrepo-deps; do
  case "$k" in
    dag) printf 'Step 1: A  base\n        depends: none\nStep 2: B  consume\n        depends: Step 1\n' > "$TMP/dd/$k.md" ;;
    xrepo-deps) printf '| Producer | Artifact | Consumer | Type |\n|---|---|---|---|\n| A | foo | B | internal |\n' > "$TMP/dd/$k.md" ;;
    acceptance-tests) printf -- '- **Step 1** [A] base\n  - Run: pytest\n  - Pass: exit 0\n\n- **Step 2** [B] consume\n  - Run: pytest\n  - Pass: exit 0\n' > "$TMP/dd/$k.md" ;;
    *) printf '## %s\n\nbody\n' "$k" > "$TMP/dd/$k.md" ;;
  esac
done
printf '## Agreed findings\n\n- claim 1\n' > "$TMP/_consult/synthesis.md"
printf 'hub/A\nhub/B\n' > "$TMP/_consult/targets.txt"

CW_TEST_DATE=2026-05-04 cw_consult_design_doc_assemble \
  "$TMP/dd" "$TMP/out.md" "Hub Topic" "" "$TMP/_consult/synthesis.md" "$TMP/_consult"

grep -q '^\*\*Target Hub(s):\*\* hub' "$TMP/out.md" || { echo "FAIL: hub header missing"; exit 1; }
grep -q '^\*\*Target Sub-Project(s):\*\* A, B' "$TMP/out.md" || { echo "FAIL: sub-project header missing"; exit 1; }
grep -q '^## Acceptance Tests' "$TMP/out.md" || { echo "FAIL: Acceptance Tests heading missing"; exit 1; }
grep -q '^## Execution DAG' "$TMP/out.md" || { echo "FAIL: DAG heading missing"; exit 1; }
grep -q '^## Cross-Repo Dependencies' "$TMP/out.md" || { echo "FAIL: Cross-Repo Dependencies missing"; exit 1; }
# Hub mode should NOT emit the legacy "Testing" heading
grep -q '^## Testing' "$TMP/out.md" && { echo "FAIL: legacy Testing should not appear in hub mode"; exit 1; } || true
pass "hub-mode assembly emits header pair + DAG + Cross-Repo Deps + Acceptance Tests"
