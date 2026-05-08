#!/usr/bin/env bash
# bin/consult-synthesize.sh — produce per-section seed drafts after PENDING
# resolution. The final design-doc is assembled by bin/consult-walk-assemble.sh
# (v0.17.0 split).
#
# Usage: bin/consult-synthesize.sh <consult-topic>
#
# v0.17.0: writes 6 seed drafts to
#   _consult/design-doc/.draft/{problem,goal,architecture,components,testing,success-criteria}.md
# from the adjudicated.md content. Each draft starts with the heading and a
# bracketed seed body grep'd from adjudicated.md. The directive's Step 11
# walk consumes these as starting points for Yoda's per-section drafts.
#
# Refuses if adjudicated.md is missing OR contains any ^- PENDING: line.
# Does NOT emit the final design-doc — that's walk-assemble's job.
# Does NOT write the legacy _consult/synthesis.md (removed in v0.12).

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/consult.sh"

[[ $# -eq 1 ]] || { echo "Usage: $0 <consult-topic>" >&2; exit 2; }
TOPIC="$1"
cw_consult_assert_topic "$TOPIC"

ART_DIR="$(cw_consult_art_dir "$TOPIC")"
[[ -d "$ART_DIR" ]] || { log_error "$ART_DIR not found"; exit 1; }

ADJ="$ART_DIR/adjudicated.md"
[[ -f "$ADJ" ]] || {
  log_error "$ADJ missing — Master Yoda must run:"
  log_error "  cp \"$ART_DIR/adjudicated-draft.md\" \"$ART_DIR/adjudicated.md\""
  log_error "then resolve PENDINGs."
  exit 1
}

if grep -q '^- PENDING:' "$ADJ"; then
  log_error "$ADJ still has ^- PENDING: lines:"
  grep -n '^- PENDING:' "$ADJ" >&2
  exit 1
fi

# v0.17.0: per-section seed drafts replace the v0.16 single design-doc emit.
DRAFT_DIR="$ART_DIR/design-doc/.draft"
mkdir -p "$DRAFT_DIR"

# Single-repo 6-section shape. Multi-repo extras (execution-dag,
# cross-repo-notes) are NOT seeded here — Yoda drafts them fresh during the
# walk because they require targets.txt content not present in adjudicated.md.
SECTIONS=(problem goal architecture components testing success-criteria)
for section in "${SECTIONS[@]}"; do
  case "$section" in
    problem)          heading="## Problem" ;;
    goal)             heading="## Goal" ;;
    architecture)     heading="## Architecture" ;;
    components)       heading="## Components" ;;
    testing)          heading="## Testing" ;;
    success-criteria) heading="## Success Criteria" ;;
  esac
  DRAFT_FILE="$DRAFT_DIR/$section.md"
  TMPF=$(mktemp)
  printf '%s\n\n' "$heading" > "$TMPF"
  case "$section" in
    problem)
      printf '<!-- seed: cross-verified facts about the current state -->\n' >> "$TMPF"
      grep -E '^- \[' "$ADJ" 2>/dev/null >> "$TMPF" || true ;;
    goal)
      printf '<!-- seed: claims tagged [Goal] in adjudicated.md -->\n' >> "$TMPF"
      grep -iE '^- \[Goal' "$ADJ" 2>/dev/null >> "$TMPF" || true ;;
    architecture)
      printf '<!-- seed: claims tagged [Architecture] -->\n' >> "$TMPF"
      grep -iE '^- \[Architecture' "$ADJ" 2>/dev/null >> "$TMPF" || true ;;
    components)
      printf '<!-- seed: claims tagged [Components] -->\n' >> "$TMPF"
      grep -iE '^- \[Components' "$ADJ" 2>/dev/null >> "$TMPF" || true ;;
    testing)
      printf '<!-- seed: claims tagged [Testing] or containing "test" -->\n' >> "$TMPF"
      grep -iE '^- \[Testing|^- .*\btest' "$ADJ" 2>/dev/null >> "$TMPF" || true ;;
    success-criteria)
      printf '<!-- seed: claims tagged [Success Criteria] -->\n' >> "$TMPF"
      grep -iE '^- \[Success' "$ADJ" 2>/dev/null >> "$TMPF" || true ;;
  esac
  # Ensure non-empty body (placeholder if no seed content matched).
  if [[ $(wc -l < "$TMPF") -le 2 ]]; then
    printf '_(no seed content matched; Yoda drafts from scratch in Step 11)_\n' >> "$TMPF"
  fi
  mv "$TMPF" "$DRAFT_FILE"
done

log_info "[synthesize] wrote ${#SECTIONS[@]} seed drafts to $DRAFT_DIR"
