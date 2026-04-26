# lib/commanders.sh — clone-trooper name-pool management.
# Sourced. Depends on lib/state.sh.
#
# Pool source: $CLONE_WARS_HOME/commanders.yaml (per-machine, user-editable),
# falls back to the shipped default at $PLUGIN_ROOT/config/commanders.yaml.

# cw_commanders_path — print the active commanders.yaml path.
cw_commanders_path() {
  local p="$(cw_state_root)/commanders.yaml"
  [[ -f "$p" ]] || p="$PLUGIN_ROOT/config/commanders.yaml"
  printf '%s\n' "$p"
}

# cw_commanders_pool — print every commander name in the pool, one per line.
# Strips list markers (`- `) and whitespace. Skips comments and empty lines.
cw_commanders_pool() {
  local path; path=$(cw_commanders_path)
  awk '
    /^[[:space:]]*#/  { next }
    /^[[:space:]]*$/  { next }
    /^[[:space:]]*-[[:space:]]+/ {
      sub(/^[[:space:]]*-[[:space:]]+/, "", $0)
      gsub(/^[ \t]+|[ \t\r]+$/, "", $0)
      if ($0 != "") print
    }
  ' "$path"
}

# cw_commanders_in_use_in_topic <topic>
# Print the set of commanders currently deployed in <topic> by listing the
# state dir's <commander>-<model>/ children.
cw_commanders_in_use_in_topic() {
  local topic="$1"
  local dir="$(cw_state_root)/state/$(cw_repo_hash)/$topic"
  [[ -d "$dir" ]] || return 0
  ls -1 "$dir" 2>/dev/null | sed 's/-[^-]*$//' | sort -u
}

# cw_commander_in_use <commander> <topic>
# Return 0 if <commander> already has a state dir under <topic>.
cw_commander_in_use() {
  local commander="$1" topic="$2"
  cw_commanders_in_use_in_topic "$topic" | grep -qx "$commander"
}

# cw_commanders_in_use_globally
# Print every commander currently deployed across every topic in this repo.
cw_commanders_in_use_globally() {
  local root="$(cw_state_root)/state/$(cw_repo_hash)"
  [[ -d "$root" ]] || return 0
  for topic_dir in "$root"/*/; do
    [[ -d "$topic_dir" ]] || continue
    ls -1 "$topic_dir" 2>/dev/null | sed 's/-[^-]*$//'
  done | sort -u
}

# cw_commander_pick_random <topic>
# Pick a commander that's (a) in the pool, (b) not in use within <topic>.
# Bias toward globally-unused names first; fall back to topic-unused if every
# pool name is in use somewhere. Print the picked name on stdout.
# Return 1 if every pool name is already in use within <topic>.
cw_commander_pick_random() {
  local topic="$1"
  local pool topic_used global_used candidates
  pool=$(cw_commanders_pool | sort)
  topic_used=$(cw_commanders_in_use_in_topic "$topic" | sort)
  global_used=$(cw_commanders_in_use_globally | sort)

  # First preference: in pool, NOT in global use.
  candidates=$(comm -23 <(printf '%s\n' "$pool") <(printf '%s\n' "$global_used"))
  if [[ -z "$candidates" ]]; then
    # Second preference: in pool, not in TOPIC use (may be busy on another topic).
    candidates=$(comm -23 <(printf '%s\n' "$pool") <(printf '%s\n' "$topic_used"))
  fi
  [[ -n "$candidates" ]] || return 1
  printf '%s\n' "$candidates" | shuf | head -n1
}
