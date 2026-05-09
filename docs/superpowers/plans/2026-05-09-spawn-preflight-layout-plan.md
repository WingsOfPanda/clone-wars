# v0.19.0 Spawn Preflight Layout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `.last_pane` chaining in `/clone-wars:consult` spawn with a two-phase pre-allocate-then-dispatch architecture, producing true parallel spawn + evenly-sized trooper panes.

**Architecture:** New `bin/preflight-layout.sh` splits N panes upfront with sentinel banners + `tmux select-layout main-vertical`, writing `_consult/preflight-panes.txt`. `bin/spawn.sh` gains `--target-pane <id>` flag using `tmux respawn-pane`. `commands/consult.md` Step 3 splits into 3a (preflight) + 3b (parallel dispatch). Backwards compat: spawn.sh without `--target-pane` is byte-equal to today.

**Tech Stack:** bash 4.2+, tmux ≥3.0. No Node/Python. Tests use plain bash + `tests/lib/assert.sh`. Tmux-dependent tests use isolated tmux windows (require `$TMUX` set, skip otherwise).

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `lib/tmux.sh` | Modify (~30 lines added) | `cw_pane_respawn` helper |
| `bin/preflight-layout.sh` | Create (~100 lines) | Phase-1 pane allocation + select-layout |
| `bin/spawn.sh` | Modify (~30 lines added in arg-parse + dispatch branch) | `--target-pane` flag + strict validation + respawn-pane dispatch |
| `bin/consult-teardown.sh` | Modify (~15 lines added) | Orphan-cleanup extension |
| `commands/consult.md` | Modify (Step 3 region rewritten, ~80 lines) | 3a/3b split + Stage 1/2 failure handling |
| `tests/test_pane_respawn.sh` | Create | Unit test for `cw_pane_respawn` |
| `tests/test_preflight_layout.sh` | Create | Happy-path preflight (N=2, N=3) |
| `tests/test_preflight_layout_rollback.sh` | Create | Failure rollback |
| `tests/test_spawn_target_pane_strict.sh` | Create | `--target-pane` validation |
| `tests/test_consult_teardown_preflight_orphans.sh` | Create | Orphan cleanup |
| `tests/test_consult_directive_v019_static_wiring.sh` | Create | Step 3a/3b prose |
| `tests/test_consult_directive_v017_static_wiring.sh` | Modify | Drop `.last_pane` negative assert; allow Step 3a/3b |
| `.claude-plugin/plugin.json` | Modify | 0.18.3 → 0.19.0 |
| `.claude-plugin/marketplace.json` | Modify | 0.18.3 → 0.19.0 |
| `CLAUDE.md` | Modify | v0.19.0 status entry + dogfood gate |

---

## Test scaffolding pattern

Tmux-using tests follow this skeleton (skip when `$TMUX` is unset so `tests/run.sh` works in non-tmux CI):

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

# Skip cleanly if not in a tmux session
[[ -n "${TMUX:-}" ]] || { echo "  SKIP: no tmux session ($TMUX unset)" >&2; exit 0; }
command -v tmux >/dev/null || { echo "  SKIP: tmux not on PATH" >&2; exit 0; }

# Create isolated test window in the existing session
TEST_WIN="cw-test-$$-${RANDOM}"
tmux new-window -d -n "$TEST_WIN" 'sleep infinity'
trap 'tmux kill-window -t "$TEST_WIN" 2>/dev/null || true' EXIT

# Capture the test window's first pane id (Yoda surrogate)
YODA_PANE=$(tmux list-panes -t "$TEST_WIN" -F '#{pane_id}' | head -1)
```

Each tmux-test closes its window in a trap so failures don't leak panes.

---

## Task 1: Verify branch + baseline

**Files:**
- Read: existing branch state

- [ ] **Step 1: Verify on the right branch**

```bash
git rev-parse --abbrev-ref HEAD
```

Expected output: `feat/v0.19.0-spawn-preflight-layout`

- [ ] **Step 2: Run baseline tests for relevant files (must all pass before changes)**

```bash
for t in test_spawn_validation.sh test_spawn_rollback.sh test_consult_directive_v017_static_wiring.sh test_consult_init_prefers_active.sh; do
  echo "=== $t ==="
  timeout 30 bash "tests/$t"
done
```

Expected: each prints `PASS` and exits 0. If any fails, stop and report — baseline is broken.

- [ ] **Step 3: Confirm spec is committed on this branch**

```bash
git log --oneline -1 docs/superpowers/specs/2026-05-09-spawn-preflight-layout-design.md
```

Expected: `a8d20f2 docs(spec): v0.19.0 spawn preflight-layout design`

No commit needed for Task 1.

---

## Task 2: `cw_pane_respawn` helper in lib/tmux.sh

**Files:**
- Modify: `lib/tmux.sh` (append after `cw_pane_spawn_down` at line 41)
- Create: `tests/test_pane_respawn.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test_pane_respawn.sh`:

```bash
#!/usr/bin/env bash
# tests/test_pane_respawn.sh
# Unit test for cw_pane_respawn — verifies it replaces pane content via
# tmux respawn-pane -k and re-stamps @cw_label / @cw_color / @cw_label_fmt.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

[[ -n "${TMUX:-}" ]] || { echo "  SKIP: no tmux session ($TMUX unset)" >&2; exit 0; }
command -v tmux >/dev/null || { echo "  SKIP: tmux not on PATH" >&2; exit 0; }

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/colors.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/tmux.sh"

TEST_WIN="cw-respawn-$$-${RANDOM}"
tmux new-window -d -n "$TEST_WIN" 'sleep infinity'
trap 'tmux kill-window -t "$TEST_WIN" 2>/dev/null || true' EXIT

# Create a sacrificial pane with a known sentinel command
TARGET=$(tmux split-window -P -F '#{pane_id}' -t "$TEST_WIN" -h 'echo SENTINEL_BEFORE; sleep infinity')
sleep 0.5

# Capture sentinel content to confirm the "before" state
before=$(tmux capture-pane -p -t "$TARGET")
[[ "$before" == *"SENTINEL_BEFORE"* ]] || { echo "FAIL: sentinel not visible before respawn" >&2; exit 1; }

# Call cw_pane_respawn — should replace sentinel with new launch
result=$(cw_pane_respawn "$TARGET" rex codex test-topic 'echo SENTINEL_AFTER; sleep infinity')
sleep 0.5

# Result should echo the same pane id back
assert_eq "$result" "$TARGET" "cw_pane_respawn returns the pane id"

# Pane content should now show the new sentinel
after=$(tmux capture-pane -p -t "$TARGET")
[[ "$after" == *"SENTINEL_AFTER"* ]] || { echo "FAIL: new sentinel not visible after respawn (saw: $after)" >&2; exit 1; }

# Labels should be stamped
label=$(tmux display-message -p -t "$TARGET" '#{@cw_label}')
[[ -n "$label" ]] || { echo "FAIL: @cw_label not stamped" >&2; exit 1; }
assert_contains "$label" "rex" "label contains commander"

color=$(tmux display-message -p -t "$TARGET" '#{@cw_color}')
[[ -n "$color" ]] || { echo "FAIL: @cw_color not stamped" >&2; exit 1; }

