#!/usr/bin/env bash
# tests/test_run_one_atomicity.sh
# Self-test: spawn two run-one.sh instances concurrently with overlapping
# stdout; assert no block interleaving (every "=== X ===" header is
# followed contiguously by X's body and footer, before any other test's
# header appears).
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

# Stage two fake tests that emit many lines slowly enough to overlap.
# Each emits 20 lines with tiny sleeps so the two runs definitely
# overlap in time (otherwise atomicity is vacuously true).
cat > "$SANDBOX/test_alpha.sh" <<'EOF'
#!/usr/bin/env bash
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  echo "alpha line $i"
  sleep 0.01
done
EOF

cat > "$SANDBOX/test_beta.sh" <<'EOF'
#!/usr/bin/env bash
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  echo "beta line $i"
  sleep 0.01
done
EOF

chmod +x "$SANDBOX"/test_*.sh

# Run both concurrently through run-one.sh via xargs -P 2.
OUT="$SANDBOX/out.log"
printf '%s\n%s\n' "$SANDBOX/test_alpha.sh" "$SANDBOX/test_beta.sh" \
  | xargs -P 2 -I{} bash run-one.sh {} > "$OUT" 2>&1
rc=$?
assert_eq "$rc" "0" "both fixture tests run successfully"

# Find each header's line number
alpha_header=$(grep -n '^=== .*test_alpha.sh ===$' "$OUT" | cut -d: -f1)
beta_header=$(grep -n '^=== .*test_beta.sh ===$' "$OUT" | cut -d: -f1)
alpha_footer=$(grep -n '^  .*test_alpha.sh: ok$' "$OUT" | cut -d: -f1)
beta_footer=$(grep -n '^  .*test_beta.sh: ok$' "$OUT" | cut -d: -f1)

[[ -n "$alpha_header" && -n "$beta_header" && -n "$alpha_footer" && -n "$beta_footer" ]] \
  || { echo "FAIL: missing header/footer in output:" >&2; cat "$OUT" >&2; exit 1; }

# Atomicity check: alpha's footer comes before beta's header (or vice-versa);
# no test's range overlaps another's.
if (( alpha_header < beta_header )); then
  (( alpha_footer < beta_header )) \
    || { echo "FAIL: alpha block extends into beta region (interleaving):" >&2; cat "$OUT" >&2; exit 1; }
else
  (( beta_footer < alpha_header )) \
    || { echo "FAIL: beta block extends into alpha region (interleaving):" >&2; cat "$OUT" >&2; exit 1; }
fi
pass "1. run-one.sh blocks do not interleave under concurrent xargs -P"

# Sanity: each test's full body lines are present (20 of each = 40 total)
alpha_count=$(grep -c '^alpha line ' "$OUT")
beta_count=$(grep -c '^beta line ' "$OUT")
[[ "$alpha_count" == "20" ]] \
  || { echo "FAIL: alpha body has $alpha_count lines (expected 20)" >&2; cat "$OUT" >&2; exit 1; }
[[ "$beta_count" == "20" ]] \
  || { echo "FAIL: beta body has $beta_count lines (expected 20)" >&2; cat "$OUT" >&2; exit 1; }
pass "2. each test's full body is captured (40 lines total: 20 alpha + 20 beta)"

# FAIL exit propagation
cat > "$SANDBOX/test_fails.sh" <<'EOF'
#!/usr/bin/env bash
echo "this test fails"
exit 1
EOF
chmod +x "$SANDBOX/test_fails.sh"

set +e
bash run-one.sh "$SANDBOX/test_fails.sh" > "$SANDBOX/fail_out.log" 2>&1
fail_rc=$?
set -e
assert_eq "$fail_rc" "1" "FAIL exit propagates through run-one.sh"
grep -q ': FAIL$' "$SANDBOX/fail_out.log" \
  || { echo "FAIL: footer doesn't say FAIL" >&2; cat "$SANDBOX/fail_out.log" >&2; exit 1; }
pass "3. test failure → run-one.sh exits 1 with ': FAIL' footer"

echo "test_run_one_atomicity: 3 cases passed"
