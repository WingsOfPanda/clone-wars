#!/usr/bin/env bash
# bin/deploy-pre-snapshot.sh <topic>
# Walks cw_deploy_iter_targets <topic> and calls cw_deploy_pre_snapshot
# per row, writing baselines under $ART_DIR/baselines/<slug>.tsv.
#
# Exits 0 even when individual targets hit hook-blocked warnings; exits
# 2 when any target is not a git repo (pre_snapshot returns 2).
set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deploy.sh"

[[ $# -eq 1 ]] || { echo "Usage: $0 <topic>" >&2; exit 2; }
TOPIC="$1"
cw_deploy_assert_topic "$TOPIC"

ART_DIR=$(cw_deploy_art_dir "$TOPIC")
[[ -d "$ART_DIR" ]] || { log_error "art-dir missing: $ART_DIR (run deploy-init.sh first)"; exit 1; }
mkdir -p "$ART_DIR/baselines"

count_clean=0; count_committed=0; count_blocked=0
while IFS=$'\t' read -r slug cwd; do
  [[ -n "$slug" && -n "$cwd" ]] || continue
  baseline="$ART_DIR/baselines/$slug.tsv"
  if ! cw_deploy_pre_snapshot "$cwd" "$TOPIC" "$slug" "$baseline"; then
    log_error "pre_snapshot failed for slug=$slug cwd=$cwd"
    exit 2
  fi
  state=$(grep -E '^state=' "$baseline" | head -1 | cut -d= -f2)
  case "$state" in
    clean)         count_clean=$(( count_clean + 1 )) ;;
    wip-committed) count_committed=$(( count_committed + 1 )) ;;
    hook-blocked)  count_blocked=$(( count_blocked + 1 )) ;;
  esac
done < <(cw_deploy_iter_targets "$TOPIC")

log_ok "pre-snapshot: $count_clean clean, $count_committed committed, $count_blocked hook-blocked"
