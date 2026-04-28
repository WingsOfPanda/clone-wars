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

# ---------------------------------------------------------- Phase 3 diff

log_info "[Phase 3] bucketing claims"
DIFF="$ART_DIR/diff.md"
cw_consult_diff "$REX_DIR/findings.md" "$CODY_DIR/findings.md" "$DIFF"

REX_ONLY="$ART_DIR/rex_only_items.txt"
CODY_ONLY="$ART_DIR/cody_only_items.txt"
awk '/^## Rex-only/{f=1;next}  /^## /{f=0} f && /^- /{ sub(/^- /,""); print }'  "$DIFF" > "$REX_ONLY"
awk '/^## Cody-only/{f=1;next} /^## /{f=0} f && /^- /{ sub(/^- /,""); print }'  "$DIFF" > "$CODY_ONLY"

# ---------------------------------------------------------- Phase 4 verify

REX_VS=skipped; CODY_VS=skipped

if [[ -s "$CODY_ONLY" ]]; then
  REX_VERIFY_PROMPT="$ART_DIR/rex_verify_prompt.md"
  cw_consult_build_verify_prompt "$CODY_ONLY" "$REX_DIR/verify.md" > "$REX_VERIFY_PROMPT"
  REX_OFFSET2=$(stat -c '%s' "$REX_OUTBOX")
  if "$PLUGIN_ROOT/bin/send.sh" "$REX" "$CONSULT_TOPIC" "@$REX_VERIFY_PROMPT" >/dev/null; then
    REX_VS=pending  # provisional; refined after wait
  else
    REX_VS=send-failed
  fi
fi

if [[ -s "$REX_ONLY" ]]; then
  CODY_VERIFY_PROMPT="$ART_DIR/cody_verify_prompt.md"
  cw_consult_build_verify_prompt "$REX_ONLY" "$CODY_DIR/verify.md" > "$CODY_VERIFY_PROMPT"
  CODY_OFFSET2=$(stat -c '%s' "$CODY_OUTBOX")
  if "$PLUGIN_ROOT/bin/send.sh" "$CODY" "$CONSULT_TOPIC" "@$CODY_VERIFY_PROMPT" >/dev/null; then
    CODY_VS=pending
  else
    CODY_VS=send-failed
  fi
fi

# Build wait file ONLY for sides that have a pending dispatch.
> "$ART_DIR/wait_verify.txt"
[[ "$REX_VS"  == pending ]] && echo "$REX:codex:$CONSULT_TOPIC:$REX_OFFSET2"   >> "$ART_DIR/wait_verify.txt"
[[ "$CODY_VS" == pending ]] && echo "$CODY:claude:$CONSULT_TOPIC:$CODY_OFFSET2" >> "$ART_DIR/wait_verify.txt"

if [[ -s "$ART_DIR/wait_verify.txt" ]]; then
  VERIFY_TIMEOUT=$(cw_consult_timeout verify)
  log_info "[Phase 4] waiting up to ${VERIFY_TIMEOUT}s for verify done events"
  if ! cw_outbox_wait_all "$ART_DIR/wait_verify.txt" done error "$VERIFY_TIMEOUT"; then
    log_warn "[Phase 4] one or both verify dispatches timed out — partial cross-verification"
    [[ "$REX_VS"  == pending ]] && [[ ! -s "$REX_DIR/verify.md"  ]] && REX_VS=timeout
    [[ "$CODY_VS" == pending ]] && [[ ! -s "$CODY_DIR/verify.md" ]] && CODY_VS=timeout
  fi
  # Promote pending → ok for sides that produced verify.md.
  [[ "$REX_VS"  == pending ]] && [[ -s "$REX_DIR/verify.md"  ]] && REX_VS=ok
  [[ "$CODY_VS" == pending ]] && [[ -s "$CODY_DIR/verify.md" ]] && CODY_VS=ok
  # Pending without verify.md and not flagged timeout means error or silent miss.
  [[ "$REX_VS"  == pending ]] && REX_VS=missing
  [[ "$CODY_VS" == pending ]] && CODY_VS=missing
