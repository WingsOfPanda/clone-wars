#!/usr/bin/env bash
# tracer/tracer-bullet.sh — standalone end-to-end test for ONE codex trooper.
#
# Goal: prove the load-bearing tmux + send-keys + paste-buffer + codex-launch
# mechanics work before we generalize into the slash commands. If anything
# surprises us here, the design changes — discover surprises now.
#
# Run from inside a tmux session:
#   bash tracer/tracer-bullet.sh
#
# After 3 clean back-to-back runs, step 1 of the build order is done.

set -uo pipefail

# ------------------------------------------------------------ Configuration

COMMANDER="rex"
MODEL="codex"
TOPIC="tracer"

TASK_INPUT_FILE="/tmp/clone-wars-tracer-input.md"
READY_TIMEOUT_S=60
DONE_TIMEOUT_S=120

# ------------------------------------------------------------ Resolution

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deps.sh"

state_root=$(cw_state_root)
repo_hash=$(cw_repo_hash)
trooper_dir="$state_root/state/$repo_hash/$TOPIC/$COMMANDER-$MODEL"
inbox="$trooper_dir/inbox.md"
outbox="$trooper_dir/outbox.jsonl"
status="$trooper_dir/status.json"
identity="$trooper_dir/identity.md"

# ------------------------------------------------------------ Cleanup trap

PANE_ID=""
cleanup() {
  if [[ -n "$PANE_ID" ]]; then
    log_info "tracer cleanup: killing pane $PANE_ID"
    tmux kill-pane -t "$PANE_ID" 2>/dev/null || true
  fi
  log_info "tracer state preserved at: $trooper_dir"
}
trap cleanup EXIT

# ------------------------------------------------------------ Preconditions

cw_in_tmux_session || { log_error "must run inside a tmux session"; exit 1; }
cw_have_cmd codex  || { log_error "codex binary not on PATH"; exit 1; }
cw_tmux_version_ok || { log_error "tmux >= 3.0 required (have: $(cw_tmux_version_string))"; exit 1; }

# ------------------------------------------------------------ State dir reset

log_info "preparing fresh state dir: $trooper_dir"
mkdir -p "$trooper_dir"
rm -f "$inbox" "$outbox" "$status" "$identity"
touch "$outbox"

# ------------------------------------------------------------ Test input fixture

cat > "$TASK_INPUT_FILE" <<'EOF'
Clone Wars tracer-bullet test input.
The trooper should read this file and report a one-line summary.
Quick brown fox jumps over the lazy dog. The number 42 appears here.
EOF

# ------------------------------------------------------------ Identity prompt

log_info "writing identity.md from template"
sed \
  -e "s|{{commander}}|$COMMANDER|g" \
  -e "s|{{model}}|$MODEL|g" \
  -e "s|{{topic}}|$TOPIC|g" \
  -e "s|{{state_dir}}|$trooper_dir|g" \
  "$PLUGIN_ROOT/config/identity-template.md" > "$identity"

# Append a "first action" instruction so codex emits {ready} immediately.
# Without this, the trooper would just sit at its prompt waiting for input.
cat >> "$identity" <<EOF

---

**First action (do this immediately, then wait):**

Append this exact line to $outbox:

