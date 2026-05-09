#!/usr/bin/env bash
# tests/test_preflight_layout.sh
# Happy-path: bin/preflight-layout.sh creates N panes, runs select-layout
# main-vertical, writes _consult/preflight-panes.txt with ordered TSV entries.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

[[ -n "${TMUX:-}" ]] || { echo "  SKIP: no tmux session ($TMUX unset)" >&2; exit 0; }
command -v tmux >/dev/null || { echo "  SKIP: tmux not on PATH" >&2; exit 0; }

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

# Stub state root so we don't pollute the user's ~/.clone-wars
SANDBOX=$(mktemp -d)
export CLONE_WARS_HOME="$SANDBOX/.clone-wars"
mkdir -p "$CLONE_WARS_HOME"

source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/consult.sh"

TOPIC="preflight-test-$$"
REPO_HASH=$(cw_repo_hash)
TOPIC_DIR="$CLONE_WARS_HOME/state/$REPO_HASH/$TOPIC"
ART_DIR="$TOPIC_DIR/_consult"
mkdir -p "$ART_DIR"

# Synthesize a 3-trooper roster
cat > "$ART_DIR/troopers.txt" <<EOF
codex	rex
claude	cody
opencode	bly
EOF

# Open isolated test window — default shell so send-keys reaches a real PTY.
# Setting an explicit shell prompt ($PS1='cw>') would also work but defaulting
# to the user's shell is simpler and matches the production conductor flow.
TEST_WIN="cw-pf-$$-${RANDOM}"
tmux new-window -d -n "$TEST_WIN"
trap 'tmux kill-window -t "$TEST_WIN" 2>/dev/null || true; rm -rf "$SANDBOX"; rm -f /tmp/cw-pf-rc-test-$$.log' EXIT

# Get the test window's first pane (Yoda surrogate)
YODA_PANE=$(tmux list-panes -t "$TEST_WIN" -F '#{pane_id}' | head -1)

# Wait briefly for the shell to be interactive
sleep 0.5

# Send preflight-layout into the test window's pane (so its `tmux display-message`
# resolves to YODA_PANE). Capture stdout+stderr to a deterministic test-side log
# so we can dump it on failure.
LOG_FILE="/tmp/cw-pf-rc-test-$$.log"
# Write PFRC into the log file (NOT to the pane terminal). Polling the file
# is robust against tmux pane resizes (select-layout main-vertical fires
# SIGWINCH which can interfere with terminal-rendered output).
tmux send-keys -t "$YODA_PANE" "CLAUDE_PLUGIN_ROOT='$PLUGIN_ROOT' CLONE_WARS_HOME='$CLONE_WARS_HOME' bash '$PLUGIN_ROOT/bin/preflight-layout.sh' '$TOPIC' 3 > '$LOG_FILE' 2>&1; echo PFRC=\$? >> '$LOG_FILE'" Enter

got_pfrc=""
for _ in $(seq 1 30); do
  if [[ -f "$LOG_FILE" ]]; then
    # `grep || true` so the rc=1 on "no match yet" doesn't trip set -e.
    line=$(grep '^PFRC=' "$LOG_FILE" 2>/dev/null | tail -1 || true)
    if [[ "$line" == "PFRC=0" ]]; then got_pfrc=0; break; fi
    if [[ "$line" == "PFRC=1" ]]; then got_pfrc=1; break; fi
    if [[ "$line" == "PFRC=2" ]]; then got_pfrc=2; break; fi
  fi
  sleep 0.5
done
if [[ -z "$got_pfrc" ]]; then
  echo "FAIL: preflight did not finish in 15s" >&2
  echo "--- last pane content ---" >&2
  echo "$out" >&2
  echo "--- log file ---" >&2
  if [[ -f "$LOG_FILE" ]]; then cat "$LOG_FILE" >&2; else echo "(log file missing)" >&2; fi
  exit 1
fi
if [[ "$got_pfrc" != "0" ]]; then
  echo "FAIL: preflight rc=$got_pfrc" >&2
  if [[ -f "$LOG_FILE" ]]; then cat "$LOG_FILE" >&2; fi
  exit 1
fi

# Assert preflight-panes.txt was written
PFP="$ART_DIR/preflight-panes.txt"
assert_file_exists "$PFP" "preflight-panes.txt written"

# Assert 3 lines, in roster order
mapfile -t LINES < "$PFP"
[[ ${#LINES[@]} -eq 3 ]] || { echo "FAIL: expected 3 lines in preflight-panes.txt, got ${#LINES[@]}" >&2; exit 1; }

[[ "${LINES[0]}" == rex$'\t'* ]]  || { echo "FAIL: line 1 not rex: ${LINES[0]}" >&2; exit 1; }
[[ "${LINES[1]}" == cody$'\t'* ]] || { echo "FAIL: line 2 not cody: ${LINES[1]}" >&2; exit 1; }
[[ "${LINES[2]}" == bly$'\t'* ]]  || { echo "FAIL: line 3 not bly: ${LINES[2]}" >&2; exit 1; }

# Each pane id must be alive
for line in "${LINES[@]}"; do
  pane="${line#*$'\t'}"
  tmux list-panes -a -F '#{pane_id}' | grep -qx "$pane" \
    || { echo "FAIL: pane $pane not alive after preflight" >&2; exit 1; }
done

# Assert pane heights are within ±2 of each other (even-vertical layout)
heights=()
for line in "${LINES[@]}"; do
  pane="${line#*$'\t'}"
  heights+=( "$(tmux display-message -p -t "$pane" '#{pane_height}')" )
done
hmin=${heights[0]}; hmax=${heights[0]}
for h in "${heights[@]}"; do
  (( h < hmin )) && hmin=$h
  (( h > hmax )) && hmax=$h
done
# Tolerance ±5 rows: tmux's main-vertical layout rounds when total height
# isn't evenly divisible by N. The bug we're guarding against is the
# halving cascade (50%/25%/12.5%) which produces diffs of 10+ rows.
diff=$(( hmax - hmin ))
(( diff <= 5 )) || { echo "FAIL: pane heights uneven (min=$hmin max=$hmax diff=$diff > 5)" >&2; exit 1; }

# Each pane must have @cw_label stamped
for line in "${LINES[@]}"; do
  cmdr="${line%%$'\t'*}"; pane="${line#*$'\t'}"
  label=$(tmux display-message -p -t "$pane" '#{@cw_label}')
  assert_contains "$label" "$cmdr" "pane $pane label contains $cmdr"
done

pass "bin/preflight-layout.sh: N=3 happy path (panes created, even heights, ordered TSV, labels stamped)"
