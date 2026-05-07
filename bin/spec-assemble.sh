#!/usr/bin/env bash
# bin/spec-assemble.sh — assemble + self-review + commit the design doc.
#
# Usage: bin/spec-assemble.sh <consult-topic>
#
# Inputs:  $TOPIC_DIR/_consult/design-doc/{architecture,components,data-flow,error-handling,testing}.md
#          $TOPIC_DIR/_consult/topic.txt   (drives title + filename hash)
#          $TOPIC_DIR/_consult/synthesis.md (drives Goal: line)
# Output:  docs/clone-wars/specs/YYYY-MM-DD-<slug>-<hash6>-design.md  (committed)
#
# Atomic-write contract: hash6-reserved filename, refuse-on-collision,
# assemble to temp, self-review, atomic mv to final path, then git commit.
#
# Refuses if:
#   - design-doc dir missing (Step 8.5 walk hasn't happened)
#   - final output path already exists (no silent overwrite)
#   - self-review flags placeholders in the temp file (must fix before commit)
#
# Env hooks for testing:
#   CW_DESIGN_DOC_NO_COMMIT=1 — skip git add/commit (still writes the file).
#   CW_TEST_DATE=YYYY-MM-DD   — stub date (passed through to filename helper).

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/consult.sh"

[[ $# -eq 1 ]] || { echo "Usage: $0 <consult-topic>" >&2; exit 2; }
TOPIC="$1"
cw_consult_assert_topic "$TOPIC"

TOPIC_DIR="$(cw_consult_topic_dir "$TOPIC")"
# Resolve consult artifact dir: prefer live `_consult/`, fall back to most-recent
# archived `_consult-<timestamp>/`. Mirrors bin/spec-init.sh's archive-glob
# (the v0.12.0 split made /spec consume archived consults; this script needs
# to follow). Also try the archive root in case the live state was already
# torn down (typical post-consult run).
ART_DIR=""
if [[ -d "$TOPIC_DIR/_consult/design-doc" ]]; then
  ART_DIR="$TOPIC_DIR/_consult"
else
  # Search live state's archived consult dirs first, then the archive root.
  REPO_HASH=$(cw_repo_hash)
  STATE_ROOT=$(cw_state_root)
  for parent in "$TOPIC_DIR" "$STATE_ROOT/archive/$REPO_HASH/$TOPIC"; do
    [[ -d "$parent" ]] || continue
    candidate=$(find "$parent" -maxdepth 1 -type d -name '_consult-*' \
                  -printf '%T@ %p\n' 2>/dev/null \
                | sort -n | tail -1 | cut -d' ' -f2-)
    if [[ -n "$candidate" && -d "$candidate/design-doc" ]]; then
      ART_DIR="$candidate"
      TOPIC_DIR="$parent"
      break
    fi
  done
fi
[[ -n "$ART_DIR" ]] || { log_error "design-doc dir not found under $TOPIC_DIR (live _consult/ or archived _consult-<ts>/) — run Step 2 walk first"; exit 1; }
DD_DIR="$ART_DIR/design-doc"

# Slug = topic with leading "consult-" stripped.
SLUG="${TOPIC#consult-}"
[[ -n "$SLUG" && "$SLUG" != "$TOPIC" ]] || { log_error "topic '$TOPIC' missing 'consult-' prefix"; exit 2; }

# Title — Title-Case the slug as fallback; full topic.txt overrides via the helper.
TITLE=$(printf '%s' "$SLUG" | tr '-' ' ' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))} 1')

# Derive 6-char hash from full topic-text (when available) for filename
# uniqueness across same-day topics that share the truncated slug.
TOPIC_TEXT_FILE="$ART_DIR/topic.txt"
TOPIC_TEXT=""
HASH6=""
if [[ -f "$TOPIC_TEXT_FILE" ]]; then
  TOPIC_TEXT=$(cat "$TOPIC_TEXT_FILE")
  if command -v sha256sum >/dev/null 2>&1; then
    HASH6=$(printf '%s' "$TOPIC_TEXT" | sha256sum | cut -c1-6)
  elif command -v shasum >/dev/null 2>&1; then
    HASH6=$(printf '%s' "$TOPIC_TEXT" | shasum -a 256 | cut -c1-6)
  fi
