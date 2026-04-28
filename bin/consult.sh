#!/usr/bin/env bash
# bin/consult.sh — orchestrate /clone-wars:consult Phases 1-5.
# Writes adjudicated.md with PENDING items; the slash directive drives the
# conductor through PENDING resolution; bin/consult-finalize.sh handles 6-7.
#
# This is the v0.1.0 skeleton: arg parsing, slug derivation, conflict
# resolver, dry-run path, and exit. Phases 1-5 land in subsequent commits.

set -uo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deps.sh"
source "$PLUGIN_ROOT/lib/contracts.sh"
source "$PLUGIN_ROOT/lib/commanders.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/tmux.sh"
source "$PLUGIN_ROOT/lib/argsfile.sh"
source "$PLUGIN_ROOT/lib/consult.sh"

# --args-file <path> — read tokens from <path> and replace positional args.
# Used by commands/*.md to fence off shell injection from $ARGUMENTS.
if [[ "${1:-}" == "--args-file" ]]; then
  [[ -n "${2:-}" ]] || { echo "--args-file requires a path" >&2; exit 2; }
  args_file="$2"; shift 2
  mapfile -t _TOKENS < <(cw_args_file_load "$args_file")
  set -- "${_TOKENS[@]}" "$@"
fi

usage() { echo "Usage: $0 <topic>" >&2; }

