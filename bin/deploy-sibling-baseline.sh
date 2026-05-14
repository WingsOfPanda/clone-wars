#!/usr/bin/env bash
# bin/deploy-sibling-baseline.sh — capture sibling sub-repo HEAD SHAs at deploy
# start. Writes <art-dir>/sibling-baseline.txt as 3-col TSV
# "<slug>\t<sha>\t<branch>" — one row per sibling git repo of $hub-cwd that
# is not in the declared $declared-targets-csv.
#
# Usage: bin/deploy-sibling-baseline.sh <art-dir> <hub-cwd> [<declared-targets-csv>]
#
# Exit codes:
#   0 — baseline.txt written (may be empty if no siblings)
#   1 — hub or art-dir missing, or git failure
#   2 — usage error (missing args)
set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deploy-sibling.sh"

if (( $# < 2 || $# > 3 )); then
  echo "Usage: $0 <art-dir> <hub-cwd> [<declared-targets-csv>]" >&2
  exit 2
fi
ART_DIR="$1"; HUB_CWD="$2"; TARGETS_CSV="${3:-}"

[[ -d "$ART_DIR" ]] || { log_error "art-dir not a directory: $ART_DIR"; exit 1; }
[[ -d "$HUB_CWD" ]] || { log_error "hub-cwd not a directory: $HUB_CWD"; exit 1; }

mapfile -t SIBLINGS < <(cw_deploy_enumerate_siblings "$HUB_CWD" "$TARGETS_CSV") \
  || { log_error "enumerate_siblings failed"; exit 1; }

OUT_TMP="$ART_DIR/sibling-baseline.txt.tmp"
: > "$OUT_TMP"
for slug in "${SIBLINGS[@]}"; do
  [[ -n "$slug" ]] || continue
  if ! cw_deploy_capture_sibling_baseline "$HUB_CWD/$slug" >> "$OUT_TMP"; then
    log_warn "skipped $slug (capture_baseline failed; likely detached HEAD)"
  fi
done
mv "$OUT_TMP" "$ART_DIR/sibling-baseline.txt"
log_info "sibling baseline: $(wc -l < "$ART_DIR/sibling-baseline.txt") repos captured"
