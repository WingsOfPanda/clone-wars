#!/usr/bin/env bash
# tracer/mixed-cycle.sh — end-to-end production-ish demo: two troopers,
# different models, full identity → inbox → done cycle, Morandi-labeled panes.
#
# Validates that the file-read identity injection + END_OF_INSTRUCTION inbox
# protocol works for BOTH codex and claude TUIs in the same crew, with
# isolated outboxes and visible per-trooper labels.
#
# Run from inside a tmux session:
#   bash tracer/mixed-cycle.sh

set -uo pipefail

# ------------------------------------------------------------ Configuration

TOPIC="mixed-cycle"

COMMANDER_A="rex"
MODEL_A="codex"
INPUT_A="/tmp/clone-wars-mc-rex.md"
LAUNCH_A="codex --dangerously-bypass-approvals-and-sandbox"

COMMANDER_B="wolffe"
MODEL_B="claude"
INPUT_B="/tmp/clone-wars-mc-wolffe.md"
LAUNCH_B="claude --permission-mode auto"

READY_TIMEOUT_S=120
DONE_TIMEOUT_S=240

# ------------------------------------------------------------ Resolution

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deps.sh"
source "$PLUGIN_ROOT/lib/colors.sh"

state_root=$(cw_state_root)
repo_hash=$(cw_repo_hash)

trooper_dir() { printf '%s/state/%s/%s/%s-%s\n' "$state_root" "$repo_hash" "$TOPIC" "$1" "$2"; }

DIR_A=$(trooper_dir "$COMMANDER_A" "$MODEL_A")
DIR_B=$(trooper_dir "$COMMANDER_B" "$MODEL_B")
IDENTITY_A="$DIR_A/identity.md"; INBOX_A="$DIR_A/inbox.md"; OUTBOX_A="$DIR_A/outbox.jsonl"
IDENTITY_B="$DIR_B/identity.md"; INBOX_B="$DIR_B/inbox.md"; OUTBOX_B="$DIR_B/outbox.jsonl"

# ------------------------------------------------------------ Cleanup trap

PANE_A=""; PANE_B=""
cleanup() {
  # Graceful shutdown: capture each trooper's visible pane content (its
  # codex/claude TUI alt-buffer), then respawn the pane with a shell that
  # echoes the captured snapshot followed by a "JOB DONE" banner + 5s
  # countdown. Preserves the conversation visible while the pane closes.
  for p in "$PANE_A" "$PANE_B"; do
    if [[ -n "$p" ]]; then
      label=$(tmux display-message -p -t "$p" '#{@cw_label}' 2>/dev/null)
      [[ -z "$label" ]] && label="trooper"
      color=$(tmux display-message -p -t "$p" '#{@cw_color}' 2>/dev/null)
      # Capture visible alt-buffer with ANSI escapes preserved (-e), no
      # join-wrapped (default off), into a tmpfile that the respawned
      # shell prints back.
      snap=$(mktemp -t cw-snap-XXXXXX.txt)
      tmux capture-pane -p -e -t "$p" > "$snap" 2>/dev/null
      tmux respawn-pane -k -t "$p" \
        "cat '$snap'; '$PLUGIN_ROOT/bin/_close-banner.sh' '$label' '$color'; rm -f '$snap'" 2>/dev/null
    fi
  done
  # Wait for the 8s countdowns to finish + a small grace period.
  sleep 9
  # Belt-and-suspenders: kill any pane still alive (respawn-pane edge cases).
  for p in "$PANE_A" "$PANE_B"; do
    [[ -n "$p" ]] && tmux kill-pane -t "$p" 2>/dev/null
  done
  log_info "state preserved at: $DIR_A and $DIR_B"
}
trap cleanup EXIT

# ------------------------------------------------------------ Preconditions

cw_in_tmux_session || { log_error "must run inside a tmux session"; exit 1; }
cw_have_cmd codex  || { log_error "codex binary not on PATH"; exit 1; }
cw_have_cmd claude || { log_error "claude binary not on PATH"; exit 1; }
cw_tmux_version_ok || { log_error "tmux >= 3.0 required"; exit 1; }

# ------------------------------------------------------------ State + fixtures

