#!/usr/bin/env bash
# tests/test_medic_opencode_preflight.sh — v0.13.0 regression for opencode
# preflight helper. Drives lib/opencode_preflight.sh through 4 config states:
# missing, "ask", "allow", and object-form. Asserts the helper's stdout +
# return code in each.
set -euo pipefail
cd "$(dirname "$0")"
PLUGIN_ROOT=$(cd .. && pwd)
source lib/assert.sh
source "$PLUGIN_ROOT/lib/opencode_preflight.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# === Case 1: no config file at all ===
out=$(cw_opencode_permission_check "$TMP/missing.json" 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "rc on missing config"
assert_contains "$out" "no opencode.json found" "stderr message on missing"
pass "preflight: missing config -> rc=1, mentions 'no opencode.json found'"

# === Case 2: config with permission: ask (default) ===
cat > "$TMP/ask.json" <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "permission": "ask"
}
EOF
out=$(cw_opencode_permission_check "$TMP/ask.json" 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "rc on permission=ask"
assert_contains "$out" "permission is 'ask'" "stderr names the offending value"
pass "preflight: permission=ask -> rc=1, names value"

# === Case 3: config with permission: allow (auto-approve) ===
cat > "$TMP/allow.json" <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "permission": "allow"
}
EOF
out=$(cw_opencode_permission_check "$TMP/allow.json" 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "0" "rc on permission=allow"
pass "preflight: permission=allow -> rc=0 (clean)"

# === Case 4: config with permission as object — informational warn ===
cat > "$TMP/object.json" <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "permission": {
    "bash": "allow",
    "edit": "allow"
  }
}
EOF
out=$(cw_opencode_permission_check "$TMP/object.json" 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "2" "rc on permission object form"
assert_contains "$out" "object-form permission" "stderr mentions object form"
pass "preflight: object-form -> rc=2 (informational)"

# === Case 5: cw_opencode_config_path search order ===
# Project-local opencode.json wins over global.
mkdir -p "$TMP/repo" "$TMP/home/.config/opencode"
cat > "$TMP/repo/opencode.json"            <<<'{"permission":"allow"}'
cat > "$TMP/home/.config/opencode/opencode.json" <<<'{"permission":"ask"}'
HOME="$TMP/home" found=$(cd "$TMP/repo" && cw_opencode_config_path)
assert_eq "$found" "$TMP/repo/opencode.json" "project-local wins"
pass "preflight: project-local opencode.json takes precedence over user-global"

# Project-local missing -> falls through to user-global.
rm "$TMP/repo/opencode.json"
HOME="$TMP/home" found=$(cd "$TMP/repo" && cw_opencode_config_path)
assert_eq "$found" "$TMP/home/.config/opencode/opencode.json" "fallback to global"
pass "preflight: falls through to ~/.config/opencode/opencode.json when no project-local"

# Neither present -> empty + rc=1.
rm "$TMP/home/.config/opencode/opencode.json"
HOME="$TMP/home" out=$(cd "$TMP/repo" && cw_opencode_config_path) && rc=0 || rc=$?
assert_eq "$rc" "1" "rc when neither config exists"
assert_eq "$out" "" "empty stdout when no config"
pass "preflight: returns rc=1 + empty stdout when no config exists anywhere"
