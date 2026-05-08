#!/usr/bin/env bash
# tests/test_consult_directive_v016_static_wiring.sh
# v0.17.0 unified-consult directive static-wiring assertions.
#
# (Filename retained for git-blame continuity; v0.17.0 renumbered Step 0.4 →
# Step 1, Step 0.5 → Step 2, and rewrote the fast-path to write 6 deploy-audit
# draft sections + invoke bin/consult-walk-assemble.sh.)
#
# Asserts that commands/consult.md contains the load-bearing strings for:
#   - --use-force flag parsing
#   - Step 1 phrasing-trigger detection
#   - Step 2 Yoda fast-path block + 4-signal complexity check
#   - CW_PATH_LABEL env var propagation (Step 3 set, Step 11 consume)
#   - CW_SOURCE_LABEL env var propagation (Step 11)
#   - Fast-path drafts 6 deploy-audit sections + invokes consult-walk-assemble.sh
#
# Static-grep test only — does not exercise the directive runtime.
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

# 2. Step 1 phrasing-trigger detection (v0.17.0: was Step 0.4)
grep -q '^### Step 1 — Escalation phrasing-trigger' "$DIR" \
  || { echo "FAIL: Step 1 (phrasing-trigger) header missing"; exit 1; }
grep -q 'PHRASING_TRIGGERS' "$DIR" \
  || { echo "FAIL: PHRASING_TRIGGERS array missing"; exit 1; }
grep -q 'ESCALATE_FROM_PHRASING' "$DIR" \
  || { echo "FAIL: ESCALATE_FROM_PHRASING flag missing"; exit 1; }
# All five trigger keywords must be present in the array.
for trigger in 'deeply' 'verify' 'compare carefully' 'second opinion' 'consult thoroughly'; do
  grep -qF "\"$trigger\"" "$DIR" \
    || { echo "FAIL: phrasing trigger '$trigger' missing from PHRASING_TRIGGERS"; exit 1; }
done
pass "Step 1 phrasing-trigger detection wired (5 keywords present)"

# 3. Step 2 Yoda fast-path block (v0.17.0: was Step 0.5)
grep -q '^### Step 2 — 4-signal complexity check' "$DIR" \
  || { echo "FAIL: Step 2 (4-signal) header missing"; exit 1; }
grep -q 'fast-path' "$DIR" \
  || { echo "FAIL: 'fast-path' phrase missing"; exit 1; }
grep -q 'ESCALATE_FROM_SIGNALS' "$DIR" \
  || { echo "FAIL: ESCALATE_FROM_SIGNALS flag missing"; exit 1; }
pass "Step 2 fast-path block wired"

# 4. 4-signal complexity check — all four signals must be present
for signal in 'Conflicting evidence' 'Significant assumptions' 'High-stakes' 'Subjective tradeoffs'; do
  grep -qF "$signal" "$DIR" \
    || { echo "FAIL: 4-signal check missing '$signal'"; exit 1; }
done
pass "Step 2 4-signal complexity check (all 4 signals named)"

# 5. Fast-path design-doc drafts — invokes consult-walk-assemble.sh + drafts
#    the 6 deploy-audit sections to .draft/<section>.md.
grep -q 'bin/consult-walk-assemble.sh' "$DIR" \
  || { echo "FAIL: fast-path must invoke bin/consult-walk-assemble.sh"; exit 1; }
grep -q '\.draft' "$DIR" \
  || { echo "FAIL: fast-path must write to design-doc/.draft/<section>.md"; exit 1; }
# The 6 deploy-audit sections — fast-path must enumerate them as draft files.
for section in 'problem' 'goal' 'architecture' 'components' 'testing' 'success-criteria'; do
  grep -q "\$DRAFT_DIR/${section}\.md" "$DIR" \
    || { echo "FAIL: fast-path missing draft path for section '${section}'"; exit 1; }
done
pass "Step 2 fast-path drafts 6 deploy-audit sections + invokes walk-assemble"

# 6. CW_PATH_LABEL env var (set in Step 3, consumed by Step 11)
grep -q 'CW_PATH_LABEL' "$DIR" \
  || { echo "FAIL: CW_PATH_LABEL env var not set"; exit 1; }
grep -q 'escalated-from-flag' "$DIR" \
  || { echo "FAIL: escalated-from-flag label value missing"; exit 1; }
grep -q 'escalated-from-phrasing' "$DIR" \
  || { echo "FAIL: escalated-from-phrasing label value missing"; exit 1; }
grep -q 'escalated-from-signals' "$DIR" \
  || { echo "FAIL: escalated-from-signals label value missing"; exit 1; }
pass "CW_PATH_LABEL propagation wired (3 escalation source labels)"

# 7. CW_SOURCE_LABEL env var (set in Step 11 from N)
grep -q 'CW_SOURCE_LABEL' "$DIR" \
  || { echo "FAIL: CW_SOURCE_LABEL env var not set"; exit 1; }
grep -q 'rex+cody cross-verified (N=2)' "$DIR" \
  || { echo "FAIL: N=2 source-label value missing"; exit 1; }
grep -q 'rex+cody+bly cross-verified (N=3)' "$DIR" \
  || { echo "FAIL: N=3 source-label value missing"; exit 1; }
pass "CW_SOURCE_LABEL propagation wired (N=2 and N=3 variants)"

# 8. Step ordering sanity — Step 1 / Step 2 / Step 3 appear in that order.
order=$(grep -nE '^### Step (1|2|3) ' "$DIR" | awk -F: '{print $1}' | tr '\n' ' ')
read -r -a positions <<< "$order"
[[ ${#positions[@]} -eq 3 ]] \
  || { echo "FAIL: expected 3 step headers (1, 2, 3), found ${#positions[@]} — '$order'"; exit 1; }
[[ ${positions[0]} -lt ${positions[1]} && ${positions[1]} -lt ${positions[2]} ]] \
  || { echo "FAIL: step order corrupt: $order"; exit 1; }
pass "step ordering: 1 → 2 → 3 (in that order, no duplicates)"

# 9. Whitespace cleanliness — no triple-blank-line gap from the insertions.
triple_blanks=$(awk 'BEGIN{n=0} /^$/{n++; if(n>=3){print NR; exit}} /./{n=0}' "$DIR")
[[ -z "$triple_blanks" ]] \
  || { echo "FAIL: triple-blank-line gap at line $triple_blanks"; exit 1; }
pass "no triple-blank-line gaps"
