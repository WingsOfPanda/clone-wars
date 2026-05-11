# lib/contracts.sh — read provider rows from $CLONE_WARS_HOME/contracts.yaml.
# Parser is awk/grep — no yq dependency. Only the fields medic + spawn need.
# Sourced. Depends on lib/state.sh.

cw_contracts_path() {
  printf '%s/contracts.yaml\n' "$(cw_state_root)"
}

cw_contracts_exists() {
  [[ -f "$(cw_contracts_path)" ]]
}

# List provider top-level keys in file order. A provider key is a non-indented
# line whose first non-whitespace token ends in a colon and isn't a comment.
# Reserved non-provider top-level blocks (e.g. `consult:` for /clone-wars:consult
# timeouts) are skipped so medic and runtime callers don't treat them as providers.
cw_contracts_providers() {
  local path; path=$(cw_contracts_path)
  [[ -f "$path" ]] || return 1
  awk '
    BEGIN {
      # Reserved top-level keys that are NOT provider rows.
      reserved["consult"] = 1
    }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/  { next }
    /^[A-Za-z][A-Za-z0-9_-]*:[[:space:]]*$/ {
      name = $0
      sub(/:[[:space:]]*$/, "", name)
      if (name in reserved) next
      print name
    }
  ' "$path"
}

# _cw_contract_field <provider> <field>
# Private. Print the value of a 2-space-indented <field>: under the
# <provider>: top-level block in contracts.yaml. Empty stdout if the
# provider or field is missing. binary: indent guard (#fa10553) is
# preserved by the literal `^  ` prefix — nested fields are not matched.
_cw_contract_field() {
  local provider="$1" field="$2" path
  path=$(cw_contracts_path)
  [[ -f "$path" ]] || return 1
  awk -v p="$provider" -v f="$field" '
    BEGIN { in_block = 0 }
    /^[A-Za-z][A-Za-z0-9_-]*:[[:space:]]*$/ {
      key = $0; sub(/:[[:space:]]*$/, "", key)
      in_block = (key == p); next
    }
    in_block && $0 ~ "^  "f":[[:space:]]" {
      v = $0; sub("^  "f":[[:space:]]*", "", v)
      gsub(/^[ \t]+|[ \t\r]+$/, "", v)
      print v; exit
    }
  ' "$path"
}

# Print the `binary:` field of <provider>, or empty + non-zero exit if not found.
cw_contract_binary() {
  local v; v=$(_cw_contract_field "$1" binary)
  [[ -n "$v" ]] || return 1
  printf '%s\n' "$v"
}

# cw_contract_default_mode <provider> — print provider's default_mode field.
cw_contract_default_mode() {
  local v; v=$(_cw_contract_field "$1" default_mode)
  [[ -n "$v" ]] || return 1
  printf '%s\n' "$v"
}

# cw_contract_ready_timeout <provider> — print provider's ready_timeout_s
# (integer seconds). Falls back to 30 if unset.
cw_contract_ready_timeout() {
  local v; v=$(_cw_contract_field "$1" ready_timeout_s)
  printf '%s\n' "${v:-30}"
}

# cw_contract_bootstrap_sleep <provider>
# Print the seconds-to-sleep after launching the provider's TUI but BEFORE
# nudging it to read its identity. Per-provider fallback when unset:
#   claude → 12 (preserves the v0.0.4 hardcoded BOOT_SLEEP)
#   anything else → 8
# Protects existing installs whose user-owned contracts.yaml was copied
# before the field was introduced.
cw_contract_bootstrap_sleep() {
  local provider="$1" v default
  case "$provider" in
    claude) default=12 ;;
    *)      default=8  ;;
  esac
  v=$(_cw_contract_field "$provider" bootstrap_sleep_s)
  printf '%s\n' "${v:-$default}"
}

# cw_consult_timeout <kind>
# Print the configured timeout for <kind> ∈ {research, verify}. Reads the
# consult: block in contracts.yaml; falls back to research=600, verify=300
# on missing block, missing field, or non-positive-integer value.
cw_consult_timeout() {
  local kind="$1" key default
  case "$kind" in
    research) key=research_timeout_s; default=600 ;;
    verify)   key=verify_timeout_s;   default=300 ;;
    *) echo "cw_consult_timeout: kind must be 'research' or 'verify'; got '$kind'" >&2; return 2 ;;
  esac
  local path; path=$(cw_contracts_path)
  [[ -f "$path" ]] || { printf '%s\n' "$default"; return 0; }
  local v
  v=$(awk -v key="$key" '
    /^consult:/         { in_consult = 1; next }
    /^[a-z]/            { in_consult = 0 }
    in_consult && $1 == key":" { print $2; exit }
  ' "$path")
  if [[ -z "$v" ]] || ! [[ "$v" =~ ^[1-9][0-9]*$ ]]; then
    v="$default"
  fi
  printf '%s\n' "$v"
}

# cw_contract_mode_args <provider> <mode>
# Print the args list for <provider>'s <mode>, one arg per line. Modes are
# stored as YAML flow sequences like:
#   modes:
#     full:      [--dangerously-bypass-approvals-and-sandbox]
#     read-only: [--sandbox, read-only]
# Returns 1 if the mode is not defined.
cw_contract_mode_args() {
  local provider="$1" mode="$2" path raw
  path=$(cw_contracts_path)
  [[ -f "$path" ]] || return 1
  raw=$(awk -v p="$provider" -v m="$mode" '
    BEGIN { in_block = 0; in_modes = 0 }
    /^[A-Za-z][A-Za-z0-9_-]*:[[:space:]]*$/ {
      key = $0; sub(/:[[:space:]]*$/, "", key)
      in_block = (key == p); in_modes = 0; next
    }
    in_block && /^  modes:[[:space:]]*$/    { in_modes = 1; next }
    in_block && /^  [A-Za-z]/                { in_modes = 0 }
    in_block && in_modes && /^    [A-Za-z][A-Za-z0-9_-]*:[[:space:]]*\[/ {
      line = $0
      sub(/^    /, "", line)
      colon = index(line, ":")
      key2 = substr(line, 1, colon - 1)
      gsub(/^[ \t]+|[ \t\r]+$/, "", key2)
      if (key2 == m) {
        v = substr(line, colon + 1)
        sub(/^[[:space:]]*\[/, "", v)
        sub(/\][[:space:]]*(#.*)?$/, "", v)
        gsub(/[ \t\r]+$/, "", v)
        print v
        exit
      }
    }
  ' "$path")
  [[ -n "$raw" ]] || return 1
  # Split on comma, trim each, print one per line.
  IFS=',' read -ra parts <<<"$raw"
  for p in "${parts[@]}"; do
    p="${p#"${p%%[![:space:]]*}"}"
    p="${p%"${p##*[![:space:]]}"}"
    [[ -n "$p" ]] && printf '%s\n' "$p"
  done
}
