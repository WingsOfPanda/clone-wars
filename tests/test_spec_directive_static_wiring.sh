#!/usr/bin/env bash
# tests/test_spec_directive_static_wiring.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

DIR=../commands/spec.md
[[ -f "$DIR" ]] || { echo "FAIL: $DIR missing" >&2; exit 1; }

grep -q 'bin/spec-init.sh'      "$DIR" || { echo "FAIL: directive missing bin/spec-init.sh reference" >&2; exit 1; }
grep -q 'bin/spec-assemble.sh'  "$DIR" || { echo "FAIL: directive missing bin/spec-assemble.sh reference" >&2; exit 1; }
! grep -q 'bin/spawn.sh'         "$DIR" || { echo "FAIL: /spec must NOT spawn troopers; spawn.sh referenced" >&2; exit 1; }
! grep -q 'consult-research-send' "$DIR" || { echo "FAIL: /spec must NOT dispatch research" >&2; exit 1; }
! grep -q 'consult-verify-send'   "$DIR" || { echo "FAIL: /spec must NOT dispatch verify" >&2; exit 1; }
! grep -q 'consult-drilldown'     "$DIR" || { echo "FAIL: /spec must NOT invoke drill (lives in /consult Step 8.4)" >&2; exit 1; }
grep -q 'cw_consult_design_doc_resume_state' "$DIR" || { echo "FAIL: directive missing resume-state helper" >&2; exit 1; }
grep -q 'hub-mode.txt'           "$DIR" || { echo "FAIL: directive missing hub-mode detection" >&2; exit 1; }
pass "commands/spec.md static wiring complete"