prep_trooper() {
  local commander="$1" model="$2" dir="$3" identity="$4" inbox="$5" outbox="$6"
  log_info "preparing $commander-$model state: $dir"
  mkdir -p "$dir"
  rm -f "$identity" "$inbox" "$outbox"
  touch "$outbox"

  sed \
    -e "s|{{commander}}|$commander|g" \
    -e "s|{{model}}|$model|g" \
    -e "s|{{topic}}|$TOPIC|g" \
    -e "s|{{state_dir}}|$dir|g" \
    "$PLUGIN_ROOT/config/identity-template.md" > "$identity"

  cat >> "$identity" <<EOF

---

**First action (do this immediately, then wait):**

Append exactly this single line to $outbox:

\`{"event":"ready","ts":"$(date -u +"%Y-%m-%dT%H:%M:%SZ")","commander":"$commander","model":"$model"}\`

Use a shell command: \`echo '{"event":"ready","ts":"...","commander":"$commander","model":"$model"}' >> $outbox\`

Then stop and wait. I will send another instruction asking you to read your inbox.
EOF
}

prep_trooper "$COMMANDER_A" "$MODEL_A" "$DIR_A" "$IDENTITY_A" "$INBOX_A" "$OUTBOX_A"
prep_trooper "$COMMANDER_B" "$MODEL_B" "$DIR_B" "$IDENTITY_B" "$INBOX_B" "$OUTBOX_B"

cat > "$INPUT_A" <<'EOF'
Mission brief for the rex-codex pane.
Topic: Operation Knightfall — codename for the Jedi Temple raid.
Mission detail: scout the perimeter, report any blue-and-white phase-II troopers seen.
Magic number: 99.
EOF

cat > "$INPUT_B" <<'EOF'
Mission brief for the wolffe-claude pane.
Topic: Order 66 — the directive issued to all clone troopers.
Mission detail: catalog the brief; do NOT execute. Report your understanding.
Magic number: 1138.
EOF

# ------------------------------------------------------------ Spawn both panes (Morandi-labeled)

log_info "spawning $COMMANDER_A-$MODEL_A pane (right-split)"
PANE_A=$(tmux split-window -P -F '#{pane_id}' -h -c "$PLUGIN_ROOT" "$LAUNCH_A")
tmux set-option -p -t "$PANE_A" @cw_label "$(cw_label_for "$COMMANDER_A" "$MODEL_A" "$TOPIC")"
tmux set-option -p -t "$PANE_A" @cw_color "$(cw_color_for "$COMMANDER_A")"
tmux set-option -p -t "$PANE_A" @cw_label_fmt "$(cw_label_fmt "$COMMANDER_A" "$MODEL_A" "$TOPIC")"
log_ok "  $(cw_label_for "$COMMANDER_A" "$MODEL_A" "$TOPIC") in pane $PANE_A"

log_info "spawning $COMMANDER_B-$MODEL_B pane (down-split of $PANE_A)"
PANE_B=$(tmux split-window -P -F '#{pane_id}' -v -t "$PANE_A" -c "$PLUGIN_ROOT" "$LAUNCH_B")
tmux set-option -p -t "$PANE_B" @cw_label "$(cw_label_for "$COMMANDER_B" "$MODEL_B" "$TOPIC")"
tmux set-option -p -t "$PANE_B" @cw_color "$(cw_color_for "$COMMANDER_B")"
tmux set-option -p -t "$PANE_B" @cw_label_fmt "$(cw_label_fmt "$COMMANDER_B" "$MODEL_B" "$TOPIC")"
log_ok "  $(cw_label_for "$COMMANDER_B" "$MODEL_B" "$TOPIC") in pane $PANE_B"

# ------------------------------------------------------------ Bootstrap delay

log_info "sleeping 12s for both TUIs to bootstrap (codex ~8s, claude ~10s)"
sleep 12

# ------------------------------------------------------------ Identity injection

log_info "asking $COMMANDER_A to read identity"
tmux send-keys -t "$PANE_A" -l "Read $IDENTITY_A and follow its instructions exactly."
sleep 0.3
tmux send-keys -t "$PANE_A" Enter

log_info "asking $COMMANDER_B to read identity"
tmux send-keys -t "$PANE_B" -l "Read $IDENTITY_B and follow its instructions exactly."
sleep 0.3
tmux send-keys -t "$PANE_B" Enter

# ------------------------------------------------------------ Wait for both ready

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

log_info "waiting for both {ready} (timeout ${READY_TIMEOUT_S}s each)"
T_A=$(wait_for_event "$OUTBOX_A" "ready" "$READY_TIMEOUT_S") || {
  log_error "$COMMANDER_A timeout on {ready}"
  log_error "outbox:"; cat "$OUTBOX_A" >&2 || true
  log_error "pane content (last 25 lines):"; tmux capture-pane -p -t "$PANE_A" 2>/dev/null | tail -n 25 >&2 || true
  exit 1
}
log_ok "$COMMANDER_A ready in ${T_A}s"

T_B=$(wait_for_event "$OUTBOX_B" "ready" "$READY_TIMEOUT_S") || {
  log_error "$COMMANDER_B timeout on {ready}"
  log_error "outbox:"; cat "$OUTBOX_B" >&2 || true
  log_error "pane content (last 25 lines):"; tmux capture-pane -p -t "$PANE_B" 2>/dev/null | tail -n 25 >&2 || true
  exit 1
}
log_ok "$COMMANDER_B ready in ${T_B}s"

# ------------------------------------------------------------ Dispatch tasks

write_inbox() {
  local inbox="$1" outbox="$2" input="$3"
  cat > "$inbox" <<EOF
# Mission Task

Read the file at: $input

Then append a single JSONL event to your outbox at:
$outbox

The event must be exactly this shape (one line, valid JSON):

\`{"event":"done","summary":"<one-line summary mentioning the topic phrase>","ts":"<iso-timestamp>"}\`

Use a shell command: \`echo '{"event":"done","summary":"...","ts":"..."}' >> $outbox\`

END_OF_INSTRUCTION
EOF
}

write_inbox "$INBOX_A" "$OUTBOX_A" "$INPUT_A"
write_inbox "$INBOX_B" "$OUTBOX_B" "$INPUT_B"

log_info "nudging $COMMANDER_A to read inbox"
tmux send-keys -t "$PANE_A" -l "Read $INBOX_A and execute the task. Report when done."
sleep 0.3
tmux send-keys -t "$PANE_A" Enter

log_info "nudging $COMMANDER_B to read inbox"
tmux send-keys -t "$PANE_B" -l "Read $INBOX_B and execute the task. Report when done."
sleep 0.3
tmux send-keys -t "$PANE_B" Enter

# ------------------------------------------------------------ Wait for both done

log_info "waiting for both {done} (timeout ${DONE_TIMEOUT_S}s each)"
D_A=$(wait_for_event "$OUTBOX_A" "done" "$DONE_TIMEOUT_S") || {
  log_error "$COMMANDER_A timeout on {done}"; cat "$OUTBOX_A" >&2; exit 1
}
log_ok "$COMMANDER_A done in ${D_A}s"

D_B=$(wait_for_event "$OUTBOX_B" "done" "$DONE_TIMEOUT_S") || {
  log_error "$COMMANDER_B timeout on {done}"; cat "$OUTBOX_B" >&2; exit 1
}
log_ok "$COMMANDER_B done in ${D_B}s"

# ------------------------------------------------------------ Isolation check

isolation_ok=true
grep -q "1138"      "$OUTBOX_A" && { log_error "ISOLATION FAIL: $COMMANDER_A's outbox mentions cody's magic number"; isolation_ok=false; }
grep -q "99"        "$OUTBOX_B" && { log_error "ISOLATION FAIL: $COMMANDER_B's outbox mentions rex's magic number"; isolation_ok=false; }
grep -q "Order 66"  "$OUTBOX_A" && { log_error "ISOLATION FAIL: $COMMANDER_A's outbox mentions wolffe's topic phrase"; isolation_ok=false; }
grep -q "Knightfall" "$OUTBOX_B" && { log_error "ISOLATION FAIL: $COMMANDER_B's outbox mentions rex's topic phrase"; isolation_ok=false; }

# ------------------------------------------------------------ Summary

echo
echo "============================================================"
if $isolation_ok; then
  echo "  Mixed-Cycle — SUCCESS (codex + claude, isolated)"
else
  echo "  Mixed-Cycle — STATE LEAK DETECTED"
fi
echo "============================================================"
echo "  $COMMANDER_A-$MODEL_A: ready ${T_A}s, done ${D_A}s, pane $PANE_A"
echo "  $COMMANDER_B-$MODEL_B: ready ${T_B}s, done ${D_B}s, pane $PANE_B"
echo
echo "$COMMANDER_A-$MODEL_A outbox:"
echo "------------------------------------------------------------"
cat "$OUTBOX_A"
echo "------------------------------------------------------------"
echo
echo "$COMMANDER_B-$MODEL_B outbox:"
echo "------------------------------------------------------------"
cat "$OUTBOX_B"
echo "------------------------------------------------------------"
echo
echo "Both panes will be killed on script exit."

$isolation_ok || exit 1
