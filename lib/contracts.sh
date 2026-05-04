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

# Print the `binary:` field of <provider>, or empty + non-zero exit if not found.
# binary: must appear at exactly 2-space indent (direct child of provider key) —
# tighter than [[:space:]]+ to avoid matching nested binary: fields if any future
# schema change introduces one.
cw_contract_binary() {
  local provider="$1" path bin
  path=$(cw_contracts_path)
  [[ -f "$path" ]] || return 1
  bin=$(awk -v p="$provider" '
    BEGIN { in_block = 0 }
    /^[A-Za-z][A-Za-z0-9_-]*:[[:space:]]*$/ {
      key = $0; sub(/:[[:space:]]*$/, "", key)
      in_block = (key == p)
      next
    }
    in_block && /^  binary:[[:space:]]*/ {
      val = $0
      sub(/^  binary:[[:space:]]*/, "", val)
      gsub(/^[ \t]+|[ \t\r]+$/, "", val)
      print val
      exit
    }
  ' "$path")
  [[ -n "$bin" ]] || return 1
  printf '%s\n' "$bin"
}

# cw_contract_default_mode <provider> — print provider's default_mode field.
cw_contract_default_mode() {
  local provider="$1" path val
  path=$(cw_contracts_path)
  [[ -f "$path" ]] || return 1
  val=$(awk -v p="$provider" '
    BEGIN { in_block = 0 }
    /^[A-Za-z][A-Za-z0-9_-]*:[[:space:]]*$/ {
      key = $0; sub(/:[[:space:]]*$/, "", key)
      in_block = (key == p); next
    }
    in_block && /^  default_mode:[[:space:]]*/ {
      v = $0
      sub(/^  default_mode:[[:space:]]*/, "", v)
      gsub(/^[ \t]+|[ \t\r]+$/, "", v)
      print v; exit
    }
  ' "$path")
  [[ -n "$val" ]] || return 1
  printf '%s\n' "$val"
}

# cw_contract_ready_timeout <provider> — print provider's ready_timeout_s
# (integer seconds). Falls back to 30 if unset.
cw_contract_ready_timeout() {
  local provider="$1" path val
  path=$(cw_contracts_path)
  [[ -f "$path" ]] || { printf '30\n'; return; }
  val=$(awk -v p="$provider" '
    BEGIN { in_block = 0 }
    /^[A-Za-z][A-Za-z0-9_-]*:[[:space:]]*$/ {
      key = $0; sub(/:[[:space:]]*$/, "", key)
      in_block = (key == p); next
    }
    in_block && /^  ready_timeout_s:[[:space:]]*/ {
      v = $0
      sub(/^  ready_timeout_s:[[:space:]]*/, "", v)
      gsub(/^[ \t]+|[ \t\r]+$/, "", v)
      print v; exit
    }
  ' "$path")
  [[ -n "$val" ]] || val=30
  printf '%s\n' "$val"
}

# cw_contract_bootstrap_sleep <provider>
# Print the seconds-to-sleep after launching the provider's TUI but BEFORE
# nudging it to read its identity. Mirrors the parser shape of
# cw_contract_ready_timeout.
#
# Default fallback when the field is unset is PROVIDER-SPECIFIC:
#   claude → 12 (preserves the v0.0.4 hardcoded BOOT_SLEEP)
#   anything else → 8
# This protects existing installs whose user-owned ~/.clone-wars/contracts.yaml
# was copied before the field was introduced — claude users don't silently
# regress to a too-short bootstrap. Once a user syncs bootstrap_sleep_s
# into their contracts.yaml, the explicit value wins. Drop the per-provider
# defaults in a future release after a migration window.
cw_contract_bootstrap_sleep() {
  local provider="$1" path val default
  case "$provider" in
    claude) default=12 ;;
    *)      default=8  ;;
  esac
  path=$(cw_contracts_path)
  [[ -f "$path" ]] || { printf '%s\n' "$default"; return; }
  val=$(awk -v p="$provider" '
    BEGIN { in_block = 0 }
    /^[A-Za-z][A-Za-z0-9_-]*:[[:space:]]*$/ {
      key = $0; sub(/:[[:space:]]*$/, "", key)
      in_block = (key == p); next
    }
    in_block && /^  bootstrap_sleep_s:[[:space:]]*/ {
      v = $0
      sub(/^  bootstrap_sleep_s:[[:space:]]*/, "", v)
      gsub(/^[ \t]+|[ \t\r]+$/, "", v)
      print v; exit
    }
  ' "$path")
  [[ -n "$val" ]] || val="$default"
  printf '%s\n' "$val"
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