else
  log_info "[Phase 4] no cross-verify needed (no Rex-only or Cody-only items)"
fi

cat > "$ART_DIR/verify_status.txt" <<EOF
REX_VS=$REX_VS
CODY_VS=$CODY_VS
EOF

log_ok "[Phase 4] verify status: rex=$REX_VS, cody=$CODY_VS"

# ---------------------------------------------------------- Phase 5 adjudicate

log_info "[Phase 5] writing adjudicated.md (PENDING resolution is the conductor's job)"

ADJ="$ART_DIR/adjudicated.md"
{
  printf '## Cross-verified\n'
  if [[ -f "$CODY_DIR/verify.md" ]]; then
    cw_consult_parse_verdicts "$CODY_DIR/verify.md" \
      | awk -F'\t' '$1 == "AGREE" { printf "- [%s] %s — CODY confirmed: %s\n", $2, $3, $3 }'
  fi
  if [[ -f "$REX_DIR/verify.md" ]]; then
    cw_consult_parse_verdicts "$REX_DIR/verify.md" \
      | awk -F'\t' '$1 == "AGREE" { printf "- [%s] %s — REX confirmed: %s\n", $2, $3, $3 }'
  fi

  printf '\n## Adjudicated\n'
  printf '<!-- conductor: read each cited source for every "PENDING" line below; rewrite the prefix to CONFIRMED, REFUTED, or move to ## Contested. The synthesis tool refuses to finalize while any PENDING remains. -->\n'
  if [[ -f "$CODY_DIR/verify.md" ]]; then
    cw_consult_parse_verdicts "$CODY_DIR/verify.md" \
      | awk -F'\t' '$1 != "AGREE" { printf "- PENDING: [%s] %s — CODY %s: %s\n", $2, $3, $1, $3 }'
  fi
  if [[ -f "$REX_DIR/verify.md" ]]; then
    cw_consult_parse_verdicts "$REX_DIR/verify.md" \
      | awk -F'\t' '$1 != "AGREE" { printf "- PENDING: [%s] %s — REX %s: %s\n", $2, $3, $1, $3 }'
  fi

  printf '\n## Contested\n'
  printf '<!-- conductor: move CONTESTED items here from Adjudicated. Items in this section ship in synthesis as unresolved. -->\n'

  printf '\n## Not-verified\n'
  # If REX_VS != ok and CODY_ONLY had items, list them here (rex was supposed to verify them).
  if [[ "$REX_VS" != "ok" && "$REX_VS" != "skipped" && -s "$CODY_ONLY" ]]; then
    awk -v vs="$REX_VS" '{ printf "- %s — REX verify dispatch %s\n", $0, vs }' "$CODY_ONLY"
  fi
  if [[ "$CODY_VS" != "ok" && "$CODY_VS" != "skipped" && -s "$REX_ONLY" ]]; then
    awk -v vs="$CODY_VS" '{ printf "- %s — CODY verify dispatch %s\n", $0, vs }' "$REX_ONLY"
  fi
} > "$ADJ"

cat <<EOF

============================================================
  CONSULTATION DRAFT (Phases 1-5 complete)
============================================================
  topic:         $CONSULT_TOPIC ($TOPIC_TEXT)
  rex findings:  $REX_DIR/findings.md           ($REX_FS)
  cody findings: $CODY_DIR/findings.md          ($CODY_FS)
  diff:          $DIFF
  adjudicated:   $ADJ                            (has PENDING items)
  rex verify:    $REX_DIR/verify.md             ($REX_VS)
  cody verify:   $CODY_DIR/verify.md             ($CODY_VS)

  NEXT — conductor responsibility:
    1. Open $ADJ.
    2. For each "- PENDING:" line, read the cited source and rewrite the
       PENDING prefix to CONFIRMED or REFUTED with one-line evidence,
       OR move the line into ## Contested if you can't decide.
    3. Run: $PLUGIN_ROOT/bin/consult-finalize.sh "$CONSULT_TOPIC"
       (this synthesizes the final report, tears down the panes, and
       archives _consult/ alongside the trooper state).
============================================================

EOF