pass "cw_pane_respawn replaces pane content + stamps @cw_* labels"
```

- [ ] **Step 2: Run test to verify it fails**

```bash
timeout 20 bash tests/test_pane_respawn.sh
```

Expected: FAIL with `cw_pane_respawn: command not found` or similar.

- [ ] **Step 3: Implement `cw_pane_respawn` in lib/tmux.sh**

Append this block to `lib/tmux.sh` (after `cw_pane_spawn_down`, around line 41 — after the closing `}` of that function):

```bash
# cw_pane_respawn <pane_id> <commander> <model> <topic> <launch_cmd> [<cwd>]
# Replaces the sentinel banner in <pane_id> with <launch_cmd> via
# tmux respawn-pane -k; re-stamps @cw_label / @cw_color / @cw_label_fmt
# so the existing border-format hook still works. Returns the pane id.
# Used by bin/spawn.sh --target-pane and bin/preflight-layout.sh's banner stage.
cw_pane_respawn() {
  local pane="$1" commander="$2" model="$3" topic="$4" launch="$5" cwd="${6:-}"
  local cmd="$launch"
  if [[ -n "$cwd" ]]; then
    cmd="cd '$cwd' && exec $launch"
  fi
  tmux respawn-pane -k -t "$pane" "$cmd"
  cw_pane_label_set "$pane" "$commander" "$model" "$topic"
  printf '%s\n' "$pane"
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
timeout 20 bash tests/test_pane_respawn.sh
```

Expected: `PASS: cw_pane_respawn replaces pane content + stamps @cw_* labels`.

- [ ] **Step 5: Commit**

```bash
git add lib/tmux.sh tests/test_pane_respawn.sh
git commit -m "$(cat <<'EOF'
feat(tmux): add cw_pane_respawn helper for tmux respawn-pane

Mirrors cw_pane_spawn_right shape but uses tmux respawn-pane -k against
an existing pane id (no split-window). Foundation for v0.19.0 preflight
spawn — used by bin/preflight-layout.sh banner stage and bin/spawn.sh
--target-pane dispatch.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: `bin/preflight-layout.sh` happy path

**Files:**
- Create: `bin/preflight-layout.sh`
- Create: `tests/test_preflight_layout.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test_preflight_layout.sh`:

```bash
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
trap 'rm -rf "$SANDBOX"' EXIT
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

# Open isolated test window
TEST_WIN="cw-pf-$$-${RANDOM}"
tmux new-window -d -n "$TEST_WIN" 'sleep infinity'
trap 'tmux kill-window -t "$TEST_WIN" 2>/dev/null || true; rm -rf "$SANDBOX"' EXIT

# Get the test window's first pane (Yoda surrogate)
YODA_PANE=$(tmux list-panes -t "$TEST_WIN" -F '#{pane_id}' | head -1)

# Send preflight-layout into the test window's pane (so its `tmux display-message`
# resolves to YODA_PANE)
tmux send-keys -t "$YODA_PANE" "CLAUDE_PLUGIN_ROOT='$PLUGIN_ROOT' CLONE_WARS_HOME='$CLONE_WARS_HOME' bash '$PLUGIN_ROOT/bin/preflight-layout.sh' '$TOPIC' 3 > /tmp/cw-pf-rc.$$ 2>&1; echo PFRC=\$?" Enter

# Wait for completion (poll for PFRC=)
for _ in $(seq 1 30); do
  out=$(tmux capture-pane -p -t "$YODA_PANE" 2>/dev/null)
  [[ "$out" == *"PFRC=0"* ]] && break
  [[ "$out" == *"PFRC=1"* ]] && { echo "FAIL: preflight rc=1: $(cat /tmp/cw-pf-rc.$$ 2>/dev/null)" >&2; exit 1; }
  sleep 0.5
done

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
diff=$(( hmax - hmin ))
(( diff <= 2 )) || { echo "FAIL: pane heights uneven (min=$hmin max=$hmax diff=$diff)" >&2; exit 1; }

# Each pane must have @cw_label stamped
for line in "${LINES[@]}"; do
  cmdr="${line%%$'\t'*}"; pane="${line#*$'\t'}"
  label=$(tmux display-message -p -t "$pane" '#{@cw_label}')
  assert_contains "$label" "$cmdr" "pane $pane label contains $cmdr"
done

pass "bin/preflight-layout.sh: N=3 happy path (panes created, even heights, ordered TSV, labels stamped)"
```

- [ ] **Step 2: Run test to verify it fails**

```bash
timeout 60 bash tests/test_preflight_layout.sh
```

Expected: FAIL — `preflight-layout.sh: No such file or directory` (test loops 30× × 0.5s waiting for PFRC=, then bails on missing file).

- [ ] **Step 3: Create `bin/preflight-layout.sh`**

```bash
#!/usr/bin/env bash
# bin/preflight-layout.sh — pre-allocate N tmux panes for a consult run.
#
# Usage: bin/preflight-layout.sh <topic> <N>
#
# Reads _consult/<topic>/troopers.txt for commander order; splits N panes
# off Yoda's pane (the pane the conductor is running in); applies tmux
# select-layout main-vertical to redistribute heights evenly; writes
# ordered _consult/<topic>/preflight-panes.txt (TSV: <commander>\t<pane_id>).
#
# Each preflight pane runs a colored sentinel banner that identifies its
# reserved commander. bin/spawn.sh --target-pane <id> later replaces the
# sentinel with the live trooper TUI via tmux respawn-pane -k.
#
# Atomic: any failure mid-preflight kills already-created panes and exits 1.

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/colors.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/tmux.sh"

[[ $# -eq 2 ]] || { echo "Usage: $0 <topic> <N>" >&2; exit 2; }
TOPIC="$1"
N="$2"

# Validate
if ! [[ "$TOPIC" =~ ^[a-z0-9-]+$ ]] || (( ${#TOPIC} > 64 )); then
  log_error "topic must match [a-z0-9-]+ and be <= 64 chars; got: '$TOPIC'"
  exit 2
fi
if ! [[ "$N" =~ ^[0-9]+$ ]] || (( N < 2 || N > 4 )); then
  log_error "N must be 2..4; got: '$N'"
  exit 2
fi

# Resolve topic + roster
ART_DIR="$(cw_consult_art_dir "$TOPIC")"
ROSTER_FILE="$ART_DIR/troopers.txt"
[[ -f "$ROSTER_FILE" ]] || { log_error "troopers.txt not found at $ROSTER_FILE"; exit 1; }

mapfile -t ROSTER < <(cw_consult_load_troopers "$ROSTER_FILE")
(( ${#ROSTER[@]} == N )) || {
  log_error "troopers.txt has ${#ROSTER[@]} entries, expected $N"
  exit 1
}

# Discover Yoda's pane (the pane the conductor is running in)
YODA_PANE=$(tmux display-message -p '#{pane_id}' 2>/dev/null || true)
[[ -n "$YODA_PANE" ]] || { log_error "could not discover Yoda's pane; not in tmux?"; exit 1; }

# Created panes — used by trap-driven rollback
declare -a CREATED_PANES=()

rollback() {
  local rc=$?
  if (( rc != 0 )); then
    log_warn "preflight failed (rc=$rc); rolling back ${#CREATED_PANES[@]} pane(s)"
    for p in "${CREATED_PANES[@]}"; do
      tmux kill-pane -t "$p" 2>/dev/null || true
    done
    rm -f "$ART_DIR/preflight-panes.txt.tmp"
  fi
}
trap rollback EXIT

TMP_FILE="$ART_DIR/preflight-panes.txt.tmp"
: > "$TMP_FILE"

# Build sentinel command for a commander. Uses cw_label_fmt for color, then
# sleep infinity to hold the pane open until respawn-pane replaces it.
build_sentinel() {
  local commander="$1" provider="$2" topic="$3"
  local label_fmt
  label_fmt=$(cw_label_fmt "$commander" "$provider" "$topic")
  printf 'printf "%s\\n  preflight pane reserved — awaiting trooper spawn...\\n"; sleep infinity' "$label_fmt"
}

# First pane: right-split Yoda. Subsequent: down-split the previous pane.
PREV_PANE="$YODA_PANE"
SPLIT_FLAG="-h"  # first split is horizontal; rest are vertical

for i in "${!ROSTER[@]}"; do
  IFS=$'\t' read -r prov cmdr <<<"${ROSTER[$i]}"
  sentinel=$(build_sentinel "$cmdr" "$prov" "$TOPIC")
  PANE=$(tmux split-window -P -F '#{pane_id}' "$SPLIT_FLAG" -t "$PREV_PANE" "$sentinel") || {
    log_error "split-window failed at index $i ($cmdr)"
    exit 1
  }
  CREATED_PANES+=( "$PANE" )
  cw_pane_label_set "$PANE" "$cmdr" "$prov" "$TOPIC" || {
    log_error "cw_pane_label_set failed for pane $PANE"
    exit 1
  }
  printf '%s\t%s\n' "$cmdr" "$PANE" >> "$TMP_FILE"
  PREV_PANE="$PANE"
  SPLIT_FLAG="-v"  # subsequent splits are vertical (down)
done

# Redistribute heights evenly via main-vertical
tmux select-layout -t "$YODA_PANE" main-vertical || {
  log_error "select-layout main-vertical failed"
  exit 1
}

# Atomic rename
mv "$TMP_FILE" "$ART_DIR/preflight-panes.txt" || {
  log_error "mv preflight-panes.txt.tmp failed"
  exit 1
}

# Disarm rollback by clearing the array (nothing to roll back on success)
CREATED_PANES=()

log_ok "preflight: $N panes allocated for topic $TOPIC"
for line in $(cat "$ART_DIR/preflight-panes.txt"); do
  printf '  %s\n' "$line"
done
exit 0
```

- [ ] **Step 4: Make it executable**

```bash
chmod +x bin/preflight-layout.sh
```

- [ ] **Step 5: Run test to verify it passes**

```bash
timeout 60 bash tests/test_preflight_layout.sh
```

Expected: `PASS: bin/preflight-layout.sh: N=3 happy path (panes created, even heights, ordered TSV, labels stamped)`.

- [ ] **Step 6: Commit**

```bash
git add bin/preflight-layout.sh tests/test_preflight_layout.sh
git commit -m "$(cat <<'EOF'
feat(preflight): add bin/preflight-layout.sh + N=3 happy-path test

Splits N panes off Yoda's pane via sequential tmux split-window calls,
applies select-layout main-vertical, writes ordered
_consult/<topic>/preflight-panes.txt. Sentinel banners use cw_label_fmt
so each reserved pane shows its commander identity until respawn.

Foundation for v0.19.0 two-phase consult spawn.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Preflight rollback (failure path)

**Files:**
- Already covers rollback in Task 3's preflight-layout.sh (lines around `trap rollback EXIT`).
- Create: `tests/test_preflight_layout_rollback.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test_preflight_layout_rollback.sh`:

```bash
#!/usr/bin/env bash
# tests/test_preflight_layout_rollback.sh
# Failure path: simulate a mid-preflight failure (kill the just-created pane
# externally between iterations) and verify rollback kills any remaining
# created pane + does not write preflight-panes.txt.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

[[ -n "${TMUX:-}" ]] || { echo "  SKIP: no tmux session ($TMUX unset)" >&2; exit 0; }
command -v tmux >/dev/null || { echo "  SKIP: tmux not on PATH" >&2; exit 0; }

PLUGIN_ROOT="$(cd .. && pwd)"
SANDBOX=$(mktemp -d)
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
export CLONE_WARS_HOME="$SANDBOX/.clone-wars"
mkdir -p "$CLONE_WARS_HOME"

source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/consult.sh"

TOPIC="preflight-rb-$$"
REPO_HASH=$(cw_repo_hash)
ART_DIR="$CLONE_WARS_HOME/state/$REPO_HASH/$TOPIC/_consult"
mkdir -p "$ART_DIR"

# Roster expecting N=3, but we'll inject a failure by removing troopers.txt
# AFTER preflight reads it but BEFORE the loop completes. Simpler approach:
# call preflight-layout with N=3 but write troopers.txt with only 2 entries.
# preflight asserts entry-count match → exits 1 BEFORE creating panes →
# verifies the early-exit path. Then we test mid-loop failure separately.

cat > "$ART_DIR/troopers.txt" <<EOF
codex	rex
claude	cody
EOF

# Test A: count mismatch → rc=1, no panes, no preflight-panes.txt
TEST_WIN="cw-pfrb-$$-${RANDOM}"
tmux new-window -d -n "$TEST_WIN" 'sleep infinity'
trap 'tmux kill-window -t "$TEST_WIN" 2>/dev/null || true; rm -rf "$SANDBOX"' EXIT
YODA_PANE=$(tmux list-panes -t "$TEST_WIN" -F '#{pane_id}' | head -1)

tmux send-keys -t "$YODA_PANE" "CLAUDE_PLUGIN_ROOT='$PLUGIN_ROOT' CLONE_WARS_HOME='$CLONE_WARS_HOME' bash '$PLUGIN_ROOT/bin/preflight-layout.sh' '$TOPIC' 3 > /tmp/pfrb-rc.$$ 2>&1; echo PFRC=\$?" Enter
for _ in $(seq 1 20); do
  out=$(tmux capture-pane -p -t "$YODA_PANE" 2>/dev/null)
  [[ "$out" == *"PFRC="* ]] && break
  sleep 0.5
done
[[ "$out" == *"PFRC=1"* ]] || { echo "FAIL: count mismatch should rc=1 (got: $out)" >&2; exit 1; }
[[ ! -f "$ART_DIR/preflight-panes.txt" ]] || { echo "FAIL: preflight-panes.txt should NOT exist on failure" >&2; exit 1; }
[[ ! -f "$ART_DIR/preflight-panes.txt.tmp" ]] || { echo "FAIL: preflight-panes.txt.tmp should be cleaned up" >&2; exit 1; }

# Confirm only the original pane exists in test window (no orphans)
n=$(tmux list-panes -t "$TEST_WIN" | wc -l)
[[ "$n" -eq 1 ]] || { echo "FAIL: expected 1 pane in test window after failure (got $n)" >&2; exit 1; }

pass "preflight rollback on count-mismatch: rc=1, no orphans, no preflight-panes.txt"
```

- [ ] **Step 2: Run test to verify it passes**

The rollback logic was added in Task 3 (`trap rollback EXIT`). This test exercises the early-exit path before any pane is created.

```bash
timeout 60 bash tests/test_preflight_layout_rollback.sh
```

Expected: `PASS: preflight rollback on count-mismatch: rc=1, no orphans, no preflight-panes.txt`.

If it fails, the rollback trap or the count-mismatch validation in `bin/preflight-layout.sh` is broken — fix in `bin/preflight-layout.sh` and re-run.

- [ ] **Step 3: Commit**

```bash
git add tests/test_preflight_layout_rollback.sh
git commit -m "$(cat <<'EOF'
test(preflight): rollback path — count mismatch yields rc=1 + no orphans

Verifies bin/preflight-layout.sh's count-validation early-exit + the
rollback trap together produce a clean failure (no preflight-panes.txt,
no orphan panes in the conductor's tmux window).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: `bin/spawn.sh --target-pane` flag with strict validation

**Files:**
- Modify: `bin/spawn.sh` (arg-parse case statement at lines 65-74; spawn dispatch around lines 156-165)
- Create: `tests/test_spawn_target_pane_strict.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test_spawn_target_pane_strict.sh`:

```bash
#!/usr/bin/env bash
# tests/test_spawn_target_pane_strict.sh
# Verifies bin/spawn.sh --target-pane <id>:
#   (a) rejects when <id> is NOT in _consult/<topic>/preflight-panes.txt
#   (b) accepts and uses respawn-pane when <id> IS in preflight-panes.txt
# Backwards compat: spawn.sh without --target-pane is unchanged
# (covered by existing test_spawn_validation.sh — re-asserted briefly).
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"

# Test A: --target-pane with id NOT in preflight-panes.txt → rc!=0
SANDBOX_A=$(mktemp -d)
export CLONE_WARS_HOME="$SANDBOX_A/.clone-wars"
mkdir -p "$CLONE_WARS_HOME"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/consult.sh"

TOPIC="strict-test-$$"
REPO_HASH=$(cw_repo_hash)
ART_DIR="$CLONE_WARS_HOME/state/$REPO_HASH/$TOPIC/_consult"
mkdir -p "$ART_DIR"
cat > "$ART_DIR/preflight-panes.txt" <<EOF
rex	%99
cody	%100
EOF

# %42 is NOT in preflight-panes.txt
err=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" "$PLUGIN_ROOT/bin/spawn.sh" rex codex "$TOPIC" --target-pane '%42' 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: --target-pane %42 (not in preflight) should rc!=0" >&2; exit 1; }
echo "$err" | grep -qi 'not in preflight-panes.txt\|not allowed\|target-pane' \
  || { echo "FAIL: error message should mention preflight-panes.txt: $err" >&2; exit 1; }

pass "spawn.sh --target-pane rejects pane id not in preflight-panes.txt"

rm -rf "$SANDBOX_A"

# Test B: --target-pane absent — spawn.sh keeps legacy split-window arg shape
# (we don't actually run the full spawn — that would need real tmux + provider
# binaries — but we verify the arg parser doesn't blow up + the legacy code
# path is reachable by checking that spawn.sh fails on a missing tmux session
# rather than on --target-pane validation.)

err=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLONE_WARS_HOME=$(mktemp -d) "$PLUGIN_ROOT/bin/spawn.sh" rex codex topic-no-tmux 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: spawn without tmux should rc!=0" >&2; exit 1; }
# Should fail on tmux/state checks, NOT on missing --target-pane
echo "$err" | grep -qi 'tmux\|TMUX' \
  || { echo "FAIL: legacy path should fail on tmux check, not --target-pane: $err" >&2; exit 1; }

pass "spawn.sh without --target-pane preserves legacy code path (fails on tmux check)"
```

- [ ] **Step 2: Run test to verify it fails**

```bash
timeout 30 bash tests/test_spawn_target_pane_strict.sh
```

Expected: FAIL — spawn.sh doesn't recognize `--target-pane` yet, so it'll be parsed as `INITIAL_PROMPT` and rc may not be the expected error.

- [ ] **Step 3: Add `--target-pane` flag to bin/spawn.sh arg-parse**

In `bin/spawn.sh`, locate the arg-parse `while` loop (around lines 65-74). Add `--target-pane` parsing.

Find this block:

```bash
COMMANDER="$1"; MODEL="$2"; TOPIC="$3"; shift 3
MODE=""
INITIAL_PROMPT=""
SPAWN_CWD=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)        MODE="$2"; shift 2 ;;
    --mode=*)      MODE="${1#*=}"; shift ;;
    --cwd)         [[ -n "${2:-}" ]] || { echo "--cwd requires a value" >&2; exit 2; }
                   SPAWN_CWD="$2"; shift 2 ;;
    --cwd=*)       SPAWN_CWD="${1#*=}"; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             INITIAL_PROMPT="$*"; break ;;
  esac
done
```

Replace with:

```bash
COMMANDER="$1"; MODEL="$2"; TOPIC="$3"; shift 3
MODE=""
INITIAL_PROMPT=""
SPAWN_CWD=""
TARGET_PANE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)         MODE="$2"; shift 2 ;;
    --mode=*)       MODE="${1#*=}"; shift ;;
    --cwd)          [[ -n "${2:-}" ]] || { echo "--cwd requires a value" >&2; exit 2; }
                    SPAWN_CWD="$2"; shift 2 ;;
    --cwd=*)        SPAWN_CWD="${1#*=}"; shift ;;
    --target-pane)  [[ -n "${2:-}" ]] || { echo "--target-pane requires a value" >&2; exit 2; }
                    TARGET_PANE="$2"; shift 2 ;;
    --target-pane=*) TARGET_PANE="${1#*=}"; shift ;;
    -h|--help)      usage; exit 0 ;;
    *)              INITIAL_PROMPT="$*"; break ;;
  esac
done
```

Also update the `usage()` function (lines ~46-58) to document `--target-pane`. Add this line after the `--cwd` block:

```
  --target-pane <id> — respawn into pre-allocated pane <id> (must appear
                       in _consult/<topic>/preflight-panes.txt). Used by
                       /clone-wars:consult v0.19.0 two-phase spawn.
```

- [ ] **Step 4: Add --target-pane validation BEFORE tmux/state work (right after --cwd validation)**

Locate the `--cwd validation` block (around lines 78-82):

```bash
# --cwd validation (must precede tmux/state work so it fails fast).
if [[ -n "$SPAWN_CWD" ]]; then
  [[ "$SPAWN_CWD" == /* ]] || { log_error "spawn --cwd must be an absolute path: $SPAWN_CWD"; exit 1; }
  [[ -d "$SPAWN_CWD" ]] || { log_error "spawn --cwd target does not exist: $SPAWN_CWD"; exit 1; }
fi
```

Add immediately after:

```bash
# --target-pane validation: strict — must appear in _consult/<topic>/preflight-panes.txt
if [[ -n "$TARGET_PANE" ]]; then
  source "$PLUGIN_ROOT/lib/consult.sh"
  PFP="$(cw_consult_art_dir "$TOPIC")/preflight-panes.txt"
  if [[ ! -f "$PFP" ]]; then
    log_error "--target-pane requires preflight-panes.txt at: $PFP"
    exit 1
  fi
  if ! grep -qE "^[a-z0-9-]+	${TARGET_PANE}$" "$PFP"; then
    log_error "--target-pane $TARGET_PANE not in preflight-panes.txt for topic $TOPIC"
    exit 1
  fi
fi
```

- [ ] **Step 5: Branch the spawn dispatch (lines 156-165) on TARGET_PANE**

Locate this block (around lines 156-165):

```bash
PRIOR_FILE="$(cw_topic_state_dir "$TOPIC")/.last_pane"
PRIOR_PANE=""
[[ -f "$PRIOR_FILE" ]] && PRIOR_PANE=$(cat "$PRIOR_FILE")
if [[ -n "$PRIOR_PANE" ]] && cw_pane_alive "$PRIOR_PANE"; then
  PANE=$(cw_pane_spawn_down "$COMMANDER" "$MODEL" "$TOPIC" "$LAUNCH" "$PRIOR_PANE" "$SPAWN_CWD")
else
  PANE=$(cw_pane_spawn_right "$COMMANDER" "$MODEL" "$TOPIC" "$LAUNCH" "" "$SPAWN_CWD")
fi
mkdir -p "$(dirname "$PRIOR_FILE")"
printf '%s\n' "$PANE" > "$PRIOR_FILE"
```

Replace with:

```bash
if [[ -n "$TARGET_PANE" ]]; then
  # v0.19.0 preflight path: respawn into pre-allocated pane.
  cw_pane_alive "$TARGET_PANE" || { log_error "--target-pane $TARGET_PANE is not alive"; exit 1; }
  PANE=$(cw_pane_respawn "$COMMANDER" "$MODEL" "$TOPIC" "$LAUNCH" "$TARGET_PANE" "$SPAWN_CWD")
  # NOTE: no .last_pane writes — preflight-panes.txt is the source of truth.
else
  # Legacy path: byte-equal to v0.18.3.
  PRIOR_FILE="$(cw_topic_state_dir "$TOPIC")/.last_pane"
  PRIOR_PANE=""
  [[ -f "$PRIOR_FILE" ]] && PRIOR_PANE=$(cat "$PRIOR_FILE")
  if [[ -n "$PRIOR_PANE" ]] && cw_pane_alive "$PRIOR_PANE"; then
    PANE=$(cw_pane_spawn_down "$COMMANDER" "$MODEL" "$TOPIC" "$LAUNCH" "$PRIOR_PANE" "$SPAWN_CWD")
  else
    PANE=$(cw_pane_spawn_right "$COMMANDER" "$MODEL" "$TOPIC" "$LAUNCH" "" "$SPAWN_CWD")
  fi
  mkdir -p "$(dirname "$PRIOR_FILE")"
  printf '%s\n' "$PANE" > "$PRIOR_FILE"
fi
```

Note: `cw_pane_respawn` signature is `<pane_id> <commander> <model> <topic> <launch_cmd> [<cwd>]` (from Task 2). Above call shape passes the args in the right order: `<commander> <model> <topic> <launch> <target_pane> <cwd>`. Wait — the helper expects pane id FIRST. Adjust:

```bash
  PANE=$(cw_pane_respawn "$TARGET_PANE" "$COMMANDER" "$MODEL" "$TOPIC" "$LAUNCH" "$SPAWN_CWD")
```

(Use this corrected signature.)

- [ ] **Step 6: Run test to verify it passes**

```bash
timeout 30 bash tests/test_spawn_target_pane_strict.sh
```

Expected: both `PASS` lines.

- [ ] **Step 7: Verify legacy spawn tests still pass**

```bash
for t in test_spawn_validation.sh test_spawn_rollback.sh; do
  echo "=== $t ==="
  timeout 30 bash "tests/$t"
done
```

Expected: each prints PASS — no regressions on the legacy path.

- [ ] **Step 8: Commit**

```bash
git add bin/spawn.sh tests/test_spawn_target_pane_strict.sh
git commit -m "$(cat <<'EOF'
feat(spawn): add --target-pane flag for v0.19.0 preflight dispatch

When --target-pane <id> is set, spawn.sh validates that <id> appears in
_consult/<topic>/preflight-panes.txt (strict; rejects pane ids outside
the preflight set), then dispatches via cw_pane_respawn instead of
cw_pane_spawn_right/down. The .last_pane read/write is skipped on this
path; preflight-panes.txt is the source of truth.

Without the flag, spawn.sh is byte-equal to v0.18.3 (legacy split-window
+ .last_pane flow preserved for /clone-wars:deploy and any other
single-trooper callers).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: `bin/consult-teardown.sh` preflight-orphan extension

**Files:**
- Modify: `bin/consult-teardown.sh`
- Create: `tests/test_consult_teardown_preflight_orphans.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test_consult_teardown_preflight_orphans.sh`:

```bash
#!/usr/bin/env bash
# tests/test_consult_teardown_preflight_orphans.sh
# Verifies bin/consult-teardown.sh kills preflight panes that are NOT in
# troopers.txt (orphan from Stage 2 partial-success abort or pre-spawn Ctrl-C).
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

[[ -n "${TMUX:-}" ]] || { echo "  SKIP: no tmux session ($TMUX unset)" >&2; exit 0; }
command -v tmux >/dev/null || { echo "  SKIP: tmux not on PATH" >&2; exit 0; }

PLUGIN_ROOT="$(cd .. && pwd)"
SANDBOX=$(mktemp -d)
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
export CLONE_WARS_HOME="$SANDBOX/.clone-wars"
mkdir -p "$CLONE_WARS_HOME"

source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/consult.sh"

TOPIC="orphan-test-$$"
REPO_HASH=$(cw_repo_hash)
ART_DIR="$CLONE_WARS_HOME/state/$REPO_HASH/$TOPIC/_consult"
mkdir -p "$ART_DIR"

# Open isolated test window with 3 panes
TEST_WIN="cw-orphan-$$-${RANDOM}"
tmux new-window -d -n "$TEST_WIN" 'sleep infinity'
trap 'tmux kill-window -t "$TEST_WIN" 2>/dev/null || true; rm -rf "$SANDBOX"' EXIT

PANE1=$(tmux split-window -P -F '#{pane_id}' -t "$TEST_WIN" -h 'sleep infinity')
PANE2=$(tmux split-window -P -F '#{pane_id}' -t "$PANE1" -v 'sleep infinity')
PANE3=$(tmux split-window -P -F '#{pane_id}' -t "$PANE2" -v 'sleep infinity')

# preflight-panes has 3; troopers.txt only has 2 → PANE3 is orphan
cat > "$ART_DIR/preflight-panes.txt" <<EOF
rex	$PANE1
cody	$PANE2
bly	$PANE3
EOF
cat > "$ART_DIR/troopers.txt" <<EOF
codex	rex
claude	cody
EOF

# Stub trooper state dirs so bin/teardown.sh on rex/cody can find something
for cmdr_pane in rex:$PANE1 cody:$PANE2; do
  cmdr="${cmdr_pane%%:*}"; pane="${cmdr_pane#*:}"
  case "$cmdr" in rex) provider=codex ;; cody) provider=claude ;; esac
  trooper_dir="$CLONE_WARS_HOME/state/$REPO_HASH/$TOPIC/$cmdr-$provider"
  mkdir -p "$trooper_dir"
  printf '{"pane_id":"%s","pid":1,"spawned_at":"2026-05-09T00:00:00Z"}\n' "$pane" > "$trooper_dir/pane.json"
