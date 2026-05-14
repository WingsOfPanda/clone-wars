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

# cw_deploy_capture_sibling_baseline <sibling-cwd>
#
# Captures the current default branch and its HEAD SHA. Emits TSV
# "<slug>\t<sha>\t<branch>" on stdout. Slug = basename of $sibling-cwd.
# Branch = result of `git symbolic-ref --short HEAD`.
#
# rc=0 on success.
# rc=1 if not a git repo OR if HEAD is detached (no symbolic-ref).
# rc=2 on missing arg.
cw_deploy_capture_sibling_baseline() {
  if (( $# < 1 )); then
    echo "cw_deploy_capture_sibling_baseline: usage: <sibling-cwd>" >&2
    return 2
  fi
  local sib="$1"
  git -C "$sib" rev-parse --git-dir >/dev/null 2>&1 \
    || { echo "cw_deploy_capture_sibling_baseline: not a git repo: $sib" >&2; return 1; }
  local branch sha slug
  branch=$(git -C "$sib" symbolic-ref --short HEAD 2>/dev/null) \
    || { echo "cw_deploy_capture_sibling_baseline: HEAD detached in $sib" >&2; return 1; }
  sha=$(git -C "$sib" rev-parse HEAD)
  slug=$(basename "$sib")
  printf '%s\t%s\t%s\n' "$slug" "$sha" "$branch"
}

# cw_deploy_diff_sibling_against_baseline <sibling-cwd> <baseline-sha> <branch>
#
# Lists commits on $branch since $baseline-sha, oneline format. Empty stdout
# when no new commits. The branch arg is consumed verbatim — caller is
# expected to pass the value previously captured by capture_sibling_baseline
# (so detached-HEAD or branch-rename mid-deploy don't silently produce
# wrong results).
#
# rc=0 on success (including empty diff).
# rc=1 if not a git repo OR baseline SHA missing OR branch missing.
# rc=2 on missing arg.
cw_deploy_diff_sibling_against_baseline() {
  if (( $# < 3 )); then
    echo "cw_deploy_diff_sibling_against_baseline: usage: <sibling-cwd> <baseline-sha> <branch>" >&2
    return 2
  fi
  local sib="$1" base="$2" branch="$3"
  git -C "$sib" rev-parse --git-dir >/dev/null 2>&1 \
    || { echo "cw_deploy_diff_sibling_against_baseline: not a git repo: $sib" >&2; return 1; }
  git -C "$sib" rev-parse --verify -q "$base" >/dev/null \
    || { echo "cw_deploy_diff_sibling_against_baseline: baseline SHA $base unknown to $sib" >&2; return 1; }
  git -C "$sib" rev-parse --verify -q "refs/heads/$branch" >/dev/null \
    || { echo "cw_deploy_diff_sibling_against_baseline: branch $branch missing in $sib" >&2; return 1; }
  git -C "$sib" log "$base..refs/heads/$branch" --oneline
}
