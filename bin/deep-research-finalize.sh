#!/usr/bin/env bash
# bin/deep-research-finalize.sh — Phase 4→5 cleanup. Idempotent.
#
# Usage: bin/deep-research-finalize.sh <topic>
#
# Steps (per spec Section 7):
# 1. Read halt reason from halt.flag (default "unknown").
# 2. For each trooper currently working/stale/stuck/blocked: phase=incomplete.
#    For idle/complete: phase=complete. Failed preserved.
# 3. Remove this session's active-<sid>.txt (hook stops injecting handler 3.b context).
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

# v0.52.0 #19: --keep-intermediate opts out of checkpoint pruning.
KEEP_INTERMEDIATE="${CW_DEEP_RESEARCH_KEEP_INTERMEDIATE:-}"
if [[ "${1:-}" == "--keep-intermediate" ]]; then
  KEEP_INTERMEDIATE=1
  shift
fi
[[ $# -eq 1 ]] || { echo "Usage: $0 [--keep-intermediate] <topic>" >&2; exit 2; }
TOPIC="$1"
cw_consult_assert_topic "$TOPIC"

TD="$(cw_topic_state_dir "$TOPIC")"
ART="$TD/_deep-research"
[[ -d "$ART" ]] || { log_error "finalize: art-dir missing: $ART"; exit 1; }

# Halt reason — parsed inside cw_deep_research_render_summary via
# cw_deep_research_halt_flag_read. No local variable needed here.

# Update per-trooper phases
if [[ -f "$ART/troopers.txt" ]]; then
  while read -r cmdr; do
    [[ -n "$cmdr" ]] || continue
    state_file="$ART/troopers/$cmdr/state.txt"
    [[ -f "$state_file" ]] || continue
    # v0.51 #3: replay outbox tail and apply terminal events BEFORE
    # the phase case-mapping. Catches done events that arrived after
    # the last resume.md handler ran (or never got processed at all
    # because the session ended).
    cw_deep_research_trooper_state_reconcile "$ART" "$cmdr"
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

# Remove this session's active marker (hook stops injecting after this)
session_id="${CLAUDE_CODE_SESSION_ID:-unknown}"
rm -f "$ART/active-${session_id}.txt"
rm -f "$ART/active.txt"  # legacy v0.39.0 form — kept for backwards-compat cleanup

# v0.52.0 #19: prune intermediate checkpoints (unless opted out).
CW_DEEP_RESEARCH_KEEP_INTERMEDIATE="$KEEP_INTERMEDIATE" \
  cw_deep_research_prune_intermediate_checkpoints "$ART"

# v0.52.0 #20: co-locate pane outbox/inbox into the artifact tree.
cw_deep_research_link_pane_artifacts "$ART" "$TD"

# v0.52.0 #24: compute size warnings (post-prune).
cw_deep_research_compute_size_warnings "$ART"

# Append Halt section to session-summary.md.
# v0.43.0 Lane A: unconditional re-render so the summary reflects the
# FINAL per-trooper state (post Step-2 phase normalization above), not
# whatever Yoda last wrote pre-halt. Idempotent atomic write.
SS="$ART/session-summary.md"
cw_deep_research_render_summary "$ART" | cw_atomic_write "$SS"
# render_summary now owns the Halt section; no append needed here.
# Idempotency comes from the atomic write above (replaces SS wholesale).

log_ok "finalize: cleanup complete"
