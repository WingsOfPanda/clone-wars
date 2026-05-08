#!/usr/bin/env bash
# tests/test_consult_directive_v016_static_wiring.sh
# v0.16.0 unified-consult directive static-wiring assertions.
#
# Asserts that commands/consult.md contains the load-bearing strings for:
#   - --use-force flag parsing (Task 5)
#   - Step 0.4 phrasing-trigger detection
#   - Step 0.5 Yoda fast-path block + 4-signal complexity check
#   - CW_PATH_LABEL env var propagation (Step 1)
#   - CW_SOURCE_LABEL env var propagation (Step 8)
#   - cw_consult_design_doc_canonical_path call (fast-path inline write)
#
# This is a static-grep test — it does not exercise the directive runtime;
# it only verifies the directive text was wired up correctly. Pairs with
# test_consult_use_force_flag_parse.sh (lib helper unit test) and
# test_consult_synthesis.sh (CW_*_LABEL consumer tests).
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

DIR=../commands/consult.md
[[ -f "$DIR" ]] || { echo "FAIL: $DIR not found"; exit 1; }

# 1. --use-force flag wiring
grep -q 'cw_consult_parse_use_force_flag' "$DIR" \
  || { echo "FAIL: cw_consult_parse_use_force_flag helper not invoked"; exit 1; }
grep -q 'USE_FORCE=' "$DIR" \
  || { echo "FAIL: USE_FORCE variable not set"; exit 1; }
grep -q '\-\-use-force' "$DIR" \
  || { echo "FAIL: --use-force flag mention missing"; exit 1; }
pass "--use-force flag parsing wired"

# 2. Step 0.4 phrasing-trigger detection
grep -q '^### Step 0\.4' "$DIR" \
  || { echo "FAIL: Step 0.4 header missing"; exit 1; }
grep -q 'PHRASING_TRIGGERS' "$DIR" \
  || { echo "FAIL: PHRASING_TRIGGERS array missing"; exit 1; }
grep -q 'ESCALATE_FROM_PHRASING' "$DIR" \
  || { echo "FAIL: ESCALATE_FROM_PHRASING flag missing"; exit 1; }
# All five trigger keywords must be present in the array.
for trigger in 'deeply' 'verify' 'compare carefully' 'second opinion' 'consult thoroughly'; do
  grep -qF "\"$trigger\"" "$DIR" \
    || { echo "FAIL: phrasing trigger '$trigger' missing from PHRASING_TRIGGERS"; exit 1; }
done
pass "Step 0.4 phrasing-trigger detection wired (5 keywords present)"

# 3. Step 0.5 Yoda fast-path block
grep -q '^### Step 0\.5' "$DIR" \
  || { echo "FAIL: Step 0.5 header missing"; exit 1; }
grep -q 'Yoda fast-path' "$DIR" \
  || { echo "FAIL: 'Yoda fast-path' phrase missing"; exit 1; }
grep -q 'ESCALATE_FROM_SIGNALS' "$DIR" \
  || { echo "FAIL: ESCALATE_FROM_SIGNALS flag missing"; exit 1; }
pass "Step 0.5 fast-path block wired"

# 4. 4-signal complexity check — all four signals must be present
for signal in 'Conflicting evidence' 'Significant assumptions' 'High-stakes' 'Subjective tradeoffs'; do
  grep -qF "$signal" "$DIR" \
    || { echo "FAIL: 4-signal check missing '$signal'"; exit 1; }
done
pass "Step 0.5 4-signal complexity check (all 4 signals named)"

# 5. Fast-path design-doc inline write — canonical path helper + 6 sections
grep -q 'cw_consult_design_doc_canonical_path' "$DIR" \
  || { echo "FAIL: canonical-path helper not invoked in fast-path"; exit 1; }
grep -q 'Master Yoda (single-source)' "$DIR" \
  || { echo "FAIL: 'Master Yoda (single-source)' trust-label header missing"; exit 1; }
grep -q '\*\*Path:\*\* fast' "$DIR" \
  || { echo "FAIL: 'Path: fast' trust-label line missing"; exit 1; }
# The 6 rigid sections — directive must enumerate them as guidance for Yoda.
for section in 'Summary' 'Findings' 'Tradeoffs' 'Recommendation' 'Open Questions' 'Sources'; do
  grep -q "\\*\\*${section}\\*\\*" "$DIR" \
    || { echo "FAIL: design-doc section '${section}' not enumerated"; exit 1; }
done
pass "Step 0.5 fast-path inline write wired (canonical-path + 6 sections)"

# 6. CW_PATH_LABEL env var (set in Step 1, consumed by Step 8)
grep -q 'CW_PATH_LABEL' "$DIR" \
  || { echo "FAIL: CW_PATH_LABEL env var not set"; exit 1; }
grep -q 'escalated-from-flag' "$DIR" \
  || { echo "FAIL: escalated-from-flag label value missing"; exit 1; }
grep -q 'escalated-from-phrasing' "$DIR" \
  || { echo "FAIL: escalated-from-phrasing label value missing"; exit 1; }
grep -q 'escalated-from-signals' "$DIR" \
  || { echo "FAIL: escalated-from-signals label value missing"; exit 1; }
pass "CW_PATH_LABEL propagation wired (3 escalation source labels)"

# 7. CW_SOURCE_LABEL env var (set in Step 8 from N)
grep -q 'CW_SOURCE_LABEL' "$DIR" \
  || { echo "FAIL: CW_SOURCE_LABEL env var not set"; exit 1; }
grep -q 'rex+cody cross-verified (N=2)' "$DIR" \
  || { echo "FAIL: N=2 source-label value missing"; exit 1; }
grep -q 'rex+cody+bly cross-verified (N=3)' "$DIR" \
  || { echo "FAIL: N=3 source-label value missing"; exit 1; }
pass "CW_SOURCE_LABEL propagation wired (N=2 and N=3 variants)"

# 8. Step ordering sanity — Step 0.4 / 0.5 / 1 appear in that order, exactly once each.
order=$(grep -n '^### Step \(0\.4\|0\.5\|1 \)' "$DIR" | awk -F: '{print $1}' | tr '\n' ' ')
read -r -a positions <<< "$order"
[[ ${#positions[@]} -eq 3 ]] \
  || { echo "FAIL: expected 3 step headers (0.4, 0.5, 1), found ${#positions[@]} — '$order'"; exit 1; }
[[ ${positions[0]} -lt ${positions[1]} && ${positions[1]} -lt ${positions[2]} ]] \
  || { echo "FAIL: step order corrupt: $order"; exit 1; }
pass "step ordering: 0.4 → 0.5 → 1 (in that order, no duplicates)"

# 9. Whitespace cleanliness — no triple-blank-line gap from the insertions.
triple_blanks=$(awk 'BEGIN{n=0} /^$/{n++; if(n>=3){print NR; exit}} /./{n=0}' "$DIR")
[[ -z "$triple_blanks" ]] \
  || { echo "FAIL: triple-blank-line gap at line $triple_blanks"; exit 1; }
pass "no triple-blank-line gaps"
