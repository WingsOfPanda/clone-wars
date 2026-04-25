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
    in_block && /^[[:space:]]+binary:[[:space:]]*/ {
      val = $0
      sub(/^[[:space:]]+binary:[[:space:]]*/, "", val)
      gsub(/^[ \t]+|[ \t\r]+$/, "", val)
      print val
      exit
    }
  ' "$path")
  [[ -n "$bin" ]] || return 1
  printf '%s\n' "$bin"
}
