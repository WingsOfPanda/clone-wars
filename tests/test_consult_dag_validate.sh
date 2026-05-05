#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/log.sh
source ../lib/state.sh
source ../lib/consult.sh

TMPROOT=$(mktemp -d -t cw-dag.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT
ART="$TMPROOT/_consult"; mkdir -p "$ART"
printf '%s\n' "hub_a/ARS-TaskServe" "hub_a/ARS-LVMGateway" "hub_a/ARS-Gateway" \
  | cw_consult_targets_persist "$ART"

# (a) Happy linear
cat > "$TMPROOT/dag1.md" <<'D'
Step 1: ARS-TaskServe  registry.yaml field
        depends: none
Step 2: ARS-LVMGateway  consume new field
        depends: Step 1
Step 3: ARS-Gateway  update endpoint
        depends: Step 2
D
cw_consult_dag_validate "$ART" < "$TMPROOT/dag1.md" || { echo "FAIL (a)"; exit 1; }
pass "(a) happy linear"

# (b) Happy diamond
cat > "$TMPROOT/dag2.md" <<'D'
Step 1: ARS-TaskServe  base
        depends: none
Step 2: ARS-LVMGateway  branch left
        depends: Step 1
Step 3: ARS-Gateway  branch right
        depends: Step 1
Step 4: ARS-TaskServe  merge
        depends: Step 2, Step 3
D
cw_consult_dag_validate "$ART" < "$TMPROOT/dag2.md" || { echo "FAIL (b)"; exit 1; }
pass "(b) happy diamond"

# (c) Cycle 1->2->1
cat > "$TMPROOT/dag3.md" <<'D'
Step 1: ARS-TaskServe  thing
        depends: Step 2
Step 2: ARS-LVMGateway  other
        depends: Step 1
D
err=$(cw_consult_dag_validate "$ART" < "$TMPROOT/dag3.md" 2>&1) && { echo "FAIL (c) - should reject"; exit 1; } || true
grep -qi cycle <<< "$err" || { echo "FAIL (c) message: $err"; exit 1; }
pass "(c) cycle rejected"

# (d) Unknown ref
cat > "$TMPROOT/dag4.md" <<'D'
Step 1: ARS-TaskServe  base
        depends: none
Step 2: ARS-LVMGateway  consume
        depends: Step 99
D
err=$(cw_consult_dag_validate "$ART" < "$TMPROOT/dag4.md" 2>&1) && { echo "FAIL (d)"; exit 1; } || true
grep -q "Step 99" <<< "$err" || { echo "FAIL (d) msg: $err"; exit 1; }
pass "(d) unknown ref rejected"

# (e) Repo not in targets
cat > "$TMPROOT/dag5.md" <<'D'
Step 1: ARS-Foo  not in targets
        depends: none
D
err=$(cw_consult_dag_validate "$ART" < "$TMPROOT/dag5.md" 2>&1) && { echo "FAIL (e)"; exit 1; } || true
grep -q "ARS-Foo" <<< "$err" || { echo "FAIL (e) msg: $err"; exit 1; }
pass "(e) non-target repo rejected"

# (f) Free-form prose
cat > "$TMPROOT/dag6.md" <<'D'
Step 1: ARS-TaskServe  base
        depends: none

Phase 2 (sequential, depends on Phase 1)
D
err=$(cw_consult_dag_validate "$ART" < "$TMPROOT/dag6.md" 2>&1) && { echo "FAIL (f)"; exit 1; } || true
grep -qi 'free-form\|invalid' <<< "$err" || { echo "FAIL (f) msg: $err"; exit 1; }
pass "(f) free-form prose rejected"

# (g) Indented Step line
cat > "$TMPROOT/dag7.md" <<'D'
  Step 1: ARS-TaskServe  base
        depends: none
D
err=$(cw_consult_dag_validate "$ART" < "$TMPROOT/dag7.md" 2>&1) && { echo "FAIL (g)"; exit 1; } || true
grep -qi 'must not be indented' <<< "$err" || { echo "FAIL (g) msg: $err"; exit 1; }
pass "(g) indented Step line — specific error"

# (h) Empty depends value
cat > "$TMPROOT/dag8.md" <<'D'
Step 1: ARS-TaskServe  base
        depends:
D
err=$(cw_consult_dag_validate "$ART" < "$TMPROOT/dag8.md" 2>&1) && { echo "FAIL (h)"; exit 1; } || true
grep -qi 'depends value missing' <<< "$err" || { echo "FAIL (h) msg: $err"; exit 1; }
pass "(h) empty depends value — specific error"

# (i) Step line with no description
cat > "$TMPROOT/dag9.md" <<'D'
Step 1: ARS-TaskServe
        depends: none
D
err=$(cw_consult_dag_validate "$ART" < "$TMPROOT/dag9.md" 2>&1) && { echo "FAIL (i)"; exit 1; } || true
grep -qi 'missing description' <<< "$err" || { echo "FAIL (i) msg: $err"; exit 1; }
pass "(i) Step line missing description — specific error"
