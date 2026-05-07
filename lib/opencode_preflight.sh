# lib/opencode_preflight.sh — preflight check for opencode auto-approve config.
#
# Pure-bash, no jq/python deps. Detects the top-level "permission" key in
# opencode.json. The object form ({"permission":{...}}) is acknowledged but
# not introspected — return code 2 signals "informational only, verify
# manually". Sourced by bin/medic.sh and tests/test_medic_opencode_preflight.sh.
#
# Detection assumes pretty-printed JSON (the canonical opencode formatter
# output). The regex anchor allows zero or two leading spaces before
# "permission" — matches both column-0 and canonical 2-space top-level
# indent, but rejects 4+ space deep nesting (per-mode/per-agent overrides).
# Minified single-line configs (e.g. {"a":{"permission":"allow"}} on one
# line) require running through `jq .` or similar before this check.
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
  local lead='^[[:space:]]{0,2}"permission"[[:space:]]*:[[:space:]]*'
  local string_match
  string_match=$(grep -E "${lead}\"[A-Za-z_]+\"" "$cfg" 2>/dev/null | head -1)
  if [[ -n "$string_match" ]]; then
    if [[ "$string_match" =~ \"permission\"[[:space:]]*:[[:space:]]*\"allow\" ]]; then
      return 0
    fi
    local val
    val=$(printf '%s' "$string_match" | sed -E 's/.*"permission"[[:space:]]*:[[:space:]]*"([A-Za-z_]+)".*/\1/')
    echo "opencode.json: permission is '$val' (need 'allow' for trooper auto-approve)" >&2
    echo "  config: $cfg" >&2
    return 1
  fi
  if grep -qE "${lead}\\{" "$cfg" 2>/dev/null; then
    echo "opencode.json: object-form permission detected; medic does not introspect per-tool keys" >&2
    echo "  config: $cfg — verify all relevant tools (bash/edit/...) are 'allow' manually" >&2
    return 2
  fi
  echo "opencode.json: no top-level 'permission' key (defaults to 'ask')" >&2
  echo "  config: $cfg" >&2
  return 1
}
