#!/usr/bin/env bash
# tracer/quad-cycle.sh — final stress test: 4 troopers (2 codex + 2 claude),
# different commanders, distinct Morandi colors, full identity → inbox →
# done cycle. Validates that the runtime scales to a real-sized crew.
#
# Layout: conductor + 4 panes cascading down the right half.
# Crew:
#   rex    + codex   (501st captain — dusty blue)
#   cody   + codex   (212th Marshal — warm terracotta)
#   wolffe + claude  (104th Wolfpack — dusty periwinkle)
#   kix    + claude  (501st medic   — dusty rose)
#
# Run from inside a tmux session:
#   bash tracer/quad-cycle.sh

set -uo pipefail

# ------------------------------------------------------------ Configuration

TOPIC="quad-cycle"

# Crew: <commander> <model> <input-file> <launch-cmd>
declare -a CREW=(
  "rex    codex  /tmp/clone-wars-qc-rex.md    codex --dangerously-bypass-approvals-and-sandbox"
  "cody   codex  /tmp/clone-wars-qc-cody.md   codex --dangerously-bypass-approvals-and-sandbox"
  "wolffe claude /tmp/clone-wars-qc-wolffe.md claude --permission-mode auto"
  "kix    claude /tmp/clone-wars-qc-kix.md    claude --permission-mode auto"
)

READY_TIMEOUT_S=180
DONE_TIMEOUT_S=300

# ------------------------------------------------------------ Resolution

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deps.sh"
source "$PLUGIN_ROOT/lib/colors.sh"

state_root=$(cw_state_root)
repo_hash=$(cw_repo_hash)

trooper_dir() { printf '%s/state/%s/%s/%s-%s\n' "$state_root" "$repo_hash" "$TOPIC" "$1" "$2"; }

# Per-trooper paths
declare -A DIR INBOX OUTBOX IDENTITY INPUT LAUNCH PANE
for entry in "${CREW[@]}"; do
  read -r C M I L1 L2 L3 <<<"$entry"
  L="$L1 $L2 $L3"
  KEY="$C-$M"
  DIR[$KEY]=$(trooper_dir "$C" "$M")
  INBOX[$KEY]="${DIR[$KEY]}/inbox.md"
  OUTBOX[$KEY]="${DIR[$KEY]}/outbox.jsonl"
  IDENTITY[$KEY]="${DIR[$KEY]}/identity.md"
  INPUT[$KEY]="$I"
  LAUNCH[$KEY]="$L"
done

# ------------------------------------------------------------ Cleanup trap

PANES=()
cleanup() {
  for p in "${PANES[@]}"; do
    if [[ -n "$p" ]]; then
      label=$(tmux display-message -p -t "$p" '#{@cw_label}' 2>/dev/null)
      [[ -z "$label" ]] && label="trooper"
      color=$(tmux display-message -p -t "$p" '#{@cw_color}' 2>/dev/null)
      snap=$(mktemp -t cw-snap-XXXXXX.txt)
      tmux capture-pane -p -e -t "$p" > "$snap" 2>/dev/null
      tmux respawn-pane -k -t "$p" \
        "cat '$snap'; '$PLUGIN_ROOT/bin/_close-banner.sh' '$label' '$color'; rm -f '$snap'" 2>/dev/null
    fi
  done
  sleep 9
  for p in "${PANES[@]}"; do
    [[ -n "$p" ]] && tmux kill-pane -t "$p" 2>/dev/null
  done
  log_info "state dirs preserved under $state_root/state/$repo_hash/$TOPIC/"
}
trap cleanup EXIT

# ------------------------------------------------------------ Preconditions

cw_in_tmux_session || { log_error "must run inside a tmux session"; exit 1; }
cw_have_cmd codex  || { log_error "codex not on PATH"; exit 1; }
cw_have_cmd claude || { log_error "claude not on PATH"; exit 1; }
cw_tmux_version_ok || { log_error "tmux >= 3.0 required"; exit 1; }

# ------------------------------------------------------------ State + fixtures

