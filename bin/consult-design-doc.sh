#!/usr/bin/env bash
# bin/consult-design-doc.sh — assemble + self-review + commit the design doc.
#
# Usage: bin/consult-design-doc.sh <consult-topic>
#
# Inputs:  $TOPIC_DIR/_consult/design-doc/{architecture,components,data-flow,error-handling,testing}.md
#          $TOPIC_DIR/_consult/topic.txt  (for context, not strictly required)
# Output:  docs/clone-wars/specs/YYYY-MM-DD-<slug>-design.md  (committed)
#
# Refuses if:
#   - design-doc dir missing (Step 8.5 walk hasn't happened)
#   - output path already exists (no silent overwrite)
#   - self-review flags placeholders (must clean up before commit)

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/consult.sh"

[[ $# -eq 1 ]] || { echo "Usage: $0 <consult-topic>" >&2; exit 2; }
TOPIC="$1"
cw_consult_topic_validate "$TOPIC" || { log_error "invalid topic: $TOPIC"; exit 2; }

TOPIC_DIR="$(cw_state_root)/state/$(cw_repo_hash)/$TOPIC"
DD_DIR="$TOPIC_DIR/_consult/design-doc"
[[ -d "$DD_DIR" ]] || { log_error "design-doc dir not found: $DD_DIR — run Step 8.5 walk first"; exit 1; }

# Slug = topic with leading "consult-" stripped.
SLUG="${TOPIC#consult-}"
[[ -n "$SLUG" && "$SLUG" != "$TOPIC" ]] || { log_error "topic '$TOPIC' missing 'consult-' prefix"; exit 2; }

# Title — Title-Case the slug for the H1 header.
TITLE=$(printf '%s' "$SLUG" | tr '-' ' ' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))} 1')

OUT_REL=$(cw_consult_design_doc_filename "$SLUG") || exit $?
REPO_ROOT=$(cw_repo_root 2>/dev/null || pwd)
OUT_ABS="$REPO_ROOT/$OUT_REL"

# Refuse silent overwrite.
if [[ -e "$OUT_ABS" ]]; then
  log_error "$OUT_REL already exists; remove or rename before re-running"
  exit 1
fi

mkdir -p "$(dirname "$OUT_ABS")"
cw_consult_design_doc_assemble "$DD_DIR" "$OUT_ABS" "$TITLE" || {
  log_error "assemble failed"
  exit 1
}

if ! cw_consult_design_doc_self_review "$OUT_ABS"; then
  log_error "self-review found placeholders in $OUT_REL"
  log_error "fix the offending sections (Step 8.5 will re-present them) then re-run"
  exit 1
fi

(cd "$REPO_ROOT" && \
  git add "$OUT_REL" && \
  git commit -m "docs(consult): add design doc for $SLUG") || {
  log_error "git commit failed; design.md is written but uncommitted at $OUT_REL"
  exit 1
}

log_info "[design-doc] wrote and committed $OUT_REL"
echo "$OUT_REL"