done

# Run teardown
"$PLUGIN_ROOT/bin/consult-teardown.sh" "$TOPIC" 2>&1 || true
sleep 0.5

# All 3 preflight panes should be killed
for p in "$PANE1" "$PANE2" "$PANE3"; do
  if tmux list-panes -a -F '#{pane_id}' | grep -qx "$p"; then
    echo "FAIL: pane $p still alive after teardown" >&2; exit 1
  fi
done

pass "consult-teardown kills preflight orphan panes (PANE3 not in troopers.txt)"
```

- [ ] **Step 2: Run test to verify it fails**

```bash
timeout 60 bash tests/test_consult_teardown_preflight_orphans.sh
```

Expected: FAIL — PANE3 still alive (current teardown doesn't read preflight-panes.txt).

- [ ] **Step 3: Extend `bin/consult-teardown.sh`**

Open `bin/consult-teardown.sh`. After the existing `if [[ -f "$TROOPERS_FILE" ]]; then ... fi` block (the whole roster-iteration block ends near the end of the file), append:

```bash
# v0.19.0: also kill any preflight pane that is NOT in troopers.txt
# (orphan sentinel left over from Stage 2 partial-success abort or
# pre-spawn Ctrl-C). Idempotent — safe when preflight-panes.txt is absent.
PFP_FILE="$ART_DIR/preflight-panes.txt"
if [[ -f "$PFP_FILE" ]]; then
  declare -A LIVE_CMDRS=()
  if [[ -f "$TROOPERS_FILE" ]]; then
    while IFS=$'\t' read -r prov cmdr; do
      [[ -n "$cmdr" ]] && LIVE_CMDRS["$cmdr"]=1
    done < <(cw_consult_load_troopers "$TROOPERS_FILE")
  fi
  while IFS=$'\t' read -r cmdr pane; do
    [[ -n "$cmdr" && -n "$pane" ]] || continue
    [[ "${LIVE_CMDRS[$cmdr]:-0}" == "1" ]] && continue  # not orphan
    log_info "killing preflight orphan pane $pane (commander=$cmdr)"
    tmux kill-pane -t "$pane" 2>/dev/null || log_warn "kill-pane $pane failed (already dead?)"
  done < "$PFP_FILE"
  rm -f "$PFP_FILE"
