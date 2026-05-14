#!/usr/bin/env bash
# bin/deep-research-finalize.sh — Phase 4→5 cleanup. Idempotent.
#
# Usage: bin/deep-research-finalize.sh <topic>
#
# Steps (per spec Section 7):
# 1. Read halt reason from halt.flag (default "unknown").
# 2. For each trooper currently working/stale/stuck/blocked: phase=incomplete.
#    For idle/complete: phase=complete. Failed preserved.
# 3. Remove active.txt (hook stops injecting handler 3.b context).
# 4. Append ## Halt section to session-summary.md.
#
# Note: monitor task stopping (TaskStop calls) is the directive's job,
# not this script's — TaskStop is a harness tool, not a shell command.
set -uo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"

[[ $# -eq 1 ]] || { echo "Usage: $0 <topic>" >&2; exit 2; }
TOPIC="$1"
cw_consult_assert_topic "$TOPIC"

REPO_HASH=$(cw_repo_hash)
TD="${CLONE_WARS_HOME:-$HOME/.clone-wars}/state/$REPO_HASH/$TOPIC"
ART="$TD/_deep-research"
[[ -d "$ART" ]] || { log_error "finalize: art-dir missing: $ART"; exit 1; }

# Halt reason
REASON=$(cat "$ART/halt.flag" 2>/dev/null | tr -d '\n' || echo "unknown")
[[ -z "$REASON" ]] && REASON="unknown"

# Update per-trooper phases
if [[ -f "$ART/troopers.txt" ]]; then
  while read -r cmdr; do
    [[ -n "$cmdr" ]] || continue
    state_file="$ART/troopers/$cmdr/state.txt"
    [[ -f "$state_file" ]] || continue
    cur_phase=$(cw_deep_research_trooper_state_field "$ART" "$cmdr" phase)
    case "$cur_phase" in
      working|stale|stuck|blocked)
        cw_deep_research_trooper_state_write "$ART" "$cmdr" phase=incomplete
        ;;
      idle|complete)
        cw_deep_research_trooper_state_write "$ART" "$cmdr" phase=complete
        ;;
      failed)
        : # leave failed as is
        ;;
    esac
  done < "$ART/troopers.txt"
fi

# Remove active.txt (hook stops injecting after this)
rm -f "$ART/active.txt"

# Append Halt section to session-summary.md
SS="$ART/session-summary.md"
if [[ ! -f "$SS" ]]; then
  cw_deep_research_render_summary "$ART" > "$SS"
fi
# Idempotency: don't duplicate Halt section
if ! grep -q '^## Halt$' "$SS"; then
  cat >> "$SS" <<EOF

## Halt

- Reason: $REASON
- Finalized: $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
fi

log_ok "finalize: cleanup complete ($REASON)"
