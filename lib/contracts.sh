# lib/contracts.sh — read provider rows from $CLONE_WARS_HOME/contracts.yaml.
# Parser is awk/grep — no yq dependency. Only structures medic and Plan B need.
# Sourced. Depends on lib/state.sh.

cw_contracts_path() {
  printf '%s/contracts.yaml\n' "$(cw_state_root)"
}

cw_contracts_exists() {
  [[ -f "$(cw_contracts_path)" ]]
}

# List provider top-level keys in file order. A provider key is a non-indented
# line whose first non-whitespace token ends in a colon and isn't a comment.
cw_contracts_providers() {
  local path; path=$(cw_contracts_path)
  [[ -f "$path" ]] || return 1
  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/  { next }
    /^[A-Za-z][A-Za-z0-9_-]*:[[:space:]]*$/ {
      sub(/:[[:space:]]*$/, "", $0)
      print
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