fi

OUT_REL=$(cw_consult_design_doc_filename "$SLUG" "$HASH6") || exit $?
REPO_ROOT=$(cw_repo_root 2>/dev/null || pwd)
OUT_ABS="$REPO_ROOT/$OUT_REL"

# Refuse silent overwrite of the final path.
if [[ -e "$OUT_ABS" ]]; then
  log_error "$OUT_REL already exists; remove or rename before re-running"
  exit 1
fi

mkdir -p "$(dirname "$OUT_ABS")"

# Atomic write: assemble to temp file beside OUT_ABS.
OUT_TMP="${OUT_ABS}.tmp.$$"
# Always clean up the temp on any exit.
trap 'rm -f "$OUT_TMP"' EXIT

SYNTHESIS_FILE="$ART_DIR/synthesis.md"
SYNTH_PATH=""
[[ -f "$SYNTHESIS_FILE" ]] && SYNTH_PATH="$SYNTHESIS_FILE"

# v0.14.0: always assemble the flat 5-section output
# (architecture / components / data-flow / error-handling / testing).
# Hub-mode (targets.txt + dag/xrepo-deps/acceptance-tests validators) was
# removed; pass an empty 6th arg for flat-mode behavior.
cw_consult_design_doc_assemble \
  "$DD_DIR" "$OUT_TMP" "$TITLE" \
  "$TOPIC_TEXT" "$SYNTH_PATH" \
  "" \
  || { log_error "assemble failed"; exit 1; }

# v0.10: when the directive's hub-detection block selected a sub-repo, it
# exports CW_CONSULT_TARGET_HEADER (e.g. "**Target Sub-Project:** ARS-Perfusion").
# Validate the slug and prepend the header as the second non-blank line — the
# audit gate in deploy-init looks for it right after the # <title> line.
if [[ -n "${CW_CONSULT_TARGET_HEADER:-}" ]]; then
  CW_TARGET_SLUG=$(printf '%s' "$CW_CONSULT_TARGET_HEADER" \
    | sed -E 's/^\*\*Target Sub-Project:\*\*[[:space:]]+([^[:space:]]+).*/\1/')
  if [[ ! "$CW_TARGET_SLUG" =~ ^${CW_SLUG_REGEX_BASE}$ ]]; then
    log_error "spec-assemble: invalid Target Sub-Project slug '$CW_TARGET_SLUG' from CW_CONSULT_TARGET_HEADER"
    exit 1
  fi
  awk -v hdr="$CW_CONSULT_TARGET_HEADER" '
    BEGIN { inserted = 0 }
    /^# / && !inserted { print; print ""; print hdr; inserted = 1; next }
    { print }
  ' "$OUT_TMP" > "$OUT_TMP.hdr" && mv "$OUT_TMP.hdr" "$OUT_TMP"
fi

if ! cw_consult_design_doc_self_review "$OUT_TMP" 2>"$OUT_TMP.errs"; then
  log_error "self-review found placeholders:"
  while IFS= read -r line; do log_error "  $line"; done < "$OUT_TMP.errs"
  log_error "fix the offending sections (Step 8.5 will re-present them) then re-run"
  rm -f "$OUT_TMP.errs"
  # OUT_TMP cleaned by EXIT trap; final OUT_ABS never created.
  exit 1
fi
rm -f "$OUT_TMP.errs"

# Self-review clean → atomic mv to final path. mv on the same filesystem is
# rename-only and atomic; the EXIT trap's rm -f on OUT_TMP is now a no-op.
mv "$OUT_TMP" "$OUT_ABS" || { log_error "mv $OUT_TMP $OUT_ABS failed"; exit 1; }

if [[ "${CW_DESIGN_DOC_NO_COMMIT:-0}" != "1" ]]; then
  if ! (cd "$REPO_ROOT" && \
        git add "$OUT_REL" >/dev/null && \
        git commit -m "docs(consult): add design doc for $SLUG" >/dev/null); then
    log_error "git commit failed; design.md is written but uncommitted at $OUT_REL"
    exit 1
  fi
fi

log_info "[design-doc] wrote and committed $OUT_REL"
echo "$OUT_REL"
