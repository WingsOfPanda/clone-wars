# lib/contracts.sh — read provider rows from $CLONE_WARS_HOME/contracts.yaml.
# Parser is awk/grep — no yq dependency. Only structures medic and Plan B need.
# Sourced. Depends on lib/state.sh.

cw_contracts_path() {
  printf '%s/contracts.yaml\n' "$(cw_state_root)"
}

cw_contracts_exists() {
  [[ -f "$(cw_contracts_path)" ]]
}