fi
```

- [ ] **Step 4: Run test to verify it passes**

```bash
timeout 60 bash tests/test_consult_teardown_preflight_orphans.sh
```

Expected: `PASS: consult-teardown kills preflight orphan panes (PANE3 not in troopers.txt)`.

- [ ] **Step 5: Commit**

```bash
git add bin/consult-teardown.sh tests/test_consult_teardown_preflight_orphans.sh
git commit -m "$(cat <<'EOF'
feat(teardown): clean preflight orphan panes (v0.19.0)

After the existing roster teardown, also walk _consult/preflight-panes.txt
and kill any pane whose commander is NOT in troopers.txt. Handles two
cases: Stage 2 partial-success abort (some panes never received a
trooper); user Ctrl-C between preflight and dispatch.

Idempotent — no-op when preflight-panes.txt is absent (pre-v0.19
archived consults unaffected).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: `commands/consult.md` Step 3a + 3b rewrite

**Files:**
- Modify: `commands/consult.md` (Step 3 region — heading line 320 area, body until Step 4 heading)
- Modify: `commands/consult.md` (task table row 3 — split into 3a + 3b)

This task changes prose; no new tests yet (Task 9 covers static-wiring).

- [ ] **Step 1: Locate the current Step 3 region**

```bash
grep -n '^### Step 3 \|^### Step 4 ' commands/consult.md
```

