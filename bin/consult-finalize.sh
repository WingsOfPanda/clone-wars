#!/usr/bin/env bash
# bin/consult-finalize.sh — Phases 6-7 of /clone-wars:consult.
# Reads adjudicated.md (must be PENDING-free), writes synthesis.md, tears
# down the trooper panes via bin/teardown.sh, then archives the _consult/
# sibling dir alongside the (now-archived) trooper state.

set -uo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/consult.sh"

usage() { echo "Usage: $0 <consult-topic>" >&2; }

[[ $# -ge 1 ]] || { usage; exit 2; }
CONSULT_TOPIC="$1"

# Validate topic to block path traversal: must match ^[A-Za-z0-9_.-]+$ and
# not begin with '-' or '.'. The slug builder in bin/consult.sh always emits
# `consult-<lowercase-alnum-hyphen>`, so legitimate topics easily satisfy this.
if [[ -z "$CONSULT_TOPIC" \
   || "$CONSULT_TOPIC" == .* \
   || "$CONSULT_TOPIC" == -* \
   || "$CONSULT_TOPIC" == */* \
   || ! "$CONSULT_TOPIC" =~ ^[A-Za-z0-9_.-]+$ ]]; then
  log_error "invalid topic '$CONSULT_TOPIC' — must match ^[A-Za-z0-9_.-]+\$ and not begin with '.' or '-'"
  exit 2
fi

TOPIC_DIR="$(cw_state_root)/state/$(cw_repo_hash)/$CONSULT_TOPIC"
ART_DIR="$TOPIC_DIR/_consult"

[[ -d "$ART_DIR" ]] || { log_error "$ART_DIR not found — was bin/consult.sh run?"; exit 1; }
ADJ="$ART_DIR/adjudicated.md"
DIFF="$ART_DIR/diff.md"
TOPIC_TEXT_FILE="$ART_DIR/topic.txt"

[[ -f "$ADJ" ]]              || { log_error "adjudicated.md not found"; exit 1; }
[[ -f "$DIFF" ]]             || { log_error "diff.md not found"; exit 1; }
[[ -f "$TOPIC_TEXT_FILE" ]]  || { log_error "topic.txt not found"; exit 1; }

# Refuse to finalize while PENDING items remain.
if grep -q '^- PENDING:' "$ADJ"; then
  log_error "adjudicated.md still has PENDING items — conductor must resolve them first"
  log_error "  open: $ADJ"
  exit 1
fi

# Load statuses (set by Phase 2 / Phase 4). The status files are written by
# bin/consult.sh in this same plugin (lines like "REX_FS=ok"); they live
# inside $CLONE_WARS_HOME, which the conductor controls. We still parse
# defensively rather than `source`ing arbitrary shell to keep the surface
# narrow — only KEY=VALUE pairs with whitelisted keys/values are honored.
REX_FS=missing; CODY_FS=missing; REX_VS=skipped; CODY_VS=skipped
_cw_load_status() {
  local file="$1" key val
  [[ -f "$file" ]] || return 0
  while IFS='=' read -r key val; do
    # Strip surrounding whitespace and any quoting.
    key="${key//[[:space:]]/}"
    val="${val//[[:space:]]/}"
    val="${val#\"}"; val="${val%\"}"
    val="${val#\'}"; val="${val%\'}"
    case "$key" in
      REX_FS|CODY_FS|REX_VS|CODY_VS)
        # Only allow expected status tokens.
        case "$val" in
          ok|empty|malformed|missing|timeout|error|send-failed|skipped|pending)
            printf -v "$key" '%s' "$val"
            ;;
          *) log_warn "ignoring unrecognized status value $key='$val' in $file" ;;
        esac
        ;;
      ''|\#*) ;;  # blank lines and comments
      *) log_warn "ignoring unknown key '$key' in $file" ;;
    esac
  done < "$file"
}
_cw_load_status "$ART_DIR/research_status.txt"
_cw_load_status "$ART_DIR/verify_status.txt"

TOPIC_TEXT=$(cat "$TOPIC_TEXT_FILE")
REX_DIR=$(cw_trooper_dir  rex  codex  "$CONSULT_TOPIC")
CODY_DIR=$(cw_trooper_dir cody claude "$CONSULT_TOPIC")

SYN="$ART_DIR/synthesis.md"
log_info "[Phase 6] synthesizing report"
cw_consult_synthesize "$TOPIC_TEXT" "$DIFF" "$ADJ" "$REX_DIR" "$CODY_DIR" \
  "$REX_FS" "$CODY_FS" "$REX_VS" "$CODY_VS" "$SYN"

# Print the final synthesis.
cat <<EOF

============================================================
  CONSULTATION REPORT
============================================================
EOF
cat "$SYN"
cat <<EOF
============================================================

EOF

ARCHIVE_BASE="$(cw_state_root)/archive/$(cw_repo_hash)/$CONSULT_TOPIC"
TS=$(date -u +'%Y%m%dT%H%M%SZ')

if [[ "${CW_CONSULT_FINALIZE_NO_TEARDOWN:-0}" == "1" ]]; then
  # Test-seam path: don't run teardown.sh (it would try to kill panes that
  # don't exist), but DO produce the same forensic record as production by
  # COPYING _consult/ into archive. The original tree is left in place so
  # tests can inspect both the live and archived copies.
  log_info "[Phase 7] CW_CONSULT_FINALIZE_NO_TEARDOWN=1 — copying _consult/ to archive (test seam)"
  mkdir -p "$ARCHIVE_BASE"
  cp -r "$ART_DIR" "$ARCHIVE_BASE/_consult-$TS"
  exit 0
fi

log_info "[Phase 7] tearing down trooper panes"
"$PLUGIN_ROOT/bin/teardown.sh" "$CONSULT_TOPIC" >/dev/null 2>&1 || true

# After teardown, the trooper subdirs are archived by bin/teardown.sh, but
# _consult/ is a sibling that teardown doesn't know about. Move it ourselves
# into the same archive root so the entire consult is one forensic record.
if [[ -d "$ART_DIR" ]]; then
  mkdir -p "$ARCHIVE_BASE"
  mv "$ART_DIR" "$ARCHIVE_BASE/_consult-$TS"
  rmdir "$TOPIC_DIR" 2>/dev/null || true
fi
log_ok "consultation $CONSULT_TOPIC complete; archive: $ARCHIVE_BASE"
