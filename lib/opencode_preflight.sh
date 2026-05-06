# lib/opencode_preflight.sh — preflight check for opencode auto-approve config.
#
# Pure-bash, no jq/python deps. Detects the top-level "permission" key in
# opencode.json. The object form ({"permission":{...}}) is acknowledged but
# not introspected — return code 2 signals "informational only, verify
# manually". Sourced by bin/medic.sh and tests/test_medic_opencode_preflight.sh.
#
# Exported functions:
#   cw_opencode_config_path        -> stdout: path to effective opencode.json
#                                     (project-local first, then user-global)
#                                     rc=0 found, rc=1 none exist
#   cw_opencode_permission_check   -> stdout: nothing on success
#                                     stderr: warn line on non-allow
#                                     rc=0 permission=allow (clean)
#                                     rc=1 missing config OR permission!=allow string
#                                     rc=2 object form (informational warn)

cw_opencode_config_path() {
  local project_cfg="$PWD/opencode.json"
  local global_cfg="${HOME}/.config/opencode/opencode.json"
  if [[ -f "$project_cfg" ]]; then
    printf '%s\n' "$project_cfg"
    return 0
  fi
  if [[ -f "$global_cfg" ]]; then
    printf '%s\n' "$global_cfg"
    return 0
  fi
  return 1
}

cw_opencode_permission_check() {
  local cfg="${1:-}"
  if [[ -z "$cfg" ]]; then
    cfg=$(cw_opencode_config_path) || cfg=""
  fi
  if [[ -z "$cfg" || ! -f "$cfg" ]]; then
    echo "no opencode.json found at \$PWD/opencode.json or \$HOME/.config/opencode/opencode.json" >&2
    return 1
  fi
  # Top-level "permission": "<value>" — string form. Object form is matched
  # by the object-detector below.
  local string_match
  string_match=$(grep -E '^\s*"permission"\s*:\s*"[a-z]+"' "$cfg" 2>/dev/null | head -1)
  if [[ -n "$string_match" ]]; then
    if [[ "$string_match" =~ \"permission\"[[:space:]]*:[[:space:]]*\"allow\" ]]; then
      return 0
    fi
    # ask, deny, or any other string value
    local val
    val=$(printf '%s' "$string_match" | sed -E 's/.*"permission"[[:space:]]*:[[:space:]]*"([a-z]+)".*/\1/')
    echo "opencode.json: permission is '$val' (need 'allow' for trooper auto-approve)" >&2
    echo "  config: $cfg" >&2
    return 1
  fi
  # Object form: "permission": { ... }
  if grep -qE '^\s*"permission"\s*:\s*\{' "$cfg" 2>/dev/null; then
    echo "opencode.json: object-form permission detected; medic does not introspect per-tool keys" >&2
    echo "  config: $cfg — verify all relevant tools (bash/edit/...) are 'allow' manually" >&2
    return 2
  fi
  echo "opencode.json: no top-level 'permission' key (defaults to 'ask')" >&2
  echo "  config: $cfg" >&2
  return 1
}
