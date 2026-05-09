#!/usr/bin/env bash
# bin/deploy-multi-init.sh — assign one commander per sub-repo + per-repo
# provider detection. Writes _deploy/troopers.txt for the v0.20.0 multi-repo
# deploy flow.
#
# Usage: bin/deploy-multi-init.sh <topic>
#
# Reads:
#   _deploy/<topic>/dag-waves.txt — wave/step/repo/desc TSV
#   $PWD/<repo-slug>/CLAUDE.md or AGENTS.md — sub-repo presence check
#
# Writes:
#   _deploy/<topic>/troopers.txt — TSV: <commander>\t<sub-repo-cwd>\t<provider>
#
# Commander assignment: deterministic; pool order from config/commanders.yaml.
# Codex sub-repos consume pool order skipping `cody` (reserved for claude).
# Plugin sub-repos (have .claude-plugin/plugin.json) → use `cody` + claude.

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deploy.sh"
source "$PLUGIN_ROOT/lib/deploy-dag.sh"

# v0.20.1: accept optional <hub-cwd> 2nd arg (defaults to $PWD).
# bin/deploy-init.sh passes $TARGET_CWD explicitly so this script
# doesn't depend on the caller's cwd.
[[ $# -ge 1 && $# -le 2 ]] || { echo "Usage: $0 <topic> [<hub-cwd>]" >&2; exit 2; }
TOPIC="$1"
HUB_CWD="${2:-$PWD}"
[[ "$HUB_CWD" == /* && -d "$HUB_CWD" ]] || { log_error "hub-cwd must be absolute existing dir: $HUB_CWD"; exit 1; }
cw_deploy_assert_topic "$TOPIC"

ART_DIR=$(cw_deploy_art_dir "$TOPIC")
WAVES_FILE="$ART_DIR/dag-waves.txt"
[[ -f "$WAVES_FILE" ]] || { log_error "dag-waves.txt not found at $WAVES_FILE"; exit 1; }

# Get unique repos in DAG order (stable: first-occurrence order)
declare -a REPOS_ORDERED=()
declare -A SEEN
while IFS=$'\t' read -r wave step repo desc; do
  [[ -n "$repo" ]] || continue
  if [[ -z "${SEEN[$repo]:-}" ]]; then
    REPOS_ORDERED+=( "$repo" )
    SEEN["$repo"]=1
  fi
done < "$WAVES_FILE"

# Read commander pool from commanders.yaml
COMMANDERS_YAML="${CLONE_WARS_HOME:-$HOME/.clone-wars}/commanders.yaml"
[[ -f "$COMMANDERS_YAML" ]] || COMMANDERS_YAML="$PLUGIN_ROOT/config/commanders.yaml"
[[ -f "$COMMANDERS_YAML" ]] || { log_error "commanders.yaml not found"; exit 1; }
mapfile -t POOL < <(awk '/^[[:space:]]*-[[:space:]]+/ { gsub(/^[[:space:]]*-[[:space:]]+/, ""); print }' "$COMMANDERS_YAML")

# Assignment loop
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
CODEX_IDX=0
for repo in "${REPOS_ORDERED[@]}"; do
  CWD="$HUB_CWD/$repo"
  [[ -d "$CWD" ]] || { log_error "sub-repo '$repo' not found at $CWD"; exit 1; }
  [[ -f "$CWD/CLAUDE.md" || -f "$CWD/AGENTS.md" ]] \
    || { log_error "sub-repo '$repo' has no CLAUDE.md or AGENTS.md at $CWD"; exit 1; }

  PROVIDER=$(cw_deploy_detect_provider "$CWD")
  if [[ "$PROVIDER" == "claude" ]]; then
    COMMANDER="cody"
  else
    # Skip cody when assigning codex commanders
    while [[ "${POOL[$CODEX_IDX]:-}" == "cody" ]]; do
      CODEX_IDX=$(( CODEX_IDX + 1 ))
    done
    [[ -n "${POOL[$CODEX_IDX]:-}" ]] || { log_error "commander pool exhausted at index $CODEX_IDX (need ${#REPOS_ORDERED[@]} commanders)"; exit 1; }
    COMMANDER="${POOL[$CODEX_IDX]}"
    CODEX_IDX=$(( CODEX_IDX + 1 ))
  fi
  printf '%s\t%s\t%s\n' "$COMMANDER" "$CWD" "$PROVIDER" >> "$TMP"

  # v0.20.1: capture pristine branch base BEFORE any trooper spawns.
  # Step 3c (Final verification) reads <cmdr>-branch-base.sha to compute
  # the diff range when detecting shared filesystem paths across sub-repos.
  git -C "$CWD" rev-parse HEAD > "$ART_DIR/${COMMANDER}-branch-base.sha" \
    || { log_error "rev-parse HEAD failed for $CWD"; exit 1; }
done

mv "$TMP" "$ART_DIR/troopers.txt" || { log_error "mv troopers.txt failed"; exit 1; }
log_ok "deploy-multi-init: ${#REPOS_ORDERED[@]} troopers assigned for topic $TOPIC"
while IFS= read -r line; do printf '  %s\n' "$line"; done < "$ART_DIR/troopers.txt"
exit 0
