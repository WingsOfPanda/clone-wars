#!/usr/bin/env bash
# tests/test_audit_parallel_safety_self.sh
# Self-test for tests/audit-parallel-safety.sh: stage a synthetic test
# directory containing one of each violation type; assert the audit
# catches all of them.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
AUDIT="$PLUGIN_ROOT/tests/audit-parallel-safety.sh"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

# Stage fixture: 1 clean test + 4 violators
cat > "$SANDBOX/test_clean.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"
TEST_WIN="cw-clean-$$-${RANDOM}"
EOF

cat > "$SANDBOX/test_v_tmp.sh" <<'EOF'
#!/usr/bin/env bash
cat > /tmp/items.txt <<EOI
hi
EOI
EOF

cat > "$SANDBOX/test_v_cw_home.sh" <<'EOF'
#!/usr/bin/env bash
CLONE_WARS_HOME=/tmp/cw-fixed bash cmd
EOF

cat > "$SANDBOX/test_v_tmux_fixed.sh" <<'EOF'
#!/usr/bin/env bash
TEST_WIN="cw-fixed-name"
EOF

cat > "$SANDBOX/test_v_cd_abs.sh" <<'EOF'
#!/usr/bin/env bash
cd /etc
EOF

chmod +x "$SANDBOX"/test_*.sh

# Run audit against the fixture dir; expect rc=1 + each violator named
out=$(AUDIT_TARGET_DIR="$SANDBOX" bash "$AUDIT" 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "audit fails on fixture dir with violators"
assert_contains "$out" "test_v_tmp.sh: fixed /tmp path write"      "catches fixed /tmp write"
assert_contains "$out" "test_v_cw_home.sh: CLONE_WARS_HOME not sandboxed" "catches unsandboxed CLONE_WARS_HOME"
assert_contains "$out" "test_v_tmux_fixed.sh: fixed tmux name"     "catches fixed tmux name"
assert_contains "$out" "test_v_cd_abs.sh: cd to absolute path"     "catches unsandboxed cd"
# Clean test must NOT appear
if echo "$out" | grep -q "test_clean.sh:"; then
  echo "FAIL: clean test should not be flagged" >&2
  echo "$out" >&2
  exit 1
fi
pass "1. audit catches the 4 violation types and ignores clean tests"

# Sanity: empty dir → exit 0
EMPTY=$(mktemp -d)
trap 'rm -rf "$SANDBOX" "$EMPTY"' EXIT
out2=$(AUDIT_TARGET_DIR="$EMPTY" bash "$AUDIT" 2>&1) && rc2=0 || rc2=$?
assert_eq "$rc2" "0" "empty dir audit passes"
pass "2. audit handles empty dir without crashing"

echo "test_audit_parallel_safety_self: 2 cases passed"