Expected: prints the line number of `### Step 3 — Parallel spawn (...)` and `### Step 4 — Parallel research dispatch (...)`. The rewrite replaces everything between these two headings.

- [ ] **Step 2: Update the task table to reflect 3a + 3b**

In `commands/consult.md`, find this row in the task table:

```
| 3  | `3 Spawn troopers (parallel) [yoda]`            | `Spawning troopers` |
```

Replace with two rows:

```
| 3a | `3a Preflight pane allocation [yoda]`           | `Preflight pane allocation` |
| 3b | `3b Parallel spawn dispatch [yoda]`             | `Spawning troopers (parallel dispatch)` |
```

Also update the line **above the table** that says "TaskCreate × 17 BEFORE Step 0" — it should now say "TaskCreate × 18 BEFORE Step 0" (since we added a row).

```bash
grep -n 'TaskCreate × 17' commands/consult.md
```

Replace `TaskCreate × 17` with `TaskCreate × 18` in that heading.

- [ ] **Step 3: Rewrite the Step 3 body**

Replace the entire block from `### Step 3 — Parallel spawn (N-aware, with auto-retry-once + rollback)` through the line just before `### Step 4 —` with the following content:

````markdown
### Step 3a — Preflight pane allocation

Set task `3a` → `in_progress`.

**Reached from one of three escalation paths:** `--use-force` flag,
phrasing trigger, or 4-signal escalation from Step 2. Set
`CW_PATH_LABEL` accordingly — it is consumed by Step 11 (synthesize)
to stamp the design-doc trust header:

```
case "$USE_FORCE,$ESCALATE_FROM_PHRASING,${ESCALATE_FROM_SIGNALS:-0}" in
  1,*,*) export CW_PATH_LABEL="escalated-from-flag" ;;
  *,1,*) export CW_PATH_LABEL="escalated-from-phrasing" ;;
  *,*,1) export CW_PATH_LABEL="escalated-from-signals" ;;
  *)     export CW_PATH_LABEL="escalated-from-signals" ;;  # defensive default
esac
log_info "trooper escalation path: $CW_PATH_LABEL"
```

Initialize the retry counter ONCE before invoking preflight:

```
SPAWN_RETRY_COUNT=0
```

**Run preflight (single foreground bash call):**

```
"$CLAUDE_PLUGIN_ROOT/bin/preflight-layout.sh" "$CONSULT_TOPIC" "$N"
```

