#!/usr/bin/env bash
# bin/deploy-sibling-verify.sh — re-read each sibling's HEAD vs baseline,
# write <art-dir>/sibling-rogue.txt with TSV rows
# "<slug>\t<sha>\t<subject>" for any commits that landed since baseline.
#
# Usage: bin/deploy-sibling-verify.sh <art-dir> <hub-cwd>
#
# Exit codes:
#   0 — verify ran (sibling-rogue.txt may be empty if no rogue commits)
#   1 — baseline missing, hub missing, or git failure
#   2 — usage error (missing args)
set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deploy-sibling.sh"

if (( $# != 2 )); then
  echo "Usage: $0 <art-dir> <hub-cwd>" >&2
  exit 2
fi
ART_DIR="$1"; HUB_CWD="$2"

[[ -d "$ART_DIR" ]] || { log_error "art-dir not a directory: $ART_DIR"; exit 1; }
[[ -d "$HUB_CWD" ]] || { log_error "hub-cwd not a directory: $HUB_CWD"; exit 1; }
[[ -f "$ART_DIR/sibling-baseline.txt" ]] || { log_error "no sibling-baseline.txt in $ART_DIR — run deploy-sibling-baseline.sh first"; exit 1; }

OUT_TMP="$ART_DIR/sibling-rogue.txt.tmp"
: > "$OUT_TMP"
while IFS=$'\t' read -r slug base_sha branch; do
  [[ -n "$slug" && -n "$base_sha" && -n "$branch" ]] || continue
  rogue=$(cw_deploy_diff_sibling_against_baseline "$HUB_CWD/$slug" "$base_sha" "$branch") || {
    log_warn "diff failed for $slug; skipping"
    continue
  }
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    sha="${line%% *}"
    subject="${line#* }"
    printf '%s\t%s\t%s\n' "$slug" "$sha" "$subject" >> "$OUT_TMP"
  done <<< "$rogue"
done < "$ART_DIR/sibling-baseline.txt"
mv "$OUT_TMP" "$ART_DIR/sibling-rogue.txt"
n=$(wc -l < "$ART_DIR/sibling-rogue.txt")
if (( n > 0 )); then
  log_warn "sibling verify: $n rogue commit(s) detected on undeclared sibling main branches"
fi
