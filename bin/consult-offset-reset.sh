#!/usr/bin/env bash
# bin/consult-offset-reset.sh — remove per-commander state file + cascade.
# The only documented retry primitive. See spec § "Retry contract".
#
# Usage: bin/consult-offset-reset.sh <consult-topic> <commander> <phase>
#   <phase> ∈ {research, verify}
#
# Removes _consult/<phase>-<commander>.txt and the derived artifacts that
# depend on it (diff.md and *_only_items.txt for the research phase;
# adjudicated-draft.md for both phases). ALSO removes the trooper-owned
# findings.md (research) or verify.md (verify) so the next wait sees only
# fresh content. Idempotent on missing files.

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/consult.sh"

# Optional --keep-findings flag preserves trooper-owned files + cascade
# artifacts (used by Patterns 1/3 for full re-prompts). The question loop
# never calls this — wait-script auto-bumps OFFSET inline.
KEEP_FINDINGS=0
ARGS=()
for a in "$@"; do
  case "$a" in
    --keep-findings) KEEP_FINDINGS=1 ;;
    --*) echo "Unknown flag: $a" >&2; exit 2 ;;
    *) ARGS+=("$a") ;;
  esac
done
[[ ${#ARGS[@]} -eq 3 ]] \
  || { echo "Usage: $0 <consult-topic> <commander> <phase> [--keep-findings]" >&2; exit 2; }
TOPIC="${ARGS[0]}"; COMMANDER="${ARGS[1]}"; PHASE="${ARGS[2]}"

cw_consult_topic_validate "$TOPIC" \
  || { log_error "invalid topic: $TOPIC"; exit 2; }
[[ "$COMMANDER" =~ ^[a-z0-9_-]+$ ]] \
  || { log_error "invalid commander: $COMMANDER"; exit 2; }
[[ "$PHASE" == research || "$PHASE" == verify ]] \
  || { log_error "phase must be 'research' or 'verify'; got '$PHASE'"; exit 2; }

ART_DIR="$(cw_state_root)/state/$(cw_repo_hash)/$TOPIC/_consult"
[[ -d "$ART_DIR" ]] || { log_error "$ART_DIR not found"; exit 1; }

rm -f "$ART_DIR/$PHASE-$COMMANDER.txt"

# Pending question payload always cleared (it's been handled).
rm -f "$ART_DIR/question-$COMMANDER.txt"

if (( ! KEEP_FINDINGS )); then
  # Trooper-owned output file: without this, the subsequent wait sees the
  # stale findings.md/verify.md and marks FS/VS=ok even when the re-prompt
  # timed out. Find the trooper dir by listing
  # state/<repo-hash>/<topic>/<commander>-<model>/ — model is unknown to
  # this script, so glob it.
  TROOPER_DIR_GLOB=$(cw_state_root)/state/$(cw_repo_hash)/$TOPIC/$COMMANDER-*
  shopt -s nullglob
  for td in $TROOPER_DIR_GLOB; do
    if [[ "$PHASE" == research ]]; then
      rm -f "$td/findings.md"
    else
      rm -f "$td/verify.md"
    fi
  done

  # Cascade. Research phase invalidates downstream computation.
  if [[ "$PHASE" == research ]]; then
    rm -f "$ART_DIR/diff.md" "$ART_DIR/rex_only_items.txt" "$ART_DIR/cody_only_items.txt"
  fi
  # Both phases invalidate the adjudication draft (which depends on both).
  rm -f "$ART_DIR/adjudicated-draft.md"
fi

log_info "reset $PHASE state for $COMMANDER on $TOPIC$( ((KEEP_FINDINGS)) && printf ' (--keep-findings)')"
