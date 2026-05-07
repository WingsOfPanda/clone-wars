#!/usr/bin/env bash
# tests/test_consult_3trooper_adjudicate.sh
#
# v0.15.0 Task 7: 5-tier adjudicate output for N=3.
#
# Sections (in order):
#   ## Consensus findings (all troopers)   ← from consensus.txt
#   ## Cross-verified                      ← all required verifiers AGREE
#   ## Contested                           ← any DISPUTE among AGREE, OR all UNCERTAIN
#   ## Refuted                             ← all required verifiers DISPUTE
#   ## - PENDING:                          ← any UNCERTAIN with mixed signal
#
# Decision rules (K = number of required verifiers):
#   All K AGREE                                  → CROSS-VERIFIED
#   All K DISPUTE                                → REFUTED
#   All K UNCERTAIN                              → CONTESTED
#   Any DISPUTE + any AGREE (no UNCERTAIN)       → CONTESTED
#   Any UNCERTAIN + any AGREE/DISPUTE            → PENDING
#
# For each (claim category × verdict combo) below, we stage:
#   - troopers.txt (TSV: provider<TAB>commander)
#   - bucket files (consensus, single-only, pair-only)
#   - verify.md per trooper (with verdicts under ## Verdicts)
# then call cw_consult_write_adjudicated <art_dir> <out> and assert the
# claim ends up in the right section.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/state.sh
source ../lib/ipc.sh
source ../lib/consult.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')

# ---------- helper: stage a complete N=3 art_dir for one fixture run ----------
# stage_n3 <topic> — writes troopers.txt + 7 empty bucket files + empty
# per-trooper verify.md skeletons. Caller fills bucket files + verdicts.
stage_n3() {
  local topic="$1"
  local td="$CLONE_WARS_HOME/state/$RH/$topic"
  local art="$td/_consult"
  mkdir -p "$art" "$td/rex-codex" "$td/cody-claude" "$td/bly-opencode"
  printf 'codex\trex\nclaude\tcody\nopencode\tbly\n' > "$art/troopers.txt"

  # Empty bucket files (caller appends what it needs).
  : > "$art/consensus.txt"
  : > "$art/rex+cody_only.txt"
  : > "$art/rex+bly_only.txt"
  : > "$art/cody+bly_only.txt"
  : > "$art/rex_only_items.txt"
  : > "$art/cody_only_items.txt"
  : > "$art/bly_only_items.txt"

  # Empty verify.md skeletons.
  for trooper_dir in "$td/rex-codex" "$td/cody-claude" "$td/bly-opencode"; do
    cat > "$trooper_dir/verify.md" <<'MD'
# Verify
## Verdicts
MD
  done

  # VS=ok state files (so Not-verified section stays empty in N=2 path; not
  # consulted by N=3 path but written for completeness).
  cat > "$art/verify-rex.txt"  <<'EOF'
OFFSET=0
VS=ok
EOF
  cat > "$art/verify-cody.txt" <<'EOF'
OFFSET=0
VS=ok
EOF
  cat > "$art/verify-bly.txt"  <<'EOF'
OFFSET=0
VS=ok
EOF

  echo "$art"
}

# add_verdict <trooper-verify-md> <N> <TAG> <cite> <text>
add_verdict() {
  local file="$1" n="$2" tag="$3" cite="$4" text="$5"
  printf '%s. %s [%s] %s\n' "$n" "$tag" "$cite" "$text" >> "$file"
  printf '   evidence for %s\n' "$cite" >> "$file"
}

# section_lines <draft> <section-heading-pattern>
# Print the lines BETWEEN the matching `## ...` heading and the next `## `.
section_lines() {
  local draft="$1" hdr="$2"
  awk -v hdr="$hdr" '
    $0 ~ "^## " hdr { f=1; next }
    f && /^## /      { f=0 }
    f { print }
  ' "$draft"
}

# ---------- Test 1: consensus claim → CONSENSUS section ----------
TOPIC=consult-fixture-3adj-consensus
ART=$(stage_n3 "$TOPIC")
echo '[src/c.py:3] consensus claim C' > "$ART/consensus.txt"

cw_consult_write_adjudicated "$ART" "$ART/adjudicated-draft.md"
DRAFT="$ART/adjudicated-draft.md"
[[ -f "$DRAFT" ]] || { echo "FAIL: draft missing" >&2; exit 1; }
grep -q '^## Consensus findings' "$DRAFT" \
  || { echo "FAIL: consensus section header missing" >&2; cat "$DRAFT" >&2; exit 1; }
section_lines "$DRAFT" "Consensus findings" | grep -q 'consensus claim C' \
  || { echo "FAIL: consensus claim not in Consensus section" >&2; cat "$DRAFT" >&2; exit 1; }
pass "consensus claim → CONSENSUS section"

# ---------- Test 2: 1-of-3 (rex_only) with both verifiers AGREE → CROSS-VERIFIED ----------
TOPIC=consult-fixture-3adj-x-agree
ART=$(stage_n3 "$TOPIC")
echo '[src/a.py:1] rex_only A' > "$ART/rex_only_items.txt"
TD=$(dirname "$ART")
add_verdict "$TD/cody-claude/verify.md" 1 AGREE 'src/a.py:1' 'rex_only A'
add_verdict "$TD/bly-opencode/verify.md" 1 AGREE 'src/a.py:1' 'rex_only A'

