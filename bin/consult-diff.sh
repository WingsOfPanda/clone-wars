#!/usr/bin/env bash
# bin/consult-diff.sh — N-way Venn bucketer over per-trooper findings.
#
# Usage: bin/consult-diff.sh <consult-topic>
#
# Reads _consult/troopers.txt (TSV: <provider>\t<commander>) to discover N
# troopers, then dispatches to cw_consult_diff which emits:
#   _consult/diff.md
#   _consult/<commander>_only_items.txt  (one per trooper, always written)
# For N>=3 additionally:
#   _consult/consensus.txt
#   _consult/<a>+<b>_only.txt            (one per trooper pair, always written)
#
# Refuses if diff.md exists (caller must reset to retry).

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
[[ ! -e "$ART_DIR/diff.md" ]] || { log_error "diff.md exists; reset to retry"; exit 1; }

TROOPERS_FILE="$ART_DIR/troopers.txt"
[[ -f "$TROOPERS_FILE" ]] || { log_error "troopers.txt missing — run consult-init first"; exit 1; }

# Build the variadic argument list: <commander>:<findings.md>
DIFF_ARGS=()
LABELS=()
while IFS=$'\t' read -r provider commander; do
  [[ -n "$provider" && -n "$commander" ]] || continue
  TROOPER_DIR=$(cw_trooper_dir "$commander" "$provider" "$TOPIC")
  FINDINGS="$TROOPER_DIR/findings.md"
  [[ -f "$FINDINGS" ]] || { log_error "$commander findings.md missing: $FINDINGS"; exit 1; }
  DIFF_ARGS+=("$commander:$FINDINGS")
  LABELS+=("$commander")
done < <(cw_consult_load_troopers "$TROOPERS_FILE")

(( ${#DIFF_ARGS[@]} >= 2 )) || { log_error "need >=2 troopers in troopers.txt, got ${#DIFF_ARGS[@]}"; exit 1; }

cw_consult_diff "$ART_DIR" "${DIFF_ARGS[@]}"

# Compose a one-line summary of items-per-bucket.
SUMMARY=""
for commander in "${LABELS[@]}"; do
  f="$ART_DIR/${commander}_only_items.txt"
  n=$([[ -f "$f" ]] && wc -l < "$f" || echo 0)
  SUMMARY+=" ${commander}_only=${n}"
done
if (( ${#LABELS[@]} >= 3 )); then
  c=$([[ -f "$ART_DIR/consensus.txt" ]] && wc -l < "$ART_DIR/consensus.txt" || echo 0)
  SUMMARY+=" consensus=${c}"
fi

log_info "[diff] wrote $ART_DIR/diff.md (${#LABELS[@]} troopers)${SUMMARY}"
