#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/log.sh
source ../lib/state.sh
source ../lib/consult.sh

TMPROOT=$(mktemp -d -t cw-acc.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT
ART="$TMPROOT/_consult"; mkdir -p "$ART/design-doc"
printf '%s\n' "hub/A" "hub/B" | cw_consult_targets_persist "$ART"

cat > "$ART/design-doc/dag.md" <<'D'
Step 1: A  base
        depends: none
Step 2: B  consume
        depends: Step 1
D

# (a) Happy
cat > "$TMPROOT/t1.md" <<'T'
- **Step 1** [A] registry roundtrip
  - Setup: install
  - Run: pytest -k registry
  - Pass: exit 0

- **Step 2** [B] dispatcher routes
  - Run: pytest -k dispatcher
  - Pass: exit 0
T
cw_consult_acceptance_tests_validate "$ART" < "$TMPROOT/t1.md" || { echo "FAIL (a)"; exit 1; }
pass "(a) happy"

# (b) Missing **Step N** tag
cat > "$TMPROOT/t2.md" <<'T'
- [A] registry roundtrip
T
err=$(cw_consult_acceptance_tests_validate "$ART" < "$TMPROOT/t2.md" 2>&1) && { echo "FAIL (b)"; exit 1; } || true
grep -qi "missing \*\*Step" <<< "$err" || { echo "FAIL (b) msg: $err"; exit 1; }
pass "(b) missing **Step N** rejected"

# (c) Missing [<sub-project>] tag
cat > "$TMPROOT/t3.md" <<'T'
- **Step 1** registry roundtrip
T
err=$(cw_consult_acceptance_tests_validate "$ART" < "$TMPROOT/t3.md" 2>&1) && { echo "FAIL (c)"; exit 1; } || true
grep -qi "missing \[" <<< "$err" || { echo "FAIL (c)"; exit 1; }
pass "(c) missing [sub-project] rejected"

# (d) Tag references unknown Step
cat > "$TMPROOT/t4.md" <<'T'
- **Step 99** [A] something
T
err=$(cw_consult_acceptance_tests_validate "$ART" < "$TMPROOT/t4.md" 2>&1) && { echo "FAIL (d)"; exit 1; } || true
grep -qi "Step 99" <<< "$err" || { echo "FAIL (d)"; exit 1; }
pass "(d) unknown Step rejected"

# (e) Tag references unknown sub-project
cat > "$TMPROOT/t5.md" <<'T'
- **Step 1** [Z] something
T
err=$(cw_consult_acceptance_tests_validate "$ART" < "$TMPROOT/t5.md" 2>&1) && { echo "FAIL (e)"; exit 1; } || true
grep -qi "\\[Z\\]" <<< "$err" || { echo "FAIL (e)"; exit 1; }
pass "(e) unknown sub-project rejected"
