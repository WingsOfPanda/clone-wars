#!/usr/bin/env bash
# tracer/two-coders.sh — explore N=2 trooper coexistence on the same topic.
#
# Goal: validate that two codex panes can be spawned, identified, dispatched
# different tasks, and report independently — without state collision, pane-id
# confusion, or tmux layout weirdness. Same pattern as tracer-bullet.sh,
# multiplied: spawn rex + cody on topic 'twocoders', dispatch different tasks,
# wait for both done events.
#
# Run from inside a tmux session:
#   bash tracer/two-coders.sh

set -uo pipefail

# ------------------------------------------------------------ Configuration

MODEL="codex"
TOPIC="twocoders"

# Two troopers, each gets a different fixture and a different expected summary
# so we can confirm outbox isolation.
COMMANDER_A="rex"
INPUT_A="/tmp/clone-wars-twocoders-rex.md"
TASK_HINT_A="Operation Knightfall"

COMMANDER_B="cody"
INPUT_B="/tmp/clone-wars-twocoders-cody.md"
TASK_HINT_B="Order 66"

READY_TIMEOUT_S=90
DONE_TIMEOUT_S=180

# ------------------------------------------------------------ Resolution

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deps.sh"
source "$PLUGIN_ROOT/lib/colors.sh"

state_root=$(cw_state_root)
repo_hash=$(cw_repo_hash)

# Per-trooper paths
trooper_dir() { printf '%s/state/%s/%s/%s-%s\n' "$state_root" "$repo_hash" "$TOPIC" "$1" "$MODEL"; }

DIR_A=$(trooper_dir "$COMMANDER_A")
DIR_B=$(trooper_dir "$COMMANDER_B")

INBOX_A="$DIR_A/inbox.md";  OUTBOX_A="$DIR_A/outbox.jsonl";  IDENTITY_A="$DIR_A/identity.md"
INBOX_B="$DIR_B/inbox.md";  OUTBOX_B="$DIR_B/outbox.jsonl";  IDENTITY_B="$DIR_B/identity.md"

# ------------------------------------------------------------ Cleanup trap

PANE_A=""; PANE_B=""
cleanup() {
  # Graceful shutdown: snapshot each trooper's TUI content, respawn the
  # pane with a shell that prints the snapshot + colored "JOB DONE" banner
  # + 8s countdown. Preserves the conversation visible while panes close.
  for p in "$PANE_A" "$PANE_B"; do
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
  for p in "$PANE_A" "$PANE_B"; do
    [[ -n "$p" ]] && tmux kill-pane -t "$p" 2>/dev/null
  done
  log_info "state dirs preserved at: $DIR_A and $DIR_B"
}
trap cleanup EXIT

# ------------------------------------------------------------ Preconditions

cw_in_tmux_session || { log_error "must run inside a tmux session"; exit 1; }
cw_have_cmd codex  || { log_error "codex binary not on PATH"; exit 1; }
cw_tmux_version_ok || { log_error "tmux >= 3.0 required"; exit 1; }

# ------------------------------------------------------------ State + fixtures

