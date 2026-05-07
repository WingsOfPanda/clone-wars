#!/usr/bin/env bash
# tests/test_spec_directive_static_wiring.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

SPEC_MD=../commands/spec.md
[[ -f "$SPEC_MD" ]] || { echo "FAIL: $SPEC_MD missing" >&2; exit 1; }

grep -q 'bin/spec-init.sh'      "$SPEC_MD" || { echo "FAIL: directive missing bin/spec-init.sh reference" >&2; exit 1; }
grep -q 'bin/spec-assemble.sh'  "$SPEC_MD" || { echo "FAIL: directive missing bin/spec-assemble.sh reference" >&2; exit 1; }
! grep -q 'bin/spawn.sh'         "$SPEC_MD" || { echo "FAIL: /spec must NOT spawn troopers; spawn.sh referenced" >&2; exit 1; }
! grep -q 'consult-research-send' "$SPEC_MD" || { echo "FAIL: /spec must NOT dispatch research" >&2; exit 1; }
! grep -q 'consult-verify-send'   "$SPEC_MD" || { echo "FAIL: /spec must NOT dispatch verify" >&2; exit 1; }
! grep -q 'consult-drilldown'     "$SPEC_MD" || { echo "FAIL: /spec must NOT invoke drill (lives in /consult Step 8.4)" >&2; exit 1; }
grep -q 'cw_spec_resume_state' "$SPEC_MD" || { echo "FAIL: directive missing resume-state helper" >&2; exit 1; }
grep -q 'hub-mode.txt'           "$SPEC_MD" || { echo "FAIL: directive missing hub-mode detection" >&2; exit 1; }
grep -q 'SEED_PATH=.*ARGS_DIR' "$SPEC_MD" \
  || { echo "FAIL: directive missing SEED_PATH read-back from \$ARGS_DIR/spec.txt" >&2; exit 1; }

# Hub-mode wiring (lifted from old Step 8.5; lives in /spec now)
grep -q 'Execution DAG'         "$SPEC_MD" || { echo "FAIL: /spec must reference Execution DAG section" >&2; exit 1; }
grep -q 'Cross-Repo Dependencies' "$SPEC_MD" || { echo "FAIL: /spec must reference Cross-Repo Dependencies" >&2; exit 1; }
grep -q 'Acceptance Tests'      "$SPEC_MD" || { echo "FAIL: /spec must reference Acceptance Tests heading" >&2; exit 1; }

pass "commands/spec.md static wiring complete"