cw_consult_write_adjudicated "$ART" "$ART/adjudicated-draft.md"
section_lines "$ART/adjudicated-draft.md" "Cross-verified" | grep -q 'rex_only A' \
  || { echo "FAIL: rex_only with cody+bly AGREE not in Cross-verified" >&2; cat "$ART/adjudicated-draft.md" >&2; exit 1; }
pass "1-of-3 rex_only + both AGREE → CROSS-VERIFIED"

# ---------- Test 3: 1-of-3 (rex_only) with split (AGREE/DISPUTE) → CONTESTED ----------
TOPIC=consult-fixture-3adj-x-split
ART=$(stage_n3 "$TOPIC")
echo '[src/a.py:1] rex_only split' > "$ART/rex_only_items.txt"
TD=$(dirname "$ART")
add_verdict "$TD/cody-claude/verify.md" 1 AGREE 'src/a.py:1' 'rex_only split'
add_verdict "$TD/bly-opencode/verify.md" 1 DISPUTE 'src/a.py:1' 'rex_only split'

cw_consult_write_adjudicated "$ART" "$ART/adjudicated-draft.md"
section_lines "$ART/adjudicated-draft.md" "Contested" | grep -q 'rex_only split' \
  || { echo "FAIL: rex_only with split AGREE/DISPUTE not in Contested" >&2; cat "$ART/adjudicated-draft.md" >&2; exit 1; }
pass "1-of-3 rex_only + AGREE/DISPUTE → CONTESTED"

# ---------- Test 4: 1-of-3 (rex_only) with both DISPUTE → REFUTED ----------
TOPIC=consult-fixture-3adj-x-refute
ART=$(stage_n3 "$TOPIC")
echo '[src/a.py:1] rex_only refuted' > "$ART/rex_only_items.txt"
TD=$(dirname "$ART")
add_verdict "$TD/cody-claude/verify.md" 1 DISPUTE 'src/a.py:1' 'rex_only refuted'
add_verdict "$TD/bly-opencode/verify.md" 1 DISPUTE 'src/a.py:1' 'rex_only refuted'

cw_consult_write_adjudicated "$ART" "$ART/adjudicated-draft.md"
section_lines "$ART/adjudicated-draft.md" "Refuted" | grep -q 'rex_only refuted' \
  || { echo "FAIL: rex_only with both DISPUTE not in Refuted" >&2; cat "$ART/adjudicated-draft.md" >&2; exit 1; }
pass "1-of-3 rex_only + both DISPUTE → REFUTED"

# ---------- Test 5: 1-of-3 (rex_only) with cody=AGREE bly=UNCERTAIN → PENDING ----------
TOPIC=consult-fixture-3adj-x-pending
ART=$(stage_n3 "$TOPIC")
echo '[src/a.py:1] rex_only pending' > "$ART/rex_only_items.txt"
TD=$(dirname "$ART")
add_verdict "$TD/cody-claude/verify.md" 1 AGREE 'src/a.py:1' 'rex_only pending'
add_verdict "$TD/bly-opencode/verify.md" 1 UNCERTAIN 'src/a.py:1' 'rex_only pending'

cw_consult_write_adjudicated "$ART" "$ART/adjudicated-draft.md"
section_lines "$ART/adjudicated-draft.md" "- PENDING:" | grep -q 'rex_only pending' \
  || awk '/^## - PENDING:/{f=1; next} /^## /{f=0} f' "$ART/adjudicated-draft.md" | grep -q 'rex_only pending' \
  || { echo "FAIL: rex_only with AGREE+UNCERTAIN not in PENDING" >&2; cat "$ART/adjudicated-draft.md" >&2; exit 1; }
pass "1-of-3 rex_only + AGREE+UNCERTAIN → PENDING"

# ---------- Test 6: 2-of-3 (rex+cody) with bly=AGREE → CROSS-VERIFIED ----------
TOPIC=consult-fixture-3adj-pair-agree
ART=$(stage_n3 "$TOPIC")
echo '[src/b.py:2] rex+cody agree' > "$ART/rex+cody_only.txt"
TD=$(dirname "$ART")
add_verdict "$TD/bly-opencode/verify.md" 1 AGREE 'src/b.py:2' 'rex+cody agree'

cw_consult_write_adjudicated "$ART" "$ART/adjudicated-draft.md"
section_lines "$ART/adjudicated-draft.md" "Cross-verified" | grep -q 'rex+cody agree' \
  || { echo "FAIL: pair rex+cody with bly AGREE not in Cross-verified" >&2; cat "$ART/adjudicated-draft.md" >&2; exit 1; }
pass "2-of-3 rex+cody + bly AGREE → CROSS-VERIFIED"

