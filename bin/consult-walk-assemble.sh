#!/usr/bin/env bash
# bin/consult-walk-assemble.sh <topic>
#
# Concatenates approved .draft/<section>.md files into the canonical
# design-doc at _consult/design-doc/<YYYY-MM-DD>-<slug>-design.md.
# Single-repo: 6 sections (problem/goal/architecture/components/testing/
# success-criteria). Multi-repo (Task 9): 8 sections + Target Sub-Project(s)
# header. Audit gate (Task 10): runs cw_deploy_audit_doc, exits non-zero
# on FAIL with ISSUE= lines on stderr.
#
# Echoes the absolute path of the written design-doc on stdout.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/lib/log.sh"
source "$ROOT/lib/state.sh"
source "$ROOT/lib/consult.sh"

TOPIC="${1:-}"
[[ -n "$TOPIC" ]] || { log_error "consult-walk-assemble: <topic> required"; exit 2; }

REPO_HASH=$(cw_repo_hash)
STATE_ROOT=$(cw_state_root)
TD="$STATE_ROOT/state/$REPO_HASH/$TOPIC"
ART="$TD/_consult"
DR="$ART/design-doc/.draft"

[[ -d "$DR" ]] || { log_error "consult-walk-assemble: draft dir not found: $DR"; exit 1; }
[[ -f "$ART/topic.txt" ]] || { log_error "consult-walk-assemble: topic.txt not found"; exit 1; }

# H1 from topic.txt's first line.
TITLE=$(head -1 "$ART/topic.txt")
SLUG="${TOPIC#consult-}"
DATE=$(date -u +%Y-%m-%d)
OUT="$ART/design-doc/$DATE-$SLUG-design.md"

# Multi-repo detection: read _consult/multi-repo.txt + targets.txt.
MULTI_REPO=0
TARGET_SLUGS=""
if [[ -f "$ART/multi-repo.txt" ]]; then
  mode=$(tr -d '[:space:]' < "$ART/multi-repo.txt")
  if [[ "$mode" == "multi" ]]; then
    [[ -f "$ART/targets.txt" ]] || { log_error "walk-assemble: multi-repo.txt=multi but targets.txt missing"; exit 1; }
    MULTI_REPO=1
    TARGET_SLUGS=$(grep -v '^#' "$ART/targets.txt" | awk -F'\t' 'NF{print $1}' | paste -sd ',' - | sed 's/,/, /g')
  fi
fi

if (( MULTI_REPO )); then
  SECTIONS=(problem goal architecture components execution-dag cross-repo-notes testing success-criteria)
else
  SECTIONS=(problem goal architecture components testing success-criteria)
fi

TMPF=$(mktemp); trap 'rm -f "$TMPF"' EXIT

printf '# %s\n\n' "$TITLE" > "$TMPF"

if (( MULTI_REPO )); then
  printf '**Date:** %s\n' "$DATE" >> "$TMPF"
  printf '**Target Sub-Project(s):** %s\n\n' "$TARGET_SLUGS" >> "$TMPF"
fi

for section in "${SECTIONS[@]}"; do
  src="$DR/$section.md"
  if [[ -f "$src" ]]; then
    cat "$src" >> "$TMPF"
    printf '\n' >> "$TMPF"
  else
    case "$section" in
      problem)          heading="## Problem" ;;
      goal)             heading="## Goal" ;;
      architecture)     heading="## Architecture" ;;
      components)       heading="## Components" ;;
      execution-dag)    heading="## Execution DAG" ;;
      cross-repo-notes) heading="## Cross-Repo Notes" ;;
      testing)          heading="## Testing" ;;
      success-criteria) heading="## Success Criteria" ;;
    esac
    printf '%s\n\n_(missing draft)_\n\n' "$heading" >> "$TMPF"
  fi
done

mv "$TMPF" "$OUT"
trap - EXIT
log_info "[walk-assemble] wrote $OUT"
printf '%s\n' "$OUT"
