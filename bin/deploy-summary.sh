#!/usr/bin/env bash
# bin/deploy-summary.sh <topic>
# Walks cw_deploy_iter_targets <topic>, calls cw_deploy_post_sweep for
# each row (writes $ART_DIR/posts/<slug>.tsv), then prints one
# cw_deploy_format_summary_block per row to stdout.
#
# Exits 0 unless a per-target step itself errors fatally (e.g. baseline
# file missing for a known target).
set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deploy.sh"

[[ $# -eq 1 ]] || { echo "Usage: $0 <topic>" >&2; exit 2; }
TOPIC="$1"
cw_deploy_assert_topic "$TOPIC"

ART_DIR=$(cw_deploy_art_dir "$TOPIC")
[[ -d "$ART_DIR" ]] || { log_error "art-dir missing: $ART_DIR"; exit 1; }
mkdir -p "$ART_DIR/posts"

while IFS=$'\t' read -r slug cwd; do
  [[ -n "$slug" && -n "$cwd" ]] || continue
  baseline="$ART_DIR/baselines/$slug.tsv"
  post="$ART_DIR/posts/$slug.tsv"
  if [[ ! -f "$baseline" ]]; then
    log_error "summary: baseline missing for slug=$slug ($baseline)"
    continue
  fi
  if [[ ! -d "$cwd" ]]; then
    log_warn "summary: target gone for slug=$slug (cwd=$cwd); omitting block"
    continue
  fi
  cw_deploy_post_sweep "$baseline" "$TOPIC" "$post"
  cw_deploy_format_summary_block "$baseline" "$post"
  printf '\n'
done < <(cw_deploy_iter_targets "$TOPIC")
