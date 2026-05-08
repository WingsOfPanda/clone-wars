#!/usr/bin/env bash
# tests/test_consult_design_doc_flag_deprecated.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

DIR=../commands/consult.md

# v0.17 obsolete path: --design-doc flag is silently ignored (no /spec
# migration hint anymore — /spec was removed).
grep -q 'obsolete as of v0.17.0'                "$DIR" || { echo "FAIL: missing v0.17 obsolete notice" >&2; exit 1; }
grep -q '/clone-wars:spec was removed'          "$DIR" || { echo "FAIL: missing /spec removal hint" >&2; exit 1; }
! grep -q '^### Step 8\.5'                      "$DIR" || { echo "FAIL: Step 8.5 must be removed" >&2; exit 1; }
! grep -q 'cw_consult_design_doc_resume_state'  "$DIR" || { echo "FAIL: design-doc resume helper must not be used in /consult" >&2; exit 1; }
pass "/consult --design-doc obsolete wiring updated for v0.17"
