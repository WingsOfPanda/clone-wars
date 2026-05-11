#!/usr/bin/env bash
# tests/test_meditate_confidence_gate.sh — verify the regex heuristics
# used in commands/meditate.md Step 5.5 work against fixture content.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
SANDBOX=$(mktemp -d -t cw-meditate-gate.XXXXXX)
trap 'rm -rf "$SANDBOX"' EXIT

# --- S1: top-approach extraction ---
cat > "$SANDBOX/draft.md" <<'EOF'
## Approaches
1. Approach Alpha — async batched scheduler
2. Approach Beta — sync per-request scheduler
3. Approach Gamma — adaptive hybrid
EOF
TOP=$(grep -m1 -oE '^[0-9]+\. [^—]+' "$SANDBOX/draft.md" \
  | head -n1 | sed 's/^[0-9]*\. //; s/ —.*//; s/ *$//')
[[ "$TOP" == "Approach Alpha" ]] \
  || { echo "FAIL: S1 top-approach extract got '$TOP' (expected 'Approach Alpha')" >&2; exit 1; }
pass "S1: top-approach name extracted correctly"

# --- S3: CONTESTED detection ---
echo "everything is fine" > "$SANDBOX/clean.md"
echo "some CONTESTED claim here" > "$SANDBOX/dirty.md"
grep -qi 'CONTESTED' "$SANDBOX/clean.md" && S3_CLEAN=false || S3_CLEAN=true
grep -qi 'CONTESTED' "$SANDBOX/dirty.md" && S3_DIRTY=false || S3_DIRTY=true
[[ "$S3_CLEAN" == "true" ]] || { echo "FAIL: S3 clean case got false" >&2; exit 1; }
[[ "$S3_DIRTY" == "false" ]] || { echo "FAIL: S3 dirty case got true" >&2; exit 1; }
pass "S3: CONTESTED marker detection correct"

# --- S5: uncertainty acknowledgment detection ---
cat > "$SANDBOX/findings-confident.md" <<'EOF'
- Always X holds.
- Always Y is fine.
EOF
cat > "$SANDBOX/findings-uncertain.md" <<'EOF'
- We are uncertain about edge case Z.
- Could not determine the rate.
EOF
grep -qiE 'uncertain|unclear|depends on|could not determine|not sure|gap in evidence' \
  "$SANDBOX/findings-confident.md" && S5_C=true || S5_C=false
grep -qiE 'uncertain|unclear|depends on|could not determine|not sure|gap in evidence' \
  "$SANDBOX/findings-uncertain.md" && S5_U=true || S5_U=false
[[ "$S5_C" == "false" ]] || { echo "FAIL: S5 confident case incorrectly passed" >&2; exit 1; }
[[ "$S5_U" == "true" ]] || { echo "FAIL: S5 uncertain case incorrectly failed" >&2; exit 1; }
pass "S5: uncertainty-acknowledgment detection correct"

pass "3 confidence-gate heuristics verified against fixtures"
