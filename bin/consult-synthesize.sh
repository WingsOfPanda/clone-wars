#!/usr/bin/env bash
# bin/consult-synthesize.sh — write synthesis.md after PENDING resolution.
#
# Usage: bin/consult-synthesize.sh <consult-topic>
#
# Refuses if adjudicated.md missing OR contains any ^- PENDING: line OR
# synthesis.md already exists.

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

SYN="$ART_DIR/synthesis.md"
[[ ! -e "$SYN" ]] || { log_error "$SYN already exists; rm to regenerate"; exit 1; }

# Load statuses with safe fallbacks.
REX_FS=missing; CODY_FS=missing; REX_VS=skipped; CODY_VS=skipped
if [[ -f "$ART_DIR/research-rex.txt"  ]]; then REX_FS=$(awk -F= '/^FS=/{print $2}'  "$ART_DIR/research-rex.txt");  : "${REX_FS:=missing}"; fi
if [[ -f "$ART_DIR/research-cody.txt" ]]; then CODY_FS=$(awk -F= '/^FS=/{print $2}' "$ART_DIR/research-cody.txt"); : "${CODY_FS:=missing}"; fi
if [[ -f "$ART_DIR/verify-rex.txt"    ]]; then REX_VS=$(awk -F= '/^VS=/{print $2}'  "$ART_DIR/verify-rex.txt");   : "${REX_VS:=skipped}"; fi
if [[ -f "$ART_DIR/verify-cody.txt"   ]]; then CODY_VS=$(awk -F= '/^VS=/{print $2}' "$ART_DIR/verify-cody.txt");  : "${CODY_VS:=skipped}"; fi

TOPIC_TEXT=$(cat "$ART_DIR/topic.txt")
DIFF="$ART_DIR/diff.md"
REX_DIR=$(cw_trooper_dir rex codex "$TOPIC")
CODY_DIR=$(cw_trooper_dir cody claude "$TOPIC")

cw_consult_synthesize "$TOPIC_TEXT" "$DIFF" "$ADJ" "$REX_DIR" "$CODY_DIR" \
  "$REX_FS" "$CODY_FS" "$REX_VS" "$CODY_VS" "$SYN"

# Findings-conformance metric (#8) — persisted for manual aggregation across
# runs. Informs v0.12+ decisions about whether the question-protocol heuristic
# (active-subproject inference) needs upgrading to an explicit trooper-side
# `subproject` field. Single-repo runs record n/a so trend queries can filter.
HUB_MODE=$(cw_consult_hub_mode_load "$ART_DIR" 2>/dev/null || echo single-repo)
{
  for c in rex cody; do
    case "$c" in
      rex)  M=codex  ;;
      cody) M=claude ;;
    esac
    F="$(cw_trooper_dir "$c" "$M" "$TOPIC")/findings.md"
    if [[ "$HUB_MODE" == "single-repo" ]]; then
      printf '%s=n/a\n' "$c"
    elif cw_consult_findings_active_subproject "$F" > /dev/null 2>&1; then
      printf '%s=conformant\n' "$c"
    else
      printf '%s=non-conformant\n' "$c"
    fi
  done
} > "$ART_DIR/findings-conformance.txt" \
  || log_warn "findings-conformance.txt write failed (non-fatal)"

log_info "[synthesize] wrote $SYN"
cat "$SYN"