# ---------- Test 7: 2-of-3 (rex+cody) with bly=DISPUTE → CONTESTED ----------
TOPIC=consult-fixture-3adj-pair-contest
ART=$(stage_n3 "$TOPIC")
echo '[src/b.py:2] rex+cody contest' > "$ART/rex+cody_only.txt"
TD=$(dirname "$ART")
add_verdict "$TD/bly-opencode/verify.md" 1 DISPUTE 'src/b.py:2' 'rex+cody contest'

cw_consult_write_adjudicated "$ART" "$ART/adjudicated-draft.md"
# Single verifier DISPUTE on a pair: that's "all K=1 verifiers DISPUTE" → REFUTED by rule.
# But spec says "2-of-3 (rex+cody) with bly=DISPUTE → CONTESTED" — this is the
# documented decision rule (a 2-trooper consensus disputed by the 3rd is
# contested, not refuted, because 2 troopers' research backs the claim).
# To honor this we override: when the claim is held by >=2 troopers and the
# remaining verifier disputes, classify as CONTESTED.
section_lines "$ART/adjudicated-draft.md" "Contested" | grep -q 'rex+cody contest' \
  || { echo "FAIL: pair rex+cody with bly DISPUTE not in Contested" >&2; cat "$ART/adjudicated-draft.md" >&2; exit 1; }
pass "2-of-3 rex+cody + bly DISPUTE → CONTESTED"

# ---------- Test 8: 2-of-3 (rex+cody) with bly=UNCERTAIN → PENDING ----------
TOPIC=consult-fixture-3adj-pair-pending
ART=$(stage_n3 "$TOPIC")
echo '[src/b.py:2] rex+cody pending' > "$ART/rex+cody_only.txt"
TD=$(dirname "$ART")
add_verdict "$TD/bly-opencode/verify.md" 1 UNCERTAIN 'src/b.py:2' 'rex+cody pending'

cw_consult_write_adjudicated "$ART" "$ART/adjudicated-draft.md"
# A 2-trooper claim disputed only by an UNCERTAIN signal is PENDING — Yoda
# must read the source to break the tie. (All-UNCERTAIN with no AGREE/DISPUTE
# *for single-trooper claims* maps to CONTESTED; for pair claims with K=1
# UNCERTAIN verifier, the 2 owners' implicit AGREE means the situation is
# AGREE+UNCERTAIN → PENDING, which is what the spec table requires.)
awk '/^## - PENDING:/{f=1; next} /^## /{f=0} f' "$ART/adjudicated-draft.md" | grep -q 'rex+cody pending' \
  || { echo "FAIL: pair rex+cody with bly UNCERTAIN not in PENDING" >&2; cat "$ART/adjudicated-draft.md" >&2; exit 1; }
pass "2-of-3 rex+cody + bly UNCERTAIN → PENDING"

# ---------- Test 9: section ORDER (Consensus → Cross-verified → Contested → Refuted → PENDING) ----------
TOPIC=consult-fixture-3adj-order
ART=$(stage_n3 "$TOPIC")
echo '[src/c.py:3] order consensus' > "$ART/consensus.txt"
echo '[src/x.py:1] order cv'        > "$ART/rex_only_items.txt"
TD=$(dirname "$ART")
add_verdict "$TD/cody-claude/verify.md" 1 AGREE 'src/x.py:1' 'order cv'
add_verdict "$TD/bly-opencode/verify.md" 1 AGREE 'src/x.py:1' 'order cv'

cw_consult_write_adjudicated "$ART" "$ART/adjudicated-draft.md"
ORDER=$(grep -n '^## ' "$ART/adjudicated-draft.md" | awk -F: '{print $2}' | tr '\n' '|')
case "$ORDER" in
  *"Consensus findings"*"Cross-verified"*"Contested"*"Refuted"*)
    pass "section order: Consensus → Cross-verified → Contested → Refuted → PENDING"
    ;;
  *)
    echo "FAIL: section order wrong: $ORDER" >&2
    cat "$ART/adjudicated-draft.md" >&2
    exit 1
    ;;
esac

# ---------- Test 10: source-set annotation includes contributor list ----------
TOPIC=consult-fixture-3adj-srcset
ART=$(stage_n3 "$TOPIC")
echo '[src/x.py:1] srcset claim' > "$ART/rex_only_items.txt"
TD=$(dirname "$ART")
add_verdict "$TD/cody-claude/verify.md" 1 AGREE 'src/x.py:1' 'srcset claim'
add_verdict "$TD/bly-opencode/verify.md" 1 AGREE 'src/x.py:1' 'srcset claim'

cw_consult_write_adjudicated "$ART" "$ART/adjudicated-draft.md"
# Annotation must mention the source set: rex_only with both AGREEs.
LINE=$(section_lines "$ART/adjudicated-draft.md" "Cross-verified" | grep 'srcset claim' || true)
[[ -n "$LINE" ]] \
  || { echo "FAIL: srcset claim not found in Cross-verified" >&2; cat "$ART/adjudicated-draft.md" >&2; exit 1; }
case "$LINE" in
  *rex*) ;;
  *) echo "FAIL: source-set annotation missing 'rex' contributor: $LINE" >&2; exit 1 ;;
esac
pass "source-set annotation includes contributor name"

echo "tests/test_consult_3trooper_adjudicate.sh: ok"