prep_trooper() {
  local commander="$1" dir="$2" inbox="$3" outbox="$4" identity="$5"
  log_info "preparing $commander state: $dir"
  mkdir -p "$dir"
  rm -f "$inbox" "$outbox" "$identity"
  touch "$outbox"

  sed \
    -e "s|{{commander}}|$commander|g" \
    -e "s|{{model}}|$MODEL|g" \
    -e "s|{{topic}}|$TOPIC|g" \
    -e "s|{{state_dir}}|$dir|g" \
    "$PLUGIN_ROOT/config/identity-template.md" > "$identity"

  cat >> "$identity" <<EOF

---

**First action (do this immediately, then wait):**

Append this exact line to $outbox:

\`{"event":"ready","ts":"$(date -u +"%Y-%m-%dT%H:%M:%SZ")","commander":"$commander"}\`

Use a shell command like:
\`echo '{"event":"ready","ts":"...","commander":"$commander"}' >> $outbox\`

Then stop and wait. I will send another instruction to read your inbox.
EOF
}

prep_trooper "$COMMANDER_A" "$DIR_A" "$INBOX_A" "$OUTBOX_A" "$IDENTITY_A"
prep_trooper "$COMMANDER_B" "$DIR_B" "$INBOX_B" "$OUTBOX_B" "$IDENTITY_B"

cat > "$INPUT_A" <<'EOF'
This file is for the rex trooper.
Topic: Operation Knightfall — the codename for the Jedi Temple raid.
Quick brown fox. The number 99.
EOF

cat > "$INPUT_B" <<'EOF'
This file is for the cody trooper.
Topic: Order 66 — the directive issued to all clone troopers.
Lorem ipsum dolor sit amet. The number 1138.
EOF

# ------------------------------------------------------------ Spawn both panes

log_info "spawning $COMMANDER_A pane (right-split of conductor)"
PANE_A=$(tmux split-window -P -F '#{pane_id}' -h -c "$PLUGIN_ROOT" "codex --dangerously-bypass-approvals-and-sandbox")
LABEL_A=$(cw_label_for "$COMMANDER_A" "$MODEL" "$TOPIC")
# @cw_label/@cw_color/@cw_label_fmt are OSC-immune custom user-options. Set
# immediately at spawn so /clone-wars:list and the active-border hook can
# read them even before codex finishes booting.
tmux set-option -p -t "$PANE_A" @cw_label "$LABEL_A"
tmux set-option -p -t "$PANE_A" @cw_color "$(cw_color_for "$COMMANDER_A")"
tmux set-option -p -t "$PANE_A" @cw_label_fmt "$(cw_label_fmt "$COMMANDER_A" "$MODEL" "$TOPIC")"
log_ok "  $LABEL_A in pane $PANE_A"

# Per DESIGN.md §Pane layout: 2nd clone in same topic splits DOWN from the 1st.
log_info "spawning $COMMANDER_B pane (down-split of $PANE_A)"
PANE_B=$(tmux split-window -P -F '#{pane_id}' -v -t "$PANE_A" -c "$PLUGIN_ROOT" "codex --dangerously-bypass-approvals-and-sandbox")
LABEL_B=$(cw_label_for "$COMMANDER_B" "$MODEL" "$TOPIC")
tmux set-option -p -t "$PANE_B" @cw_label "$LABEL_B"
tmux set-option -p -t "$PANE_B" @cw_color "$(cw_color_for "$COMMANDER_B")"
tmux set-option -p -t "$PANE_B" @cw_label_fmt "$(cw_label_fmt "$COMMANDER_B" "$MODEL" "$TOPIC")"
log_ok "  $LABEL_B in pane $PANE_B"

tmux display-message "spawned 2 troopers: $LABEL_A ($PANE_A), $LABEL_B ($PANE_B)"

# Both bootstrap in parallel; sleep once for the longest.
log_info "sleeping 10s for both codex instances to bootstrap"
sleep 10

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
  local outbox="$1" event="$2" timeout="$3" label="$4"
  for i in $(seq 1 "$timeout"); do
    if grep -q "\"event\":\"$event\"" "$outbox" 2>/dev/null; then
      printf '%s\n' "$i"
      return 0
    fi
    sleep 1
  done
  return 1
}

log_info "waiting for both {ready} events (timeout ${READY_TIMEOUT_S}s each)"
T_A=$(wait_for_event "$OUTBOX_A" "ready" "$READY_TIMEOUT_S" "$COMMANDER_A") || {
  log_error "$COMMANDER_A timeout on {ready}; outbox:"; cat "$OUTBOX_A" >&2 || true
  log_error "pane content:"; tmux capture-pane -p -t "$PANE_A" 2>/dev/null | tail -n 20 >&2 || true
  exit 1
}
log_ok "$COMMANDER_A ready in ${T_A}s"

T_B=$(wait_for_event "$OUTBOX_B" "ready" "$READY_TIMEOUT_S" "$COMMANDER_B") || {
  log_error "$COMMANDER_B timeout on {ready}; outbox:"; cat "$OUTBOX_B" >&2 || true
  log_error "pane content:"; tmux capture-pane -p -t "$PANE_B" 2>/dev/null | tail -n 20 >&2 || true
  exit 1
}
log_ok "$COMMANDER_B ready in ${T_B}s"

# ------------------------------------------------------------ Dispatch tasks

write_inbox() {
  local inbox="$1" outbox="$2" input="$3" hint="$4"
  cat > "$inbox" <<EOF
# Task: Two-coders test

Please read the file at: $input

Then append a single JSONL event to your outbox at:
$outbox

The event must be exactly this shape (one line, valid JSON):

\`{"event":"done","summary":"<one-line summary mentioning the topic phrase>","ts":"<iso-timestamp>"}\`

Use a shell command, e.g.:
\`echo '{"event":"done","summary":"...","ts":"..."}' >> $outbox\`

END_OF_INSTRUCTION
EOF
}

write_inbox "$INBOX_A" "$OUTBOX_A" "$INPUT_A" "$TASK_HINT_A"
write_inbox "$INBOX_B" "$OUTBOX_B" "$INPUT_B" "$TASK_HINT_B"

log_info "nudging $COMMANDER_A to read inbox"
tmux send-keys -t "$PANE_A" -l "Read $INBOX_A and execute the task. Reply when done."
sleep 0.3
tmux send-keys -t "$PANE_A" Enter

log_info "nudging $COMMANDER_B to read inbox"
tmux send-keys -t "$PANE_B" -l "Read $INBOX_B and execute the task. Reply when done."
sleep 0.3
tmux send-keys -t "$PANE_B" Enter

# ------------------------------------------------------------ Wait for both done

log_info "waiting for both {done} events (timeout ${DONE_TIMEOUT_S}s each)"
D_A=$(wait_for_event "$OUTBOX_A" "done" "$DONE_TIMEOUT_S" "$COMMANDER_A") || {
  log_error "$COMMANDER_A timeout on {done}; outbox:"; cat "$OUTBOX_A" >&2 || true
  exit 1
}
log_ok "$COMMANDER_A done in ${D_A}s"

D_B=$(wait_for_event "$OUTBOX_B" "done" "$DONE_TIMEOUT_S" "$COMMANDER_B") || {
  log_error "$COMMANDER_B timeout on {done}; outbox:"; cat "$OUTBOX_B" >&2 || true
  exit 1
}
log_ok "$COMMANDER_B done in ${D_B}s"

# ------------------------------------------------------------ Isolation check

isolation_ok=true
if grep -q "$TASK_HINT_B" "$OUTBOX_A" 2>/dev/null; then
  log_error "ISOLATION FAIL: $COMMANDER_A's outbox mentions '$TASK_HINT_B' (cody's hint)"
  isolation_ok=false
fi
if grep -q "$TASK_HINT_A" "$OUTBOX_B" 2>/dev/null; then
  log_error "ISOLATION FAIL: $COMMANDER_B's outbox mentions '$TASK_HINT_A' (rex's hint)"
  isolation_ok=false
fi

# ------------------------------------------------------------ Summary

echo
echo "============================================================"
if $isolation_ok; then
  echo "  Two-Coders — SUCCESS (outboxes isolated)"
else
  echo "  Two-Coders — STATE LEAK DETECTED"
fi
echo "============================================================"
echo "  $LABEL_A:  ready ${T_A}s, done ${D_A}s, pane $PANE_A"
echo "  $LABEL_B:  ready ${T_B}s, done ${D_B}s, pane $PANE_B"
echo
echo "$COMMANDER_A outbox:"
echo "------------------------------------------------------------"
cat "$OUTBOX_A"
echo "------------------------------------------------------------"
echo
echo "$COMMANDER_B outbox:"
echo "------------------------------------------------------------"
cat "$OUTBOX_B"
echo "------------------------------------------------------------"
echo
echo "Both panes will be killed on script exit."

$isolation_ok || exit 1