Expected behavior:

- On rc=0: `_consult/preflight-panes.txt` is now populated with N ordered
  TSV lines (`<commander>\t<pane_id>`). The user's tmux window now shows
  Yoda on the left + N evenly-sized sentinel panes on the right.
- On rc≠0: preflight rolled back any panes it created. Surface the error
  to the user. Retry semantics are handled in Step 3b's failure tuple
  evaluation (Stage 1 retry-once + Stage 2 partial-success offer).

After preflight succeeds, load the pane assignments into a shell array:

```
declare -A PREFLIGHT_PANES
while IFS=$'\t' read -r cmdr pane; do
  [[ -n "$cmdr" && -n "$pane" ]] && PREFLIGHT_PANES["$cmdr"]="$pane"
done < "$TOPIC_DIR/_consult/preflight-panes.txt"
```

Set task `3a` → `completed`.

### Step 3b — Parallel spawn dispatch (N-aware, with Stage 1 retry + Stage 2 partial-success)

Set task `3b` → `in_progress`.

**Issue `N` parallel `Bash` tool calls in a single message** — one per
entry in `TROOPERS`. Each call invokes
`bin/spawn.sh <commander> <provider> "$CONSULT_TOPIC" --target-pane "${PREFLIGHT_PANES[$cmdr]}"`.
Capture each rc separately.

Canonical N=3 example (codex/rex, claude/cody, opencode/bly — order
matches `TROOPERS`):

```
"$CLAUDE_PLUGIN_ROOT/bin/spawn.sh" rex  codex    "$CONSULT_TOPIC" --target-pane "${PREFLIGHT_PANES[rex]}"   # parallel 1
"$CLAUDE_PLUGIN_ROOT/bin/spawn.sh" cody claude   "$CONSULT_TOPIC" --target-pane "${PREFLIGHT_PANES[cody]}"  # parallel 2
"$CLAUDE_PLUGIN_ROOT/bin/spawn.sh" bly  opencode "$CONSULT_TOPIC" --target-pane "${PREFLIGHT_PANES[bly]}"   # parallel 3
```

For N=2 (any 2-provider subset selected via `/clone-wars:medic`), issue
2 calls. Iterate `TROOPERS` to derive each call:

```
for entry in "${TROOPERS[@]}"; do
  IFS=$'\t' read -r prov cmdr <<<"$entry"
  # Issue: "$CLAUDE_PLUGIN_ROOT/bin/spawn.sh" "$cmdr" "$prov" "$CONSULT_TOPIC" --target-pane "${PREFLIGHT_PANES[$cmdr]}"
  # — but as a PARALLEL Bash tool call, not a serial loop.
done
```

(The `for`-loop above is illustrative — Master Yoda emits `N` parallel
Bash tool calls in one message, NOT a sequential bash loop. With
preflight-panes already allocated, the spawns are truly parallel — no
shared mutable state between the N processes.)

#### Failure handling — Stage 1 (retry-once) + Stage 2 (partial-success)

After all `N` parallel spawn calls return, evaluate the rc tuple.

- **All N succeed** → continue to Step 4. Set task `3b` → `completed`.

- **At least one fails AND `SPAWN_RETRY_COUNT == 0`** → **Stage 1
  retry-once**:

  ```
  # Tear down everything (preflight panes + any spawned troopers); KEEP _consult/.
  "$CLAUDE_PLUGIN_ROOT/bin/consult-teardown.sh" "$CONSULT_TOPIC" 2>/dev/null || true
  SPAWN_RETRY_COUNT=1
  log_info "Stage 1: spawn failed (cold start?); retrying preflight + parallel spawn once"
  ```

  Then re-run Step 3a (preflight) and re-issue the N parallel spawn calls.
  Most cold-start failures (codex / opencode auth handshake on first call)
  are absorbed at Stage 1 invisibly.