prep_trooper() {
  local C="$1" M="$2"
  local KEY="$C-$M"
  local dir="${DIR[$KEY]}" identity="${IDENTITY[$KEY]}" inbox="${INBOX[$KEY]}" outbox="${OUTBOX[$KEY]}"
  log_info "  preparing $KEY state: $dir"
  mkdir -p "$dir"
  rm -f "$identity" "$inbox" "$outbox"
  touch "$outbox"

  sed \
    -e "s|{{commander}}|$C|g" \
    -e "s|{{model}}|$M|g" \
    -e "s|{{topic}}|$TOPIC|g" \
    -e "s|{{state_dir}}|$dir|g" \
    "$PLUGIN_ROOT/config/identity-template.md" > "$identity"

  cat >> "$identity" <<EOF

---

**First action (do this immediately, then wait):**

Append exactly this single line to $outbox:

\`{"event":"ready","ts":"$(date -u +"%Y-%m-%dT%H:%M:%SZ")","commander":"$C","model":"$M"}\`

Use a shell command: \`echo '{"event":"ready","ts":"...","commander":"$C","model":"$M"}' >> $outbox\`

Then stop and wait. I will send another instruction asking you to read your inbox.
EOF
}

log_info "preparing 4 trooper state dirs:"
for entry in "${CREW[@]}"; do
  read -r C M _ <<<"$entry"
  prep_trooper "$C" "$M"
done

# Fixture files — each commander gets a unique magic-number for isolation checking
log_info "writing 4 mission-brief fixtures"
cat > "${INPUT[rex-codex]}" <<'EOF'
Rex mission brief: Operation Knightfall. Magic number 99.
EOF
cat > "${INPUT[cody-codex]}" <<'EOF'
Cody mission brief: Battle of Utapau, Marshal Commander deployment. Magic number 212.
EOF
cat > "${INPUT[wolffe-claude]}" <<'EOF'
Wolffe mission brief: Khorm patrol, Wolfpack standing orders. Magic number 104.
EOF
cat > "${INPUT[kix-claude]}" <<'EOF'
Kix mission brief: medical resupply audit, 501st Torrent Co. Magic number 501.
EOF

# ------------------------------------------------------------ Spawn 4 panes

declare -a PANE_KEYS=()
prev_pane=""
log_info "spawning 4 trooper panes (cascade splits)"
for entry in "${CREW[@]}"; do
  read -r C M I L1 L2 L3 <<<"$entry"
  L="$L1 $L2 $L3"
  KEY="$C-$M"

  if [[ -z "$prev_pane" ]]; then
    # First pane: right-split of conductor
    p=$(tmux split-window -P -F '#{pane_id}' -h -c "$PLUGIN_ROOT" "$L")
  else
    # Subsequent panes: down-split of previous
    p=$(tmux split-window -P -F '#{pane_id}' -v -t "$prev_pane" -c "$PLUGIN_ROOT" "$L")
  fi

  PANE[$KEY]="$p"
  PANES+=("$p")
  PANE_KEYS+=("$KEY")

  label=$(cw_label_for "$C" "$M" "$TOPIC")
  tmux set-option -p -t "$p" @cw_label "$label"
  tmux set-option -p -t "$p" @cw_color "$(cw_color_for "$C")"
  tmux set-option -p -t "$p" @cw_label_fmt "$(cw_label_fmt "$C" "$M" "$TOPIC")"
  log_ok "  $label in pane $p"

  prev_pane="$p"
done

# Re-balance the cascade so all 4 trooper panes get equal vertical room.
tmux select-layout -t "${PANES[0]}" main-vertical 2>/dev/null || true
tmux display-message "spawned 4 troopers on $TOPIC"

# Bootstrap delay (codex ~8s, claude ~10s; sleep generously since 4 TUIs init in parallel)
log_info "sleeping 14s for all 4 TUIs to bootstrap"
sleep 14

# ------------------------------------------------------------ Identity injection

for KEY in "${PANE_KEYS[@]}"; do
  p="${PANE[$KEY]}"
  identity="${IDENTITY[$KEY]}"
  log_info "  asking $KEY to read identity"
  tmux send-keys -t "$p" -l "Read $identity and follow its instructions exactly."
  sleep 0.3
  tmux send-keys -t "$p" Enter
done

# ------------------------------------------------------------ Wait for all ready

wait_for_event() {
  local outbox="$1" event="$2" timeout="$3"
  for i in $(seq 1 "$timeout"); do
    if grep -q "\"event\":\"$event\"" "$outbox" 2>/dev/null; then
      printf '%s\n' "$i"; return 0
    fi
    sleep 1
  done
  return 1
}

declare -A T_READY
log_info "waiting for all 4 {ready} events (timeout ${READY_TIMEOUT_S}s each)"
for KEY in "${PANE_KEYS[@]}"; do
  outbox="${OUTBOX[$KEY]}"
  T_READY[$KEY]=$(wait_for_event "$outbox" "ready" "$READY_TIMEOUT_S") || {
    log_error "$KEY timeout on {ready}"
    log_error "outbox:"; cat "$outbox" >&2 || true
    log_error "pane content (last 20 lines):"
    tmux capture-pane -p -t "${PANE[$KEY]}" 2>/dev/null | tail -n 20 >&2 || true
    exit 1
  }
  log_ok "  $KEY ready in ${T_READY[$KEY]}s"
done

# ------------------------------------------------------------ Dispatch tasks

write_inbox() {
  local KEY="$1"
  cat > "${INBOX[$KEY]}" <<EOF
# Mission Task

Read the file at: ${INPUT[$KEY]}

Then append a single JSONL event to your outbox at:
${OUTBOX[$KEY]}

The event must be exactly this shape (one line, valid JSON):

\`{"event":"done","summary":"<one-line summary mentioning the magic number>","ts":"<iso-timestamp>"}\`

Use a shell command: \`echo '{"event":"done","summary":"...","ts":"..."}' >> ${OUTBOX[$KEY]}\`

END_OF_INSTRUCTION
EOF
}

for KEY in "${PANE_KEYS[@]}"; do
  write_inbox "$KEY"
done

for KEY in "${PANE_KEYS[@]}"; do
  p="${PANE[$KEY]}"
  inbox="${INBOX[$KEY]}"
  log_info "  nudging $KEY to read inbox"
  tmux send-keys -t "$p" -l "Read $inbox and execute the task. Report when done."
  sleep 0.3
  tmux send-keys -t "$p" Enter
done

# ------------------------------------------------------------ Wait for all done

declare -A T_DONE
log_info "waiting for all 4 {done} events (timeout ${DONE_TIMEOUT_S}s each)"
for KEY in "${PANE_KEYS[@]}"; do
  outbox="${OUTBOX[$KEY]}"
  T_DONE[$KEY]=$(wait_for_event "$outbox" "done" "$DONE_TIMEOUT_S") || {
    log_error "$KEY timeout on {done}"
    log_error "outbox:"; cat "$outbox" >&2
    exit 1
  }
  log_ok "  $KEY done in ${T_DONE[$KEY]}s"
done

# ------------------------------------------------------------ Isolation check

isolation_ok=true
declare -A MAGIC=( [rex-codex]=99 [cody-codex]=212 [wolffe-claude]=104 [kix-claude]=501 )
for K1 in "${PANE_KEYS[@]}"; do
  outbox="${OUTBOX[$K1]}"
  for K2 in "${PANE_KEYS[@]}"; do
    [[ "$K1" == "$K2" ]] && continue
    other_magic="${MAGIC[$K2]}"
    if grep -qw "$other_magic" "$outbox" 2>/dev/null; then
      log_error "ISOLATION FAIL: $K1's outbox mentions $K2's magic number ($other_magic)"
      isolation_ok=false
    fi
  done
done

# ------------------------------------------------------------ Summary

echo
echo "============================================================"
if $isolation_ok; then
  echo "  Quad-Cycle — SUCCESS (4 troopers, 2 codex + 2 claude, isolated)"
else
  echo "  Quad-Cycle — STATE LEAK DETECTED"
fi
echo "============================================================"
for KEY in "${PANE_KEYS[@]}"; do
  printf '  %-15s pane=%s ready=%ss done=%ss\n' "$KEY" "${PANE[$KEY]}" "${T_READY[$KEY]}" "${T_DONE[$KEY]}"
done
echo
for KEY in "${PANE_KEYS[@]}"; do
  echo "$KEY outbox:"
  echo "------------------------------------------------------------"
  cat "${OUTBOX[$KEY]}"
  echo "------------------------------------------------------------"
  echo
done
echo "All 4 panes will get colored shutdown banners on script exit."

$isolation_ok || exit 1
