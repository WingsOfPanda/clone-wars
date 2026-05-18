#!/usr/bin/env bash
# bin/deep-research-teardown.sh — archive a /clone-wars:deep-research topic state dir.
#
# Usage: bin/deep-research-teardown.sh <topic>
#
# Per-round commander panes are torn down inline by the directive via
# bin/teardown.sh --pairs after each round (batched 9s graceful banner).
# This script handles the final archive of the entire topic state dir to
# ~/.clone-wars/archive/. Parallels bin/meditate-teardown.sh.

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/deep-research.sh"
source "$PLUGIN_ROOT/lib/tmux.sh"

[[ $# -eq 1 ]] || { echo "Usage: $0 <topic>" >&2; exit 2; }
TOPIC="$1"
cw_deep_research_assert_topic "$TOPIC"

TOPIC_DIR="$(cw_topic_state_dir "$TOPIC")"
[[ -d "$TOPIC_DIR" ]] || { log_error "$TOPIC_DIR not found"; exit 1; }

# v0.29.0: shared helper handles 1-col troopers.txt parse + orphan kill +
# cleanup. No-op if preflight-panes.txt is absent (pre-v0.28.3 archives +
# happy-path runs where the file was already removed elsewhere).
ART_DIR="$TOPIC_DIR/_deep-research"
TROOPERS_FILE="$ART_DIR/troopers.txt"
cw_teardown_with_preflight_orphans "$ART_DIR" "$TROOPERS_FILE" 1col

# v0.43.0 Lane B: sweep shared/ orphans before the archive mv.
# *.tmp + *.lock are the known atomic-write / fcntl-flock leak shapes.
# Scoped to shared/ (depth 2) so trooper experiment dirs are untouched.
if [[ -d "$ART_DIR/shared" ]]; then
  find "$ART_DIR/shared" -maxdepth 2 \( -name '*.tmp' -o -name '*.lock' \) -delete 2>/dev/null || true
fi

# v0.43.0 Lane B: winner symlink. Reads scoreboard.md's top-1 ok row
# (highest-rank with status=ok) and creates _deep-research/winner ->
# troopers/<cmdr>/experiments/<exp-id>/code (relative; survives the mv).
SCOREBOARD="$ART_DIR/scoreboard.md"
if [[ -f "$SCOREBOARD" ]]; then
  # awk: skip header rows; first row with $6 == "ok" wins.
  # Table shape: | Rank | Experiment | Commander | Metric | Status | ...
  read -r WIN_CMDR WIN_EXP < <(awk -F'|' '
    /^\| *[0-9]+ *\|/ {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $3)  # exp
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $4)  # cmdr
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $6)  # status
      if ($6 == "ok") { print $4, $3; exit }
    }
  ' "$SCOREBOARD")
  if [[ -n "${WIN_CMDR:-}" && -n "${WIN_EXP:-}" ]]; then
    WIN_TARGET="troopers/$WIN_CMDR/experiments/$WIN_EXP/code"
    if [[ -d "$ART_DIR/$WIN_TARGET" ]]; then
      ln -sfn "$WIN_TARGET" "$ART_DIR/winner"
      log_ok "[teardown] winner symlink → $WIN_TARGET ($WIN_CMDR/$WIN_EXP)"
    else
      log_warn "[teardown] scoreboard top-1 dir missing: $ART_DIR/$WIN_TARGET; no symlink"
    fi
  else
    log_info "[teardown] scoreboard has no ok rows; no winner symlink"
  fi
fi

ts=$(date -u +%Y%m%dT%H%M%SZ)
# v0.38.0: archive is per-MACHINE (global), distinct from per-PROJECT state.
archive_dir="$(cw_global_state_root)/archive/$(cw_repo_hash)/${TOPIC}-${ts}"
mkdir -p "$(dirname "$archive_dir")"
mv "$TOPIC_DIR" "$archive_dir"
log_ok "[teardown] archived $TOPIC → $archive_dir"
printf '%s\n' "$archive_dir"