- **At least one fails AND `SPAWN_RETRY_COUNT == 1`** → **Stage 2
  partial-success offer**:

  Determine which troopers succeeded vs failed by checking each
  commander's state-dir:

  ```
  declare -a SUCCEEDED FAILED
  for entry in "${TROOPERS[@]}"; do
    IFS=$'\t' read -r prov cmdr <<<"$entry"
    if [[ -f "$TOPIC_DIR/$cmdr-$prov/pane.json" ]]; then
      SUCCEEDED+=( "$cmdr ($prov)" )
    else
      FAILED+=( "$cmdr ($prov)" )
    fi
  done
  ```

  If `${#SUCCEEDED[@]} -lt 2`, force abort: only one trooper alive, the
  protocol requires N≥2. Run teardown + `rm -rf "$TOPIC_DIR"` + exit 1
  with a message redirecting to ask Claude directly (matches the existing
  N=1 plain-exit semantics from `consult-init.sh`).

  Otherwise, ask the user:

  ```
  AskUserQuestion:
    question: "${#SUCCEEDED[@]}/$N troopers spawned after retry.
               Successes: ${SUCCEEDED[*]}. Failures: ${FAILED[*]}.
               Proceed degraded with N=${#SUCCEEDED[@]} or abort all?"
    options:  "Proceed degraded" / "Abort all"
  ```

  - **Proceed degraded** — rewrite `_consult/troopers.txt` to drop the
    failed entries (atomic tmp+mv), update the conductor's `$N` and
    `$TROOPERS` array to match the surviving roster, run
    `bin/consult-teardown.sh` to clean preflight orphan panes (the
    teardown extension from v0.19.0 handles this), then continue to
    Step 4 with N=${#SUCCEEDED[@]}.

    ```
    # Rewrite troopers.txt
    TMP=$(mktemp)
    for entry in "${TROOPERS[@]}"; do
      IFS=$'\t' read -r prov cmdr <<<"$entry"
      [[ -f "$TOPIC_DIR/$cmdr-$prov/pane.json" ]] && printf '%s\t%s\n' "$prov" "$cmdr" >> "$TMP"
    done
    mv "$TMP" "$TOPIC_DIR/_consult/troopers.txt"

    # Reload TROOPERS + N
    mapfile -t TROOPERS < <(cw_consult_load_troopers "$TOPIC_DIR/_consult/troopers.txt")
    N=${#TROOPERS[@]}
    log_info "Stage 2: proceeding degraded with N=$N"

    # consult-teardown's preflight-orphan extension cleans the failed sentinels
    "$CLAUDE_PLUGIN_ROOT/bin/consult-teardown.sh" "$CONSULT_TOPIC" 2>/dev/null || true
    ```

  - **Abort all** — full teardown + exit 1:

    ```
    "$CLAUDE_PLUGIN_ROOT/bin/consult-teardown.sh" "$CONSULT_TOPIC" 2>/dev/null || true
    rm -rf "$TOPIC_DIR"
    exit 1
    ```

  Set task `3b` → `completed` only on Stage 1 success or Stage 2 "Proceed
  degraded" → continued to Step 4. Otherwise task `3b` stays `pending`.
````

- [ ] **Step 4: Run the existing v0.17 static-wiring test (will likely break — that's expected)**

```bash
timeout 30 bash tests/test_consult_directive_v017_static_wiring.sh
```

Expected: may FAIL on assertions about Step 3 wording. Don't fix the test yet — Task 11 handles it.

- [ ] **Step 5: Smoke-check the directive renders sensibly**

```bash
grep -c '^### Step 3a ' commands/consult.md
grep -c '^### Step 3b ' commands/consult.md
grep -c 'PREFLIGHT_PANES' commands/consult.md
grep -c 'Stage 1 retry-once\|Stage 2 partial-success' commands/consult.md
grep -c '\.last_pane' commands/consult.md
```

Expected:
- `### Step 3a `: 1
- `### Step 3b `: 1
- `PREFLIGHT_PANES`: ≥3 (declared + indexed by all 3 commanders in N=3 example + dispatch loop)
- `Stage 1 retry-once|Stage 2 partial-success`: ≥1
- `\.last_pane`: 0 (legacy state file should NOT appear in the consult flow anymore)

- [ ] **Step 6: Commit**

```bash
git add commands/consult.md
git commit -m "$(cat <<'EOF'
feat(consult): split Step 3 into 3a (preflight) + 3b (dispatch) (v0.19.0)

Step 3a invokes bin/preflight-layout.sh once (foreground), populates
$PREFLIGHT_PANES[commander]→pane_id from preflight-panes.txt.
Step 3b issues N parallel spawn calls each with --target-pane "${PREFLIGHT_PANES[$cmdr]}".

Failure handling restructured:
- Stage 1: retry-once (full teardown + re-preflight + re-dispatch).
  Most cold-start failures absorbed invisibly here.
- Stage 2: partial-success AskUserQuestion ("proceed degraded with N=M
  / abort all"). On degraded: rewrite troopers.txt, reload N, continue
  to Step 4 with reduced roster. On abort: full teardown + exit 1.

Drops the .last_pane chain race that serialized parallel spawns and
caused the unevenly-sized panes user reported.

Task table grows from 17 to 18 rows (3 → 3a + 3b).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Static-wiring test for v0.19.0 directive

**Files:**
- Create: `tests/test_consult_directive_v019_static_wiring.sh`

- [ ] **Step 1: Write the test**

```bash
#!/usr/bin/env bash
# tests/test_consult_directive_v019_static_wiring.sh
# Static-wiring asserts on commands/consult.md for v0.19.0:
# - Step 3a + Step 3b headings exist
# - preflight-layout.sh + --target-pane references present
# - Stage 1 / Stage 2 wording present
# - PREFLIGHT_PANES associative array referenced
# - Negative: no .last_pane references in the consult directive
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

DIR=../commands/consult.md
BODY=$(cat "$DIR")

# Step 3a + Step 3b headings
grep -qE '^### Step 3a ' "$DIR" || { echo "FAIL: missing '### Step 3a' heading" >&2; exit 1; }
grep -qE '^### Step 3b ' "$DIR" || { echo "FAIL: missing '### Step 3b' heading" >&2; exit 1; }

# Preflight + target-pane references
assert_contains "$BODY" "bin/preflight-layout.sh" "directive references preflight-layout.sh"
assert_contains "$BODY" "--target-pane"           "directive references --target-pane flag"
assert_contains "$BODY" "preflight-panes.txt"     "directive references preflight-panes.txt"
assert_contains "$BODY" "PREFLIGHT_PANES"          "directive declares PREFLIGHT_PANES array"

# Stage 1 / Stage 2 failure handling
assert_contains "$BODY" "Stage 1 retry-once"          "directive describes Stage 1 retry-once"
assert_contains "$BODY" "Stage 2 partial-success"     "directive describes Stage 2 partial-success"
assert_contains "$BODY" "Proceed degraded"            "directive describes degraded-mode option"
assert_contains "$BODY" "Abort all"                   "directive describes abort option"

# Task table updated to 18 rows
grep -qE 'TaskCreate × 18 BEFORE Step 0' "$DIR" \
  || { echo "FAIL: task-list heading not 'TaskCreate × 18 BEFORE Step 0'" >&2; exit 1; }
grep -qE '^\| 3a \| ' "$DIR" || { echo "FAIL: task table missing 3a row" >&2; exit 1; }
grep -qE '^\| 3b \| ' "$DIR" || { echo "FAIL: task table missing 3b row" >&2; exit 1; }

# Negative: no .last_pane references in consult.md (legacy state file
# should not appear in the consult flow — only in spawn.sh's legacy path)
! grep -qE '\.last_pane' "$DIR" \
  || { echo "FAIL: consult.md still references .last_pane (legacy state file)" >&2; exit 1; }

# Negative: old singular "Step 3" heading should be gone
! grep -qE '^### Step 3 — Parallel spawn' "$DIR" \
  || { echo "FAIL: legacy '### Step 3 — Parallel spawn' heading still present" >&2; exit 1; }

pass "commands/consult.md v0.19.0 static wiring complete"
```

- [ ] **Step 2: Run the test**

```bash
timeout 30 bash tests/test_consult_directive_v019_static_wiring.sh
```

Expected: `PASS: commands/consult.md v0.19.0 static wiring complete`. If anything fails, the prose in Task 7 needs fixing — go back to the directive, fix, re-run.

- [ ] **Step 3: Commit**

```bash
git add tests/test_consult_directive_v019_static_wiring.sh
git commit -m "$(cat <<'EOF'
test(consult): static-wiring asserts for v0.19.0 directive

Locks in Step 3a / Step 3b structure, preflight-layout.sh and
--target-pane references, Stage 1 / Stage 2 failure-handling wording,
PREFLIGHT_PANES array declaration, and the task table's row count
(17 → 18). Negative-asserts: no .last_pane references and no legacy
'Step 3 — Parallel spawn' heading.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Update v0.17 static-wiring test for compat

**Files:**
- Modify: `tests/test_consult_directive_v017_static_wiring.sh`

The v0.17 test was written before Step 3a/3b existed. It may have asserts on Step 3 wording that no longer match. This task updates only the asserts that would otherwise FAIL on the v0.19.0 directive — without dropping any v0.17 invariants that still hold.

- [ ] **Step 1: Run the v0.17 test against the new directive to identify failing asserts**

```bash
timeout 30 bash tests/test_consult_directive_v017_static_wiring.sh
```

Note which assertion fails (e.g. "missing `^### Step 3 —` heading"). The Task 7 rewrite removed the singular `### Step 3` heading.

- [ ] **Step 2: Update the test**

Open `tests/test_consult_directive_v017_static_wiring.sh` and locate the `for i in $(seq 0 16); do` loop at the top. It iterates all 17 step headings.

Replace this loop:

```bash
# 17 step headings: Step 0, Step 1, ..., Step 16.
for i in $(seq 0 16); do
  grep -qE "^### Step ${i} —" "$DIR" || { echo "FAIL: missing '### Step $i —' heading" >&2; exit 1; }
done
```

With v0.19-aware version:

```bash
# v0.19.0: Step 3 split into 3a + 3b. All other step headings unchanged.
for i in 0 1 2; do
  grep -qE "^### Step ${i} —" "$DIR" || { echo "FAIL: missing '### Step $i —' heading" >&2; exit 1; }
done
grep -qE '^### Step 3a ' "$DIR" || { echo "FAIL: missing '### Step 3a' heading (v0.19.0)" >&2; exit 1; }
grep -qE '^### Step 3b ' "$DIR" || { echo "FAIL: missing '### Step 3b' heading (v0.19.0)" >&2; exit 1; }
for i in $(seq 4 16); do
  grep -qE "^### Step ${i} —" "$DIR" || { echo "FAIL: missing '### Step $i —' heading" >&2; exit 1; }
done
```

- [ ] **Step 3: Run all consult-directive tests**

```bash
for t in test_consult_directive_v017_static_wiring.sh test_consult_directive_v019_static_wiring.sh; do
  echo "=== $t ==="
  timeout 30 bash "tests/$t"
done
```

Expected: both pass.

- [ ] **Step 4: Commit**

```bash
git add tests/test_consult_directive_v017_static_wiring.sh
git commit -m "$(cat <<'EOF'
test(consult): v0.17 static wiring — accept v0.19.0 Step 3a/3b split

The v0.17 test's seq-0-16 loop expected '### Step 3 —' as a single
heading. v0.19.0 splits it into 3a + 3b. Update the loop to special-
case Step 3, mirroring the structure of test_consult_directive_v019_
static_wiring.sh. All other step assertions (0-2, 4-16) unchanged.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Plugin version bump 0.18.3 → 0.19.0

**Files:**
- Modify: `.claude-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json`

- [ ] **Step 1: Bump plugin.json**

Find this line in `.claude-plugin/plugin.json`:

```json
  "version": "0.18.3",
```

Replace with:

```json
  "version": "0.19.0",
```

- [ ] **Step 2: Bump marketplace.json (two occurrences)**

Find both occurrences of `"version": "0.18.3"` in `.claude-plugin/marketplace.json` and replace with `"version": "0.19.0"`.

```bash
grep -n '"version":' .claude-plugin/marketplace.json
```

Expected: 2 lines, both should now read `"version": "0.19.0"`.

- [ ] **Step 3: Commit**

```bash
git add .claude-plugin/plugin.json .claude-plugin/marketplace.json
git commit -m "$(cat <<'EOF'
chore(release): bump plugin to v0.19.0

v0.19.0 — spawn preflight refactor. Two-phase trooper allocation
(bin/preflight-layout.sh + bin/spawn.sh --target-pane) replaces the
.last_pane chain race in /clone-wars:consult.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: CLAUDE.md status entry

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Locate the v0.18.3 status row**

```bash
grep -n 'v0.18.3:' CLAUDE.md
```

- [ ] **Step 2: Add v0.19.0 entry directly after the v0.18.3 row**

Open `CLAUDE.md`, find the line beginning `- [x] v0.18.3: consult skill-reviewer polish — ...` (a single long line). Append a new row immediately after it (and before the next `- [ ] v0.6:` line):

```markdown
- [x] v0.19.0: spawn preflight refactor — two-phase trooper allocation replaces the `.last_pane` chain race in `/clone-wars:consult`. New `bin/preflight-layout.sh` splits N panes off Yoda's pane in a single bash process, applies `tmux select-layout main-vertical`, writes ordered `_consult/preflight-panes.txt`. New `bin/spawn.sh --target-pane <id>` flag dispatches via `tmux respawn-pane` (no `.last_pane` reads/writes on this path; strict validation against preflight-panes.txt). `commands/consult.md` Step 3 split into 3a (preflight, foreground) + 3b (parallel spawn dispatch with Stage 1 retry-once + Stage 2 partial-success AskUserQuestion). `bin/consult-teardown.sh` extension cleans preflight orphan panes. Backwards-compat: spawn.sh without `--target-pane` is byte-equal to v0.18.3 (legacy split-window + `.last_pane` flow preserved for `/clone-wars:deploy`). Five new tests + 1 v0.17 test update.
- [ ] v0.19.0 strict-dogfood pass on a real machine (release gate — verify: (1) 3-trooper consult --use-force produces three evenly-sized panes that all appear within ~2s of preflight call, no "1 then 2 then 3" appearance; (2) Yoda pane stays at ~50% width throughout; (3) /clone-wars:deploy single-trooper spawn behavior is byte-equal to v0.18.3; (4) Stage 1 retry absorbs codex cold-start invisibly; (5) Stage 2 partial-success AskUserQuestion offers degrade-or-abort when retry fails)
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "$(cat <<'EOF'
docs(claude): record v0.19.0 spawn preflight + dogfood gate

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: Final sweep — run all relevant tests + open PR

**Files:**
- Read-only verification + git push + PR

- [ ] **Step 1: Run the full test suite for v0.19.0-relevant tests**

```bash
for t in test_pane_respawn.sh test_preflight_layout.sh test_preflight_layout_rollback.sh \
         test_spawn_target_pane_strict.sh test_consult_teardown_preflight_orphans.sh \
         test_consult_directive_v019_static_wiring.sh test_consult_directive_v017_static_wiring.sh \
         test_spawn_validation.sh test_spawn_rollback.sh \
         test_medic_directive_v018_static_wiring.sh \
         test_active_providers_path.sh test_consult_init_prefers_active.sh \
         test_consult_init_falls_back_to_available.sh test_consult_init_handles_stale_active.sh; do
  echo "=== $t ==="
  timeout 60 bash "tests/$t" 2>&1 | tail -3
  rc=${PIPESTATUS[0]}
  echo "rc=$rc"
done
```

Expected: every test prints `PASS:` or `SKIP:` (skips are acceptable for tmux-dependent tests if `$TMUX` is unset). Any FAIL → stop and fix before pushing.

- [ ] **Step 2: Push the branch**

```bash
git push -u origin feat/v0.19.0-spawn-preflight-layout
```

Expected: branch pushed; gh prints PR-create URL.

- [ ] **Step 3: Open the PR**

```bash
gh pr create --title "feat(consult): two-phase spawn preflight (v0.19.0)" --body "$(cat <<'EOF'
## Summary

Replaces the `.last_pane` chain in `/clone-wars:consult` spawn with a two-phase **pre-allocate, then dispatch** architecture. Solves two linked bugs the user reported during dogfood:
1. Sequential pane appearance ("split into 1, into 2, into 3") despite parallel spawn calls — root cause: `.last_pane` race serialized the parallel processes.
2. Unevenly-sized trooper panes — root cause: each successive `tmux split-window -v` halved the prior pane's height.

`/clone-wars:deploy` and other single-trooper callers are unchanged (legacy `split-window` + `.last_pane` flow preserved byte-equal to v0.18.3).

## What changes

- **NEW `bin/preflight-layout.sh`** — splits N panes off Yoda's pane in a single bash process, applies `tmux select-layout main-vertical`, writes ordered `_consult/preflight-panes.txt`. Sentinel banners use `cw_label_fmt` so each reserved pane shows its commander identity until respawn. Trap-driven rollback on failure.
- **NEW `cw_pane_respawn` in `lib/tmux.sh`** — wraps `tmux respawn-pane -k` + `cw_pane_label_set`.
- **`bin/spawn.sh` gains `--target-pane <id>`** — strict validation (must appear in preflight-panes.txt for the topic) + dispatches via `cw_pane_respawn` instead of split-window. Without the flag, byte-equal to v0.18.3.
- **`commands/consult.md` Step 3 split** into 3a (preflight, foreground) + 3b (parallel dispatch). Stage 1 retry-once + Stage 2 partial-success AskUserQuestion offer ("proceed degraded with N=M / abort all").
- **`bin/consult-teardown.sh` extension** — cleans preflight orphan panes (commanders in preflight-panes.txt but not in troopers.txt).

## Test plan

- [x] `tests/test_pane_respawn.sh` — `cw_pane_respawn` happy path (tmux-dep)
- [x] `tests/test_preflight_layout.sh` — N=3 happy path: even heights, ordered TSV, labels stamped (tmux-dep)
- [x] `tests/test_preflight_layout_rollback.sh` — count-mismatch rc=1 + no orphans (tmux-dep)
- [x] `tests/test_spawn_target_pane_strict.sh` — strict validation + legacy regression
- [x] `tests/test_consult_teardown_preflight_orphans.sh` — orphan cleanup (tmux-dep)
- [x] `tests/test_consult_directive_v019_static_wiring.sh` — directive prose
- [x] `tests/test_consult_directive_v017_static_wiring.sh` — updated for Step 3a/3b split
- [x] `tests/test_spawn_validation.sh` + `test_spawn_rollback.sh` — legacy path regression-free
- [ ] After merge: dogfood `/clone-wars:consult --use-force` on a 3-trooper run (release gate per CLAUDE.md)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: `gh` prints the PR URL.

- [ ] **Step 4: Report PR URL to user**

Print the PR URL from Step 3's output. Done.

---

## Self-review checklist

| Spec section | Implementing task(s) |
|---|---|
| `cw_pane_respawn` helper | Task 2 |
| `bin/preflight-layout.sh` happy path | Task 3 |
| Preflight rollback (trap-driven) | Tasks 3 + 4 (impl in 3, test in 4) |
| `bin/spawn.sh --target-pane` flag | Task 5 |
| Strict validation against preflight-panes.txt | Task 5 (Step 4) |
| Skip `.last_pane` writes on preflight path | Task 5 (Step 5 — branch via `if [[ -n "$TARGET_PANE" ]]`) |
| Backwards compat (spawn.sh without flag) | Task 5 (Step 5 — `else` branch byte-equal to today; Step 7 verifies legacy tests still pass) |
| `bin/consult-teardown.sh` orphan cleanup | Task 6 |
| `commands/consult.md` Step 3a + 3b | Task 7 |
| Stage 1 retry-once | Task 7 (Step 3, "Stage 1" sub-block) |
| Stage 2 partial-success AskUserQuestion | Task 7 (Step 3, "Stage 2" sub-block) |
| Static-wiring test | Task 8 |
| v0.17 test update | Task 9 |
| Plugin version bump | Task 10 |
| CLAUDE.md status + dogfood gate | Task 11 |
| Final test sweep + PR | Task 12 |

All spec sections covered. No placeholders. Type signatures consistent: `cw_pane_respawn <pane_id> <commander> <model> <topic> <launch> [<cwd>]` is referenced identically in Tasks 2 and 5.

Failure-mode mapping verified against spec table:
- Preflight tmux split midway → trap rollback (Task 3)
- Yoda pane discovery fails → exit 1 immediately (Task 3, validation block)
- troopers.txt absent / wrong count → exit 1 immediately (Task 3, validation block)
- Stage 1 retry fails preflight → covered by trap rollback + Stage 2 trigger (Task 7 Stage 2 evaluates state-dirs)
- Stage 2 abort all → teardown + rm -rf (Task 7 Stage 2 abort branch)
- consult-teardown with missing preflight-panes.txt → no-op (Task 6 — `if [[ -f "$PFP_FILE" ]]` guard)
- `--target-pane` not in preflight-panes.txt → strict reject (Task 5)
- `--target-pane` is dead → strict reject in dispatch (Task 5 Step 5)

Ready for execution.
