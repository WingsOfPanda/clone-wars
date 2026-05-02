#!/usr/bin/env bash
# bin/execute-design-init.sh — derive topic slug, create _execute/, copy
# design doc, create feat/exec-<topic> branch (unless --no-branch).
# Prints the topic slug on stdout.
#
# Usage:
#   bin/execute-design-init.sh [--no-branch] [--branch <name>] [--topic <slug>] <design-path>

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/argsfile.sh"
source "$PLUGIN_ROOT/lib/consult.sh"     # cw_consult_outbox_match_endbyte (later)
source "$PLUGIN_ROOT/lib/execute_design.sh"

# --args-file passthrough (mirrors bin/spawn.sh / bin/send.sh).
if [[ "${1:-}" == "--args-file" ]]; then
  [[ -n "${2:-}" ]] || { echo "--args-file requires a path" >&2; exit 2; }
  args_file="$2"; shift 2
  mapfile -t _TOKENS < <(cw_args_file_load "$args_file")
  set -- "${_TOKENS[@]}" "$@"
fi

NO_BRANCH=0
BRANCH_OVERRIDE=""
TOPIC_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-branch)  NO_BRANCH=1; shift ;;
    --branch)     BRANCH_OVERRIDE="$2"; shift 2 ;;
    --topic)      TOPIC_OVERRIDE="$2"; shift 2 ;;
    --) shift; break ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *)  break ;;
  esac
done

[[ $# -eq 1 ]] || { echo "Usage: $0 [--no-branch] [--branch <n>] [--topic <slug>] <design-path>" >&2; exit 2; }
DESIGN_PATH="$1"
[[ -f "$DESIGN_PATH" && -r "$DESIGN_PATH" ]] || { log_error "design doc unreadable: $DESIGN_PATH"; exit 1; }

# Derive topic
if [[ -n "$TOPIC_OVERRIDE" ]]; then
  TOPIC="$TOPIC_OVERRIDE"
else
  TOPIC=$(cw_execute_design_derive_topic "$DESIGN_PATH")
  [[ -n "$TOPIC" ]] || { log_error "could not derive topic from filename; pass --topic <slug>"; exit 1; }
fi
cw_execute_design_assert_topic "$TOPIC"

TOPIC_DIR="$(cw_execute_design_topic_dir "$TOPIC")"
ART_DIR="$(cw_execute_design_art_dir "$TOPIC")"
[[ ! -d "$ART_DIR" ]] || { log_error "topic _execute dir already exists: $ART_DIR (pick a different --topic or run teardown)"; exit 1; }

mkdir -p "$ART_DIR"
cp "$DESIGN_PATH" "$ART_DIR/design.md"
printf '%s' "$TOPIC" > "$ART_DIR/topic.txt"

# Branch
if (( NO_BRANCH == 0 )); then
  if branch=$(cw_execute_design_branch_create "$TOPIC" "$BRANCH_OVERRIDE"); then
    log_info "branch: $branch"
  else
    log_error "branch creation failed; remove $ART_DIR or pass --no-branch and retry"
    exit 1
  fi
fi

log_info "topic:        $TOPIC"
log_info "  artifacts:  $ART_DIR"
log_info "  design.md:  $ART_DIR/design.md"

printf '%s\n' "$TOPIC"
