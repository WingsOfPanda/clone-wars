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
# Hermeticity: ensure no-arg cw_opencode_permission_check calls (cases 1-4
# pass an explicit path so this is defensive) cannot pick up an ambient
# opencode.json from tests/.
cd "$TMP"

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

# === Case 4a: nested per-agent permission (false-positive regression) ===
# Before the {0,2} anchor fix, the deeply-nested "permission" key matched
# the loose ^\s* regex and yielded rc=0. Must be rc=1 now.
cat > "$TMP/nested.json" <<'EOF'
{
  "agents": {
    "rex": {
      "permission": "allow"
    }
  }
}
EOF
out=$(cw_opencode_permission_check "$TMP/nested.json" 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "rc when only nested per-agent permission key exists"
assert_contains "$out" "no top-level 'permission' key" "stderr says no top-level key"
pass "preflight: nested per-agent permission -> rc=1 (rejects deep-nested false positive)"

# === Case 4b: per-mode-only permission (false-positive regression) ===
# Same class of bug as 4a — opencode allows per-mode permission overrides
# under "mode": { "build": { "permission": "..." } }. Must NOT count as
# top-level allow.
cat > "$TMP/per-mode.json" <<'EOF'
{
  "mode": {
    "build": {
      "permission": "allow"
    }
  }
}
EOF
out=$(cw_opencode_permission_check "$TMP/per-mode.json" 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "rc when only per-mode permission key exists"
assert_contains "$out" "no top-level 'permission' key" "stderr says no top-level key"
pass "preflight: per-mode-only permission -> rc=1 (rejects per-mode false positive)"

# === Case 4c: mixed-case value "Allow" (charclass widening) ===
# Before [A-Za-z_]+, "Allow" fell through to the "no top-level permission"
# branch with a misleading stderr. Now it matches the string-form regex
# and the lowercase-only =~ "allow" check correctly returns rc=1 with
# the value-named stderr.
cat > "$TMP/mixedcase.json" <<'EOF'
{
  "permission": "Allow"
}
EOF
out=$(cw_opencode_permission_check "$TMP/mixedcase.json" 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "rc on mixed-case permission=Allow"
assert_contains "$out" "permission is 'Allow'" "stderr names the mixed-case value"
pass "preflight: permission=Allow -> rc=1, names value (charclass accepts mixed case)"

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

# === Case 6: medic.sh sources lib/opencode_preflight.sh cleanly ===
out=$( bash -c "source $PLUGIN_ROOT/lib/log.sh; source $PLUGIN_ROOT/lib/opencode_preflight.sh; type cw_opencode_permission_check >/dev/null && echo SOURCED" 2>&1)
assert_contains "$out" "SOURCED" "lib sources cleanly under set -uo pipefail"
pass "preflight: lib/opencode_preflight.sh sources cleanly"

# === Case 7: medic.sh emits WARN line for opencode.json missing permission ===
# Regression for the `if ! cmd; then rc=$?` bash-semantics bug that silently
# swallowed both rc=1 and rc=2 case-arms (v0.13.0 PR1 wiring; fixed in PR2).
# Stages a state root with opencode in contracts.yaml + a fake opencode
# binary on PATH + an opencode.json that has no `permission` key, then
# invokes bin/medic.sh and asserts the WARN line appears.
mkdir -p "$TMP/medic7/cw" "$TMP/medic7/repo" "$TMP/medic7/bin"
cp "$PLUGIN_ROOT/config/contracts.yaml" "$TMP/medic7/cw/contracts.yaml"
cat > "$TMP/medic7/repo/opencode.json" <<'EOF'
{ "model": "deepseek/deepseek-v4-pro" }
EOF
# Fake opencode binary: silent on --version, exits 0.
cat > "$TMP/medic7/bin/opencode" <<'EOF'
#!/usr/bin/env bash
echo "opencode 1.14.39"
exit 0
EOF
chmod +x "$TMP/medic7/bin/opencode"
out=$(
  CLONE_WARS_HOME="$TMP/medic7/cw" \
  PATH="$TMP/medic7/bin:$PATH" \
  HOME="$TMP/medic7/nohome" \
  bash -c "cd '$TMP/medic7/repo' && '$PLUGIN_ROOT/bin/medic.sh'" 2>&1
)
assert_contains "$out" "opencode auto-approve" "medic emits opencode preflight section"
assert_contains "$out" "no top-level 'permission' key" "medic prints the missing-key WARN"
pass "preflight: medic.sh emits WARN for opencode.json without permission key"

# === Case 8: medic.sh emits OK line when opencode.json has permission=allow ===
mkdir -p "$TMP/medic8/cw" "$TMP/medic8/repo" "$TMP/medic8/bin"
cp "$PLUGIN_ROOT/config/contracts.yaml" "$TMP/medic8/cw/contracts.yaml"
cat > "$TMP/medic8/repo/opencode.json" <<'EOF'
{
  "permission": "allow"
}
EOF
cat > "$TMP/medic8/bin/opencode" <<'EOF'
#!/usr/bin/env bash
echo "opencode 1.14.39"
exit 0
EOF
chmod +x "$TMP/medic8/bin/opencode"
out=$(
  CLONE_WARS_HOME="$TMP/medic8/cw" \
  PATH="$TMP/medic8/bin:$PATH" \
  HOME="$TMP/medic8/nohome" \
  bash -c "cd '$TMP/medic8/repo' && '$PLUGIN_ROOT/bin/medic.sh'" 2>&1
)
assert_contains "$out" "'permission: allow' detected" "medic prints the OK line"
pass "preflight: medic.sh emits OK when opencode.json has permission=allow"
