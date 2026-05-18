#!/usr/bin/env bash
# tests/test_deep_research_format_sota_block.sh — v0.44.0 Lane A
# Locks: cw_deep_research_format_sota_block takes K=V pairs on stdin and
# emits a Markdown table with frontmatter block. ref_N rows beyond 7
# are silently ignored. Empty refs produce empty-table fallback.
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib/assert.sh
source lib/log.sh
source lib/deep-research.sh

# Case 1: full input with 3 refs
out=$(cw_deep_research_format_sota_block <<'EOF'
topic=optimize MNIST under 100k params
metric=accuracy
sweep_date=2026-05-18T09:42:11Z
queries=SOTA accuracy MNIST, MNIST under 100k params
ref_1=Depthwise CNN|99.84%|over by 60k params|https://example.org/a|Caps-Net variant
ref_2=Plain CNN|99.65%|fits (98k)|https://example.org/b|baseline reference
ref_3=Transformer|99.42%|over by 220k params|https://example.org/c|too large
EOF
)
echo "$out" | grep -qE '^# SOTA reference — optimize MNIST under 100k params$' \
  || { echo "FAIL: missing or wrong H1 header" >&2; echo "$out" >&2; exit 1; }
echo "$out" | grep -qE '^> \*\*Sweep date:\*\* 2026-05-18T09:42:11Z$' \
  || { echo "FAIL: missing sweep_date frontmatter" >&2; echo "$out" >&2; exit 1; }
echo "$out" | grep -qE '^> \*\*Optimizing for:\*\* accuracy$' \
  || { echo "FAIL: missing optimizing-for frontmatter" >&2; echo "$out" >&2; exit 1; }
echo "$out" | grep -qE '^> \*\*Queries fired:\*\* SOTA accuracy MNIST, MNIST under 100k params$' \
  || { echo "FAIL: missing queries frontmatter" >&2; echo "$out" >&2; exit 1; }
echo "$out" | grep -qE '^\| Approach family \| Best known \| Constraint compliance \| Source \| Notes \|$' \
  || { echo "FAIL: missing table header row" >&2; echo "$out" >&2; exit 1; }
row_count=$(echo "$out" | grep -cE '^\|.*https?://' || true)
[[ "$row_count" == "3" ]] \
  || { echo "FAIL: expected 3 data rows, got $row_count" >&2; echo "$out" >&2; exit 1; }
echo "$out" | grep -qE '^\| Depthwise CNN \| 99\.84% \| over by 60k params \| https://example\.org/a \| Caps-Net variant \|$' \
  || { echo "FAIL: row 1 not literal" >&2; echo "$out" >&2; exit 1; }
pass "1. full input with 3 refs renders header + frontmatter + 3-row table"

# Case 2: frontmatter only, no refs → empty-table fallback
out=$(cw_deep_research_format_sota_block <<'EOF'
topic=novel domain
metric=loss
sweep_date=2026-05-18T10:00:00Z
queries=none yielded usable results
EOF
)
echo "$out" | grep -qE '^# SOTA reference — novel domain$' \
  || { echo "FAIL: missing H1 in empty-refs case" >&2; echo "$out" >&2; exit 1; }
echo "$out" | grep -qE '^\| Approach family \|' \
  || { echo "FAIL: missing table header in empty-refs case" >&2; echo "$out" >&2; exit 1; }
row_count=$(echo "$out" | grep -cE '^\|.*https?://' || true)
[[ "$row_count" == "0" ]] \
  || { echo "FAIL: expected 0 data rows in empty case, got $row_count" >&2; echo "$out" >&2; exit 1; }
echo "$out" | grep -qE 'sweep returned no usable references|trooper-side web search remains available' \
  || { echo "FAIL: missing empty-table fallback note" >&2; echo "$out" >&2; exit 1; }
pass "2. frontmatter-only input renders empty-table fallback with note"

# Case 3: ref_N rows beyond 7 are silently ignored
out=$(cw_deep_research_format_sota_block <<'EOF'
topic=stress test
metric=score
sweep_date=2026-05-18T10:00:00Z
queries=q1
ref_1=A|1|fits|https://a|na
ref_2=B|2|fits|https://b|na
ref_3=C|3|fits|https://c|na
ref_4=D|4|fits|https://d|na
ref_5=E|5|fits|https://e|na
ref_6=F|6|fits|https://f|na
ref_7=G|7|fits|https://g|na
ref_8=H|8|fits|https://h|na
ref_9=I|9|fits|https://i|na
EOF
)
row_count=$(echo "$out" | grep -cE '^\| [A-Z] \|' || true)
[[ "$row_count" == "7" ]] \
  || { echo "FAIL: expected 7 data rows when 9 supplied, got $row_count" >&2; echo "$out" >&2; exit 1; }
if echo "$out" | grep -qE '^\| H \|'; then
  echo "FAIL: ref_8 leaked into output" >&2; echo "$out" >&2; exit 1
fi
pass "3. ref_N rows beyond 7 are silently dropped"

echo "test_deep_research_format_sota_block: 3 cases passed"