\`{"event":"ready","ts":"$(date -u +"%Y-%m-%dT%H:%M:%SZ")","pane":"%PANE_ID%"}\`

(Replace %PANE_ID% with the literal string "tracer-bullet".)

Use a shell command like:
\`echo '{"event":"ready","ts":"...","pane":"tracer-bullet"}' >> $outbox\`

Then stop and wait for the next instruction. Do not try to read the inbox until I tell you to.
EOF

# ------------------------------------------------------------ Spawn pane

log_info "spawning codex pane via tmux split-window -h"
PANE_ID=$(tmux split-window -P -F '#{pane_id}' -h -c "$PLUGIN_ROOT" "codex --dangerously-bypass-approvals-and-sandbox")
TROOPER_LABEL="$COMMANDER-$MODEL-$TOPIC"

# Identification via @cw_label — a custom tmux pane user-option that's
# OSC-immune (codex's OSC title sequences write `pane_title`, which is a
# different variable). Set immediately at spawn; survives codex bootstrap and
# any subsequent title emissions for the lifetime of the pane. Visible in
# tmux's pane border via `pane-border-format ' #{?@cw_label,#{@cw_label},#{pane_title}} '`.
tmux set-option -p -t "$PANE_ID" @cw_label "$TROOPER_LABEL"
tmux display-message "spawned $TROOPER_LABEL in pane $PANE_ID"
log_ok "pane created: $PANE_ID  (@cw_label=$TROOPER_LABEL)"

# Give codex enough time to bootstrap (banner, working-dir line, composer ready).
# Manual experiment (tracer iteration 1) showed ~8s is the safe floor on this box.
log_info "sleeping 8s for codex bootstrap"
sleep 8

# ------------------------------------------------------------ Identity injection
#
# Architecture choice (after iteration 1 surprised us): rather than paste the
# multi-line identity into codex's TUI input — which got eaten silently — we
# write identity.md to disk and ask codex to *read the file*. Codex is agentic;
# reading a file is a natural verb for it. Keeps the TUI input single-line, which
# we proved works via tmux send-keys -l.

log_info "asking codex to read identity.md"
tmux send-keys -t "$PANE_ID" -l "Read $identity and follow its instructions exactly."
sleep 0.3
tmux send-keys -t "$PANE_ID" Enter

# ------------------------------------------------------------ Wait for {ready}

log_info "waiting for {ready} event in outbox (timeout ${READY_TIMEOUT_S}s)"
ready_at=""
for i in $(seq 1 "$READY_TIMEOUT_S"); do
  if grep -q '"event":"ready"' "$outbox" 2>/dev/null; then
    ready_at="$i"
    break
  fi
  sleep 1
done

if [[ -z "$ready_at" ]]; then
  log_error "timeout waiting for {ready} after ${READY_TIMEOUT_S}s"
  log_error "outbox contents:"
  cat "$outbox" >&2 || true
  log_error "tmux pane content (last 30 lines):"
  tmux capture-pane -p -t "$PANE_ID" 2>/dev/null | tail -n 30 >&2 || true
  exit 1
fi
log_ok "{ready} received after ${ready_at}s"

# ------------------------------------------------------------ Dispatch task

log_info "writing inbox.md with test task"
cat > "$inbox" <<EOF
# Task: Tracer Test

Please read the file at: $TASK_INPUT_FILE

Then append a single JSONL event to your outbox at:
$outbox

The event must be exactly this shape (one line, valid JSON):

\`{"event":"done","summary":"<your one-line summary of the file>","ts":"<iso-timestamp>"}\`

Use a shell command to do this, e.g.:
\`echo '{"event":"done","summary":"...","ts":"..."}' >> $outbox\`

END_OF_INSTRUCTION
EOF

log_info "nudging codex to read inbox"
# Use send-keys -l (literal) so the path text isn't interpreted as keymap chords.
tmux send-keys -t "$PANE_ID" -l "Read $inbox and execute the task. Reply when done."
sleep 0.3
tmux send-keys -t "$PANE_ID" Enter

# ------------------------------------------------------------ Wait for {done}

log_info "waiting for {done} event in outbox (timeout ${DONE_TIMEOUT_S}s)"
done_at=""
for i in $(seq 1 "$DONE_TIMEOUT_S"); do
  if grep -q '"event":"done"' "$outbox" 2>/dev/null; then
    done_at="$i"
    break
  fi
  sleep 1
done

if [[ -z "$done_at" ]]; then
  log_error "timeout waiting for {done} after ${DONE_TIMEOUT_S}s"
  log_error "outbox contents:"
  cat "$outbox" >&2 || true
  log_error "tmux pane content (last 30 lines):"
  tmux capture-pane -p -t "$PANE_ID" 2>/dev/null | tail -n 30 >&2 || true
  exit 1
fi
log_ok "{done} received after ${done_at}s"

# ------------------------------------------------------------ Summary

echo
echo "============================================================"
echo "  Tracer Bullet — SUCCESS"
echo "============================================================"
echo "  Trooper:     $COMMANDER-$MODEL on $TOPIC"
echo "  Pane:        $PANE_ID"
echo "  Ready in:    ${ready_at}s"
echo "  Done in:     ${done_at}s"
echo "  State dir:   $trooper_dir"
echo
echo "Outbox events:"
echo "------------------------------------------------------------"
cat "$outbox"
echo "------------------------------------------------------------"
echo
echo "Pane will be killed on script exit. Re-run to test reproducibility."
echo "(state dir is preserved for forensics; rerun cleans it.)"
