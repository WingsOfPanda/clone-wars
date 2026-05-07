#!/usr/bin/env bash
# bin/consult-teardown.sh — kill consult panes + archive trooper state.
#
# v0.15.0: iterates _consult/troopers.txt (TSV: <provider>\t<commander>) so the
# teardown scales to N troopers (2/3) instead of the legacy hardcoded rex+cody
# pair. Per-trooper errors are reported via log_warn and the loop continues so
# one failed pane never blocks the others from being archived. When troopers.txt
# is missing (defensive: pre-v0.15 archived state, or a consult that failed
# before consult-init wrote it), falls back to `bin/teardown.sh <topic>` which
# discovers troopers via filesystem scan of the topic dir.
#
# Usage: bin/consult-teardown.sh <consult-topic>

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/consult.sh"

[[ $# -eq 1 ]] || { echo "Usage: $0 <consult-topic>" >&2; exit 2; }
TOPIC="$1"
cw_consult_assert_topic "$TOPIC"

ART_DIR=$(cw_consult_art_dir "$TOPIC")
TROOPERS_FILE="$ART_DIR/troopers.txt"

if [[ -f "$TROOPERS_FILE" ]]; then
  while IFS=$'\t' read -r prov cmdr; do
    [[ -n "$cmdr" ]] || continue
    "$PLUGIN_ROOT/bin/teardown.sh" "$cmdr" "$TOPIC" \
      || log_warn "teardown failed for $cmdr-$prov on $TOPIC (continuing)"
  done < <(cw_consult_load_troopers "$TROOPERS_FILE")
else
  log_warn "troopers.txt missing for '$TOPIC'; falling back to topic-scan teardown"
  "$PLUGIN_ROOT/bin/teardown.sh" "$TOPIC"
fi