[[ $# -ge 1 ]] || { usage; exit 2; }
TOPIC_TEXT="$*"

# ---------------------------------------------------------- Slug derivation
# Cap base slug to 20 chars so consult-<base>-NNN <= 32 (spawn.sh's limit).
# 8 ("consult-") + 20 (base) + 4 ("-999") = 32 exactly.
SLUG_BASE=$(printf '%s' "$TOPIC_TEXT" \
  | tr '[:upper:]' '[:lower:]' \
  | tr -c 'a-z0-9-' '-' \
  | sed 's/--*/-/g; s/^-//; s/-$//' \
  | cut -c1-20 \
  | sed 's/-$//')
[[ -n "$SLUG_BASE" ]] || { log_error "topic produced empty slug; provide alphanumerics"; exit 2; }

CONSULT_TOPIC="consult-$SLUG_BASE"
TOPIC_DIR="$(cw_state_root)/state/$(cw_repo_hash)/$CONSULT_TOPIC"
n=2
while [[ -d "$TOPIC_DIR" ]]; do
  if (( n > 999 )); then
    log_error "more than 999 prior consults on slug '$SLUG_BASE'; pick a different topic"
    exit 1
  fi
  CONSULT_TOPIC="consult-$SLUG_BASE-$n"
  TOPIC_DIR="$(cw_state_root)/state/$(cw_repo_hash)/$CONSULT_TOPIC"
  n=$((n + 1))
done

mkdir -p "$TOPIC_DIR/_consult"
ART_DIR="$TOPIC_DIR/_consult"
# Save topic text for finalize to recover later.
printf '%s' "$TOPIC_TEXT" > "$ART_DIR/topic.txt"

# Print resolved topic on STDOUT (not via log_info, which goes to stderr) so
# tests can capture it cleanly without mixing log noise. Other progress lines
# stay on stderr.
printf 'consultation topic: %s\n' "$CONSULT_TOPIC"
log_info "  artifacts dir: $ART_DIR"

# Dry-run path (test harness): print and exit before spawning.
if [[ "${CW_CONSULT_DRY_RUN:-0}" == "1" ]]; then
  exit 0
fi

# ---------------------------------------------------------- Phase 1 spawn

REX=rex; CODY=cody
log_info "[Phase 1] spawning $REX-codex"
"$PLUGIN_ROOT/bin/spawn.sh" "$REX" codex "$CONSULT_TOPIC" >/dev/null \
  || { log_error "rex spawn failed"; exit 1; }

log_info "[Phase 1] spawning $CODY-claude"
if ! "$PLUGIN_ROOT/bin/spawn.sh" "$CODY" claude "$CONSULT_TOPIC" >/dev/null; then
  log_error "cody spawn failed; tearing down rex"
  "$PLUGIN_ROOT/bin/teardown.sh" "$REX" "$CONSULT_TOPIC" >/dev/null 2>&1 || true
  exit 1
fi
log_ok "both troopers ready"

REX_DIR=$(cw_trooper_dir  "$REX"  codex  "$CONSULT_TOPIC")
CODY_DIR=$(cw_trooper_dir "$CODY" claude "$CONSULT_TOPIC")

# ---------------------------------------------------------- Phase 2 research

log_info "[Phase 2] dispatching research to both troopers"

REX_PROMPT="$ART_DIR/rex_research_prompt.md"
CODY_PROMPT="$ART_DIR/cody_research_prompt.md"
cw_consult_build_research_prompt "$TOPIC_TEXT" "$REX_DIR/findings.md"  > "$REX_PROMPT"
cw_consult_build_research_prompt "$TOPIC_TEXT" "$CODY_DIR/findings.md" > "$CODY_PROMPT"

REX_OUTBOX=$(cw_outbox_path  "$REX"  codex  "$CONSULT_TOPIC")
CODY_OUTBOX=$(cw_outbox_path "$CODY" claude "$CONSULT_TOPIC")
REX_OFFSET=$(stat -c '%s' "$REX_OUTBOX")
CODY_OFFSET=$(stat -c '%s' "$CODY_OUTBOX")

REX_SEND_OK=1; CODY_SEND_OK=1
if ! "$PLUGIN_ROOT/bin/send.sh" "$REX"  "$CONSULT_TOPIC" "@$REX_PROMPT"  >/dev/null; then
  log_error "[Phase 2] rex send failed"
  REX_SEND_OK=0
fi
if ! "$PLUGIN_ROOT/bin/send.sh" "$CODY" "$CONSULT_TOPIC" "@$CODY_PROMPT" >/dev/null; then
  log_error "[Phase 2] cody send failed"
  CODY_SEND_OK=0
fi

if (( REX_SEND_OK == 0 && CODY_SEND_OK == 0 )); then
  log_error "[Phase 2] both research sends failed; tearing down"
  "$PLUGIN_ROOT/bin/teardown.sh" "$CONSULT_TOPIC" >/dev/null 2>&1 || true
  exit 1
fi

# Wait for both done events past their pre-send offsets.
RESEARCH_TIMEOUT=$(cw_consult_timeout research)
log_info "[Phase 2] waiting up to ${RESEARCH_TIMEOUT}s for both done events"

cat > "$ART_DIR/wait_research.txt" <<EOF
$REX:codex:$CONSULT_TOPIC:$REX_OFFSET
$CODY:claude:$CONSULT_TOPIC:$CODY_OFFSET
EOF

if ! cw_outbox_wait_all "$ART_DIR/wait_research.txt" done error "$RESEARCH_TIMEOUT"; then
  log_error "[Phase 2] timeout or error before both troopers reported done"
  "$PLUGIN_ROOT/bin/teardown.sh" "$CONSULT_TOPIC" >/dev/null 2>&1 || true
  exit 1
fi

REX_FS=$(cw_consult_findings_status  "$REX_DIR/findings.md")
CODY_FS=$(cw_consult_findings_status "$CODY_DIR/findings.md")

if [[ "$REX_FS" == "missing" && "$CODY_FS" == "missing" ]]; then
  log_error "[Phase 2] neither trooper produced findings.md; tearing down"
  "$PLUGIN_ROOT/bin/teardown.sh" "$CONSULT_TOPIC" >/dev/null 2>&1 || true
  exit 1
fi

# Persist statuses for finalize.
cat > "$ART_DIR/research_status.txt" <<EOF
REX_FS=$REX_FS
CODY_FS=$CODY_FS
EOF

log_ok "[Phase 2] research complete (rex=$REX_FS, cody=$CODY_FS)"

# (Phase 3 + 4 + 5 in subsequent commits.)
exit 0
