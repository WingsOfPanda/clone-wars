#!/usr/bin/env bash
# bin/consult-verify-send.sh — Phase 4 dispatch for one commander.
# Master Yoda invokes 2x (or 3x) in parallel.
#
# Usage: bin/consult-verify-send.sh <consult-topic> <commander> <model>
#
# v0.15.0: verify scope = union of all bucket files in _consult/ where this
# trooper is NOT a member.
#
# For trooper T with commander $COMMANDER:
#   - SKIP `consensus.txt` (T IS a member; auto-CONSENSUS, no verify needed)
#   - INCLUDE `<X>_only_items.txt` for every X != T   (single-only's of others)
#   - INCLUDE `<A>+<B>_only.txt` for every pair where T ∉ {A,B} (pair-only's not containing T)
#
# For N=2 (rex+cody only) this reduces to a single file: the OTHER commander's
# _only_items.txt — byte-equal to v0.14.0 behavior.
# For N=3 (rex+cody+bly) this is 3 files (1 single + 1 single + 1 pair).
#
# If the union is empty → writes VS=skipped (no actual send). Else writes
# OFFSET= and sends.

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/consult.sh"

[[ $# -eq 3 ]] || { echo "Usage: $0 <consult-topic> <commander> <model>" >&2; exit 2; }
TOPIC="$1"; COMMANDER="$2"; MODEL="$3"

cw_consult_assert_topic "$TOPIC"
cw_consult_assert_commander "$COMMANDER"
[[ "$MODEL" =~ ^[a-z0-9_-]+$ ]]    || { log_error "invalid model: $MODEL"; exit 2; }

ART_DIR="$(cw_consult_art_dir "$TOPIC")"
[[ -d "$ART_DIR" ]] || { log_error "$ART_DIR not found"; exit 1; }

STATE_FILE="$ART_DIR/verify-$COMMANDER.txt"
[[ ! -e "$STATE_FILE" ]] || {
  log_error "$STATE_FILE already exists; reset with: bin/consult-offset-reset.sh $TOPIC $COMMANDER verify"
  exit 1
}

# Discover commanders from _consult/troopers.txt. With v0.15.0, consult-init
# always writes this file before any verify runs.
TROOPERS_FILE="$ART_DIR/troopers.txt"
[[ -f "$TROOPERS_FILE" ]] || { log_error "troopers.txt missing — run consult-init first"; exit 1; }

COMMANDERS=()
while IFS=$'\t' read -r _prov cmdr; do
  [[ -n "$cmdr" ]] || continue
  COMMANDERS+=("$cmdr")
done < <(cw_consult_load_troopers "$TROOPERS_FILE")
(( ${#COMMANDERS[@]} >= 2 )) || { log_error "need >=2 troopers in troopers.txt, got ${#COMMANDERS[@]}"; exit 1; }

# Verify $COMMANDER is one of the listed troopers.
KNOWN=0
for c in "${COMMANDERS[@]}"; do
  [[ "$c" == "$COMMANDER" ]] && { KNOWN=1; break; }
done
(( KNOWN == 1 )) || { log_error "$COMMANDER not listed in troopers.txt"; exit 1; }

# Build the include-list of bucket files where $COMMANDER is NOT a member.
INCLUDE_FILES=()

# Single-only buckets: include every commander != $COMMANDER.
for c in "${COMMANDERS[@]}"; do
  [[ "$c" == "$COMMANDER" ]] && continue
  f="$ART_DIR/${c}_only_items.txt"
  [[ -f "$f" ]] || { log_error "expected bucket file missing: $f (run consult-diff first)"; exit 1; }
  [[ -s "$f" ]] && INCLUDE_FILES+=("$f")
done

# Pair-only buckets (only exist for N>=3): include every (a,b) where $COMMANDER ∉ {a,b}.
n=${#COMMANDERS[@]}
if (( n >= 3 )); then
  for ((i = 0; i < n; i++)); do
    for ((j = i + 1; j < n; j++)); do
      a="${COMMANDERS[$i]}"; b="${COMMANDERS[$j]}"
      [[ "$a" == "$COMMANDER" || "$b" == "$COMMANDER" ]] && continue
      f="$ART_DIR/${a}+${b}_only.txt"
      [[ -f "$f" ]] || { log_error "expected pair bucket missing: $f (run consult-diff first)"; exit 1; }
      [[ -s "$f" ]] && INCLUDE_FILES+=("$f")
    done
  done
fi

# Concatenate the includes into a single verify-claims-<COMMANDER>.txt.
# This file is what we hand to cw_consult_build_verify_prompt.
VERIFY_CLAIMS="$ART_DIR/verify-claims-${COMMANDER}.txt"
: > "$VERIFY_CLAIMS"
if (( ${#INCLUDE_FILES[@]} > 0 )); then
  cat "${INCLUDE_FILES[@]}" > "$VERIFY_CLAIMS"
fi

if [[ ! -s "$VERIFY_CLAIMS" ]]; then
  printf 'VS=skipped\n' > "$STATE_FILE"
  log_info "[verify-send] $COMMANDER VS=skipped (no claims to verify)"
  exit 0
fi

TROOPER_DIR=$(cw_trooper_dir "$COMMANDER" "$MODEL" "$TOPIC")
OUTBOX="$TROOPER_DIR/outbox.jsonl"
[[ -f "$OUTBOX" ]] || { log_error "outbox not found at $OUTBOX"; exit 1; }

PROMPT_FILE="$ART_DIR/${COMMANDER}_verify_prompt.md"
BASE_PROMPT=$(cw_consult_build_verify_prompt \
  "$VERIFY_CLAIMS" "$TROOPER_DIR/verify.md")
cw_consult_skill_hint_append "$ART_DIR/skill.txt" "$BASE_PROMPT" > "$PROMPT_FILE"

OFFSET=$(wc -c < "$OUTBOX" | tr -d ' ')
printf 'OFFSET=%s\n' "$OFFSET" > "$STATE_FILE"

if ! "$PLUGIN_ROOT/bin/send.sh" "$COMMANDER" "$TOPIC" "@$PROMPT_FILE" >/dev/null; then
  log_error "send.sh failed; state file kept for retry"
  exit 1
fi

log_info "[verify-send] $COMMANDER offset=$OFFSET items=$(wc -l < "$VERIFY_CLAIMS") buckets=${#INCLUDE_FILES[@]}"
