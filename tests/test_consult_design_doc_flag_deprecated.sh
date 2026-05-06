#!/usr/bin/env bash
# tests/test_consult_design_doc_flag_deprecated.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

DIR=../commands/consult.md

# v0.12 deprecation path: warning is present, walk-entry is gone.
grep -q 'deprecated as of v0.12.0'                 "$DIR" || { echo "FAIL: missing v0.12 deprecation notice" >&2; exit 1; }
grep -q 'Run /clone-wars:spec separately'          "$DIR" || { echo "FAIL: missing /spec migration hint" >&2; exit 1; }
! grep -q '^### Step 8\.5'                         "$DIR" || { echo "FAIL: Step 8.5 must be removed" >&2; exit 1; }
! grep -q 'cw_consult_design_doc_resume_state'     "$DIR" || { echo "FAIL: design-doc resume helper must not be used in /consult" >&2; exit 1; }
pass "/consult --design-doc deprecation wiring complete"
