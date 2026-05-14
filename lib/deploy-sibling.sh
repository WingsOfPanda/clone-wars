#!/usr/bin/env bash
# lib/deploy-sibling.sh — adjacent-tree commit guard helpers (v0.30.0 item 2).
#
# Helpers in this file:
#   - cw_deploy_enumerate_siblings:           list git-repo siblings of hub
#   - cw_deploy_capture_sibling_baseline:     (added in Task 4)
#   - cw_deploy_diff_sibling_against_baseline: (added in Task 4)
#   - cw_deploy_revert_and_replay:            (added in Task 5)
#
# Sourcing-only file. No top-level side effects.

# cw_deploy_enumerate_siblings <hub-cwd> <declared-targets-csv>
#
# Walks $hub-cwd's first-level subdirectories (skipping dotfiles), keeps those
# that contain a .git/ directory (not a gitlink file), and excludes any whose
# basename is in $declared-targets-csv. Emits one slug per line, sorted.
#
# rc=0 on success (zero hits prints nothing).
# rc=1 if $hub-cwd doesn't exist.
# rc=2 if either arg is missing (use empty string to mean "no exclusions").
cw_deploy_enumerate_siblings() {
  if (( $# < 2 )); then
    echo "cw_deploy_enumerate_siblings: usage: <hub-cwd> <declared-targets-csv> (empty string for no exclusions)" >&2
    return 2
  fi
  local hub="$1" targets_csv="$2"
  [[ -d "$hub" ]] || { echo "cw_deploy_enumerate_siblings: not a directory: $hub" >&2; return 1; }

  # Build excluded slug set as a sorted, newline-padded scratch (cheap membership check).
  local excluded
  excluded=$'\n'$(printf '%s' "$targets_csv" | tr ',' '\n')$'\n'

  local entry slug
  for entry in "$hub"/*/; do
    [[ -d "$entry" ]] || continue
    slug=$(basename "$entry")
    [[ "$slug" != .* ]] || continue          # skip hidden
    [[ -d "$entry/.git" ]] || continue       # skip non-repos AND submodule gitlinks (.git is a file)
    [[ "$excluded" != *$'\n'"$slug"$'\n'* ]] || continue   # skip declared targets
    printf '%s\n' "$slug"
  done | sort
}
