# Clone Wars Hardening — Phase 2 (`v0.0.5`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land Phase 2 fixes from the hardening spec — JSON-strict event matching, short-circuit on terminal events, atomic inbox writes, contract-driven bootstrap sleep, and DRY teardown — and tag `v0.0.5`.

**Architecture:** All changes are confined to `lib/ipc.sh`, `lib/contracts.sh`, `bin/spawn.sh`, `bin/collect.sh`, `bin/list.sh`, `bin/teardown.sh`, and `config/contracts.yaml`. No new dependencies. Each fix is testable at the lib-function or bin-script level via the existing pure-bash test harness.

**Tech Stack:** bash 4.2+, tmux ≥ 3.0, pure-shell test harness (`tests/run.sh` discovers every `tests/test_*.sh`). Uses `lib/log.sh` for stderr output.

---

## Spec reference

`/home/liupan/CC/clone-wars/docs/superpowers/specs/2026-04-26-clone-wars-hardening-design.md` § Phase 2.

**Note on #9 (archive timestamp collisions):** the spec lists this as a Phase 2 item, but it was already implemented in Phase 1 Task 1 as part of `cw_state_archive`'s collision-resolution loop (commit `dfe82a7`). Phase 2 therefore covers 5 fixes (#6, #7, #8, #10, #11), not 6.

## File structure (Phase 2 changes)

| File | Status | Responsibility |
|---|---|---|
| `lib/ipc.sh` | modify | Add `cw_event_match_pattern <event>`; rewrite `cw_outbox_wait` to accept multiple events + use strict pattern; rewrite `cw_inbox_write` for atomic tmp+rename |
| `lib/contracts.sh` | modify | Add `cw_contract_bootstrap_sleep <provider>` reader (default 8) |
| `config/contracts.yaml` | modify | Add `bootstrap_sleep_s:` field per provider |
| `bin/spawn.sh` | modify | Replace hardcoded BOOT_SLEEP case with `cw_contract_bootstrap_sleep` call; pass `"ready error"` to `cw_outbox_wait`; branch on which event arrived |
| `bin/collect.sh` | modify | Use strict regex (`^\{"event":"<name>"[,}]`) instead of substring grep |
| `bin/list.sh` | modify | Use strict regex when extracting last_event |
| `bin/teardown.sh` | modify | Extract `_teardown_batch <topic> <c1>:<m1> ...` helper; collapse `teardown_topic` and the 2-arg branch onto it; remove now-unused `teardown_trooper` helper |
| `tests/test_event_match.sh` | **NEW** | Cover strict matcher: false-positive payload (progress note containing `"event":"done"`) + real done line; matcher picks the real one |
| `tests/test_outbox_wait.sh` | **NEW** | Cover short-circuit: pre-write error to outbox, assert `cw_outbox_wait ... "ready error"` returns error within 1s (not after timeout) |
| `tests/test_inbox_atomic.sh` | **NEW** | Static-grep regression guard: `cw_inbox_write` uses `inbox.md.tmp` + `mv -f` pattern (true atomicity is unobservable from a shell test) |
| `tests/test_contracts.sh` | modify | Extend with `bootstrap_sleep_s` cases (provider with field returns it; provider without returns default 8) |
| `.claude-plugin/plugin.json` | modify | Bump to `0.0.5` |
| `.claude-plugin/marketplace.json` | modify | Bump to `0.0.5` |

---

## Setup (before Task 1)

- [ ] **Step 0.1: Create the implementation branch**

```bash
cd /home/liupan/CC/clone-wars
git checkout main
git pull origin main
git checkout -b chore/v0.0.5-hardening-phase-2
```

The hook policy blocks direct commits to `main`; everything goes through this branch + a PR.

---

## Task 1 — `lib/ipc.sh` + `bin/collect.sh` + `bin/list.sh`: JSON-strict event matching (#7)

**Why first:** Task 2 (#6 short-circuit) consumes the new `cw_event_match_pattern` helper, so this lands first. Pure-bash, fully testable.

**Files:**
- Modify: `/home/liupan/CC/clone-wars/lib/ipc.sh` (add new helper around line 110, just before `cw_outbox_wait`)
- Modify: `/home/liupan/CC/clone-wars/bin/collect.sh:62-74` (substring grep → strict regex)
- Modify: `/home/liupan/CC/clone-wars/bin/list.sh:60` (substring grep → strict regex)
- Test: `/home/liupan/CC/clone-wars/tests/test_event_match.sh` (new)

- [ ] **Step 1.1: Write the failing test**

Create `tests/test_event_match.sh`:

```bash
#!/usr/bin/env bash
# tests/test_event_match.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/state.sh
source ../lib/ipc.sh

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 1. cw_event_match_pattern returns an anchored regex.
PAT=$(cw_event_match_pattern done)
assert_eq "$PAT" '^\{"event":"done"[,}]' "pattern shape"
pass "cw_event_match_pattern produces anchored regex"

# 2. Strict pattern correctly identifies a true {done} event.
OUTBOX="$TMP/outbox.jsonl"
echo '{"event":"done","summary":"ok","ts":"2026-04-27T00:00:00Z"}' > "$OUTBOX"
grep -qE "$(cw_event_match_pattern done)" "$OUTBOX" || { echo "FAIL: strict matcher missed a real done line" >&2; exit 1; }
pass "strict matcher hits real done"

# 3. Strict pattern does NOT match a progress event whose note contains the
#    literal text "event":"done" — exactly the false-positive class #7 closes.
cat > "$OUTBOX" <<'EOF'
{"event":"progress","note":"the trooper said \"event\":\"done\" but this is just a status note","ts":"2026-04-27T00:01:00Z"}
EOF
if grep -qE "$(cw_event_match_pattern done)" "$OUTBOX"; then
  echo "FAIL: strict matcher false-positives on a progress event with embedded text" >&2
  exit 1
fi
pass "strict matcher rejects progress note with embedded text"

# 4. Strict matcher picks the REAL done line out of an outbox that contains
#    both the noisy progress event AND a genuine done event afterward.
cat > "$OUTBOX" <<'EOF'
{"event":"ack","task_summary":"work","ts":"2026-04-27T00:00:00Z"}
{"event":"progress","note":"contains the literal substring \"event\":\"done\" inside","ts":"2026-04-27T00:00:30Z"}
{"event":"done","summary":"actually finished","ts":"2026-04-27T00:01:00Z"}
EOF
HIT=$(grep -E "$(cw_event_match_pattern done)" "$OUTBOX" | tail -n1)
assert_contains "$HIT" '"summary":"actually finished"' "matched the real done line"
pass "strict matcher selects real done from mixed outbox"

# 5. Empty event-name rejected (defensive — a caller passing "" would otherwise
#    construct a regex matching ANY event line).
PAT_EMPTY=$(cw_event_match_pattern '' 2>&1) && { echo "FAIL: empty event accepted" >&2; exit 1; }
pass "empty event rejected"

echo "  ALL: ok"
```

- [ ] **Step 1.2: Run the test to verify it fails**

```bash
cd /home/liupan/CC/clone-wars && bash tests/test_event_match.sh
```

Expected: FAIL on test 1 — `cw_event_match_pattern` doesn't exist yet.

- [ ] **Step 1.3: Add `cw_event_match_pattern` to `lib/ipc.sh`**

Find `cw_outbox_wait` in `lib/ipc.sh` (currently around line 111). Insert the new helper IMMEDIATELY BEFORE the `cw_outbox_wait` function definition. The full insertion is:

```bash
# cw_event_match_pattern <event_name>
# Print a `grep -E` pattern that matches a single JSONL line whose `event`
# field is EXACTLY <event_name>. Anchors at the start (^) and requires the
# next character after the event name to be `,` (more fields follow) or `}`
# (event has no payload). Closes the false-positive class where a substring
# grep would match `"event":"done"` literal text inside another event's note.
cw_event_match_pattern() {
  local event="$1"
  [[ -n "$event" ]] || { echo "cw_event_match_pattern: empty event" >&2; return 1; }
  printf '^\\{"event":"%s"[,}]' "$event"
}
```

- [ ] **Step 1.4: Run the test to verify it passes**

```bash
cd /home/liupan/CC/clone-wars && bash tests/test_event_match.sh
```

Expected: All 5 `PASS:` lines, then `ALL: ok`.

- [ ] **Step 1.5: Update `bin/collect.sh` to use the strict pattern**

Find the polling block in `bin/collect.sh` (currently around lines 60-74):

```bash
for ((i = 0; i < TIMEOUT; i++)); do
  if grep -q '"event":"done"' "$OUTBOX" 2>/dev/null; then
    EVENT=$(grep '"event":"done"' "$OUTBOX" | tail -n1)
    log_ok "{done} received"
    echo "$EVENT"
    exit 0
  fi
  if grep -q '"event":"error"' "$OUTBOX" 2>/dev/null; then
    EVENT=$(grep '"event":"error"' "$OUTBOX" | tail -n1)
    log_error "{error} received from $COMMANDER"
    echo "$EVENT"
    exit 1
  fi
  sleep 1
done
```

Replace with:

```bash
DONE_PAT=$(cw_event_match_pattern done)
ERROR_PAT=$(cw_event_match_pattern error)
for ((i = 0; i < TIMEOUT; i++)); do
  if grep -qE "$DONE_PAT" "$OUTBOX" 2>/dev/null; then
    EVENT=$(grep -E "$DONE_PAT" "$OUTBOX" | tail -n1)
    log_ok "{done} received"
    echo "$EVENT"
    exit 0
  fi
  if grep -qE "$ERROR_PAT" "$OUTBOX" 2>/dev/null; then
    EVENT=$(grep -E "$ERROR_PAT" "$OUTBOX" | tail -n1)
    log_error "{error} received from $COMMANDER"
    echo "$EVENT"
    exit 1
  fi
  sleep 1
done
```

The `lib/ipc.sh` source is already in the bin script (added in Phase 1), so `cw_event_match_pattern` is in scope. No new source line needed.

- [ ] **Step 1.6: Update `bin/list.sh` to use the strict pattern**

Find the per-trooper inner loop body in `bin/list.sh`. The current line that extracts the last event is around line 60:

```bash
        last_event=$(tail -n1 "$outbox" | grep -oE '"event":"[^"]+"' | head -n1 | cut -d'"' -f4)
```

Replace with:

```bash
        # Use strict event-name extraction: anchor at start of line so a
        # progress note with embedded "event":"X" text can't shadow the real one.
        last_event=$(tail -n1 "$outbox" | grep -oE '^\{"event":"[^"]+"' | head -n1 | sed -e 's/^{"event":"//' -e 's/"$//')
```

Note: list.sh already operates on the LAST line of the outbox (`tail -n1`), so the strict-vs-substring distinction matters less here than in collect.sh — but anchoring eliminates the false-positive surface symmetrically.

- [ ] **Step 1.7: Lint-pass**

```bash
cd /home/liupan/CC/clone-wars
for f in bin/collect.sh bin/list.sh; do
  bash -n "$f" && echo "$f: syntax OK" || { echo "$f: SYNTAX ERROR"; exit 1; }
done
```

Expected: both `syntax OK`.

- [ ] **Step 1.8: Run the full test suite**

```bash
cd /home/liupan/CC/clone-wars && bash tests/run.sh
```

Expected: every test passes including `test_event_match.sh`. Total should be 11 test files now (10 from Phase 1 + this new one).

- [ ] **Step 1.9: Commit**

```bash
cd /home/liupan/CC/clone-wars
git add lib/ipc.sh bin/collect.sh bin/list.sh tests/test_event_match.sh
git commit -m "$(cat <<'EOF'
feat(ipc): JSON-strict event matching (#7)

Adds cw_event_match_pattern <event> in lib/ipc.sh — produces an
anchored regex (^\{"event":"<name>"[,}]) that matches a JSONL line
whose event field is exactly <name>. Closes the false-positive class
where a substring grep on '"event":"done"' would also match a
progress event whose note field happened to contain those bytes.

bin/collect.sh and bin/list.sh switched to the strict pattern.
bin/spawn.sh's outbox-wait will switch in the next commit (Task 2)
when it grows multi-event awareness.
EOF
)"
```

---

## Task 2 — `lib/ipc.sh` + `bin/spawn.sh`: `cw_outbox_wait` short-circuits on terminal events (#6)

**Why second:** Builds on Task 1's `cw_event_match_pattern` helper.

**Files:**
- Modify: `/home/liupan/CC/clone-wars/lib/ipc.sh` (rewrite `cw_outbox_wait` signature + body)
- Modify: `/home/liupan/CC/clone-wars/bin/spawn.sh` (consume the new signature; branch on which event arrived)
- Test: `/home/liupan/CC/clone-wars/tests/test_outbox_wait.sh` (new)

**Codex review note.** The locked spec's example test calls `cw_outbox_wait commander model topic ready error 30` — varargs, NOT a quoted list. The plan was originally written with a quoted-list shape, then revised to match the spec: events are positional args between `<topic>` and the final `<timeout>`. Single-event callers (`cw_outbox_wait c m t ready 30`) continue to work because the function unpacks "all-but-last as events, last as timeout."

- [ ] **Step 2.1: Write the failing test**

Create `tests/test_outbox_wait.sh`:

```bash
#!/usr/bin/env bash
# tests/test_outbox_wait.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/state.sh
source ../lib/ipc.sh

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

DIR=$(cw_trooper_dir rex codex demo)
mkdir -p "$DIR"

# 1. Single-event API still works (backward compat with Phase 1's call sites).
#    Signature: cw_outbox_wait <commander> <model> <topic> <event> <timeout>
:> "$DIR/outbox.jsonl"
echo '{"event":"ready","ts":"2026-04-27T00:00:00Z"}' >> "$DIR/outbox.jsonl"
LINE=$(cw_outbox_wait rex codex demo ready 2)
assert_contains "$LINE" '"event":"ready"' "single-event call returns the line"
pass "single-event API preserved"

# 2. Multi-event varargs call: events are positional args between topic and
#    timeout (the locked spec shape). ready already in outbox → returned.
LINE=$(cw_outbox_wait rex codex demo ready error 2)
assert_contains "$LINE" '"event":"ready"' "multi-event varargs hits ready"
pass "multi-event varargs API hits ready"

# 3. Short-circuit: ONLY error in the outbox; multi-event call returns the
#    error line WITHIN the timeout window (not after exhausting it).
:> "$DIR/outbox.jsonl"
echo '{"event":"error","message":"bootstrap failed","fatal":true,"ts":"2026-04-27T00:00:00Z"}' >> "$DIR/outbox.jsonl"
START=$(date +%s)
LINE=$(cw_outbox_wait rex codex demo ready error 30)
END=$(date +%s)
ELAPSED=$((END - START))
assert_contains "$LINE" '"event":"error"' "short-circuit returns error line"
[[ "$ELAPSED" -lt 5 ]] || { echo "FAIL: short-circuit took ${ELAPSED}s — should be <5s, got full timeout" >&2; exit 1; }
pass "short-circuit on error within ${ELAPSED}s (timeout was 30s)"

# 4. Timeout case: empty outbox + 2s timeout → returns 1 with no output.
:> "$DIR/outbox.jsonl"
LINE=$(cw_outbox_wait rex codex demo ready error 2 2>/dev/null) && CODE=0 || CODE=$?
assert_eq "$CODE" "1" "timeout returns rc=1"
[[ -z "$LINE" ]] || { echo "FAIL: timeout produced output: '$LINE'" >&2; exit 1; }
pass "timeout returns rc=1 with no output"

# 5. False-positive immunity: outbox has a progress note containing the
#    literal text "event":"ready" — multi-event call should NOT short-circuit
#    on that, and DOES return when a real ready arrives.
cat > "$DIR/outbox.jsonl" <<'EOF'
{"event":"progress","note":"trooper said \"event\":\"ready\" in chat — but the protocol event hasn't fired","ts":"2026-04-27T00:00:00Z"}
{"event":"ready","ts":"2026-04-27T00:00:01Z"}
EOF
LINE=$(cw_outbox_wait rex codex demo ready error 2)
assert_contains "$LINE" '"ts":"2026-04-27T00:00:01Z"' "matched the real ready line, not the noisy progress note"
pass "false-positive immunity"

# 6. Three-event varargs (forward-compat for any future "done|error|ack" calls).
:> "$DIR/outbox.jsonl"
echo '{"event":"ack","task_summary":"ok","ts":"2026-04-27T00:00:00Z"}' >> "$DIR/outbox.jsonl"
LINE=$(cw_outbox_wait rex codex demo ready error ack 2)
assert_contains "$LINE" '"event":"ack"' "three-event varargs hits ack"
pass "three-event varargs"

echo "  ALL: ok"
```

- [ ] **Step 2.2: Run the test to verify it fails**

```bash
cd /home/liupan/CC/clone-wars && bash tests/test_outbox_wait.sh
```

Expected: FAIL on test 2 — current `cw_outbox_wait` treats its 4th arg as a single event name and its 5th arg as timeout; passing `ready error 2` makes `events=ready` and `timeout=error`, which crashes the arithmetic `for ((i = 0; i < timeout; i++))`.

- [ ] **Step 2.3: Rewrite `cw_outbox_wait` in `lib/ipc.sh` (varargs)**

Find the current `cw_outbox_wait` function (currently around lines 111-126):

```bash
# cw_outbox_wait <commander> <model> <topic> <event> <timeout-seconds>
# Poll the outbox for the named event. Print the matching JSON line to stdout
# if found within timeout (return 0). Print nothing and return 1 on timeout.
cw_outbox_wait() {
  local commander="$1" model="$2" topic="$3" event="$4" timeout="$5"
  local outbox; outbox=$(cw_outbox_path "$commander" "$model" "$topic")
  local i
  for i in $(seq 1 "$timeout"); do
    if grep -q "\"event\":\"$event\"" "$outbox" 2>/dev/null; then
      grep "\"event\":\"$event\"" "$outbox" | tail -n1
      return 0
    fi
    sleep 1
  done
  return 1
}
```

Replace with:

```bash
# cw_outbox_wait <commander> <model> <topic> <event1> [<event2> ...] <timeout>
# Poll the outbox for ANY of the named events. Events are positional args
# between <topic> and the FINAL <timeout> arg. Print the matching JSON line
# on stdout and return 0 as soon as any listed event appears. Return 1 with
# no output if the timeout expires.
#
# Single-event call (backward compat with Phase 1):
#   cw_outbox_wait c m t ready 30
# Multi-event call (Phase 2's short-circuit on error during bootstrap):
#   cw_outbox_wait c m t ready error 30
#
# Uses cw_event_match_pattern for strict (anchored, ^\{"event":"X"[,}])
# matching so a progress note containing a quoted event name doesn't
# false-positive.
cw_outbox_wait() {
  local commander="$1" model="$2" topic="$3"
  shift 3
  # Last positional is timeout; everything between <topic> and it is events.
  (( $# >= 2 )) || { echo "cw_outbox_wait: need at least one event and a timeout" >&2; return 2; }
  local timeout="${!#}"   # ${!#} = last positional
  set -- "${@:1:$#-1}"    # drop the last positional → only events remain
  local events=("$@")
  [[ "$timeout" =~ ^[0-9]+$ ]] || { echo "cw_outbox_wait: timeout must be a non-negative integer; got '$timeout'" >&2; return 2; }
  local outbox; outbox=$(cw_outbox_path "$commander" "$model" "$topic")
  local i event pat
  for ((i = 0; i < timeout; i++)); do
    for event in "${events[@]}"; do
      pat=$(cw_event_match_pattern "$event")
      if grep -qE "$pat" "$outbox" 2>/dev/null; then
        grep -E "$pat" "$outbox" | tail -n1
        return 0
      fi
    done
    sleep 1
  done
  return 1
}
```

The 5-arg single-event call (`c m t ready 30`) still works because `${!#}` picks the last positional (`30`) and the slice `${@:1:$#-1}` leaves `ready` as the only event. The 6-arg multi-event call (`c m t ready error 30`) puts `(ready error)` in `events[]` and `30` in `timeout`. Validates that `timeout` is numeric to fail fast on legacy callers that accidentally pass a quoted-list shape (e.g. `"ready error"` would arrive as a single event token, then the next arg would be the timeout — which works, but doesn't break either).

- [ ] **Step 2.4: Run the test to verify it passes**

```bash
cd /home/liupan/CC/clone-wars && bash tests/test_outbox_wait.sh
```

Expected: All 5 `PASS:` lines, then `ALL: ok`.

- [ ] **Step 2.5: Update `bin/spawn.sh` to short-circuit on error**

Find the ready-wait block in `bin/spawn.sh` (currently around lines 168-178 after Phase 1's edits):

```bash
log_info "waiting for {ready} in outbox (timeout ${READY_TIMEOUT}s)"
if ! cw_outbox_wait "$COMMANDER" "$MODEL" "$TOPIC" ready "$READY_TIMEOUT" >/dev/null; then
  log_error "$COMMANDER timed out on {ready}"
  log_error "outbox:"; cw_outbox_dump "$COMMANDER" "$MODEL" "$TOPIC" >&2
  log_error "pane content (last 25 lines, captured BEFORE kill):"
  tmux capture-pane -p -t "$PANE" 2>/dev/null | tail -n 25 >&2 || true
  cw_pane_kill_now "$PANE"
  failed_archive=$(cw_state_archive "$COMMANDER" "$MODEL" "$TOPIC" FAILED)
  log_error "state archived to: $failed_archive"
  exit 1
fi
log_ok "$COMMANDER is ready"
```

Replace with:

```bash
log_info "waiting for {ready,error} in outbox (timeout ${READY_TIMEOUT}s)"
event_line=$(cw_outbox_wait "$COMMANDER" "$MODEL" "$TOPIC" ready error "$READY_TIMEOUT") || event_line=""
if [[ -z "$event_line" ]]; then
  log_error "$COMMANDER timed out on {ready,error}"
  log_error "outbox:"; cw_outbox_dump "$COMMANDER" "$MODEL" "$TOPIC" >&2
  log_error "pane content (last 25 lines, captured BEFORE kill):"
  tmux capture-pane -p -t "$PANE" 2>/dev/null | tail -n 25 >&2 || true
  cw_pane_kill_now "$PANE"
  failed_archive=$(cw_state_archive "$COMMANDER" "$MODEL" "$TOPIC" FAILED)
  log_error "state archived to: $failed_archive"
  exit 1
fi
if [[ "$event_line" == *'"event":"error"'* ]]; then
  log_error "$COMMANDER reported {error} during bootstrap: $event_line"
  log_error "pane content (last 25 lines, captured BEFORE kill):"
  tmux capture-pane -p -t "$PANE" 2>/dev/null | tail -n 25 >&2 || true
  cw_pane_kill_now "$PANE"
  failed_archive=$(cw_state_archive "$COMMANDER" "$MODEL" "$TOPIC" FAILED)
  log_error "state archived to: $failed_archive"
  exit 1
fi
log_ok "$COMMANDER is ready"
```

The two FAIL paths (timeout vs explicit error) share most logic but diverge in their leading log line so the user can distinguish "trooper hung" from "trooper said no". Both still archive with `FAILED` suffix and exit 1, preserving Task 2 of Phase 1's contract.

- [ ] **Step 2.6: Lint-pass**

```bash
cd /home/liupan/CC/clone-wars && bash -n bin/spawn.sh && echo "syntax OK"
```

Expected: `syntax OK`.

- [ ] **Step 2.7: Run the full test suite**

```bash
cd /home/liupan/CC/clone-wars && bash tests/run.sh
```

Expected: every test passes including `test_outbox_wait.sh`. The Phase 1 test `test_spawn_validation.sh` exercises spawn outside tmux — the changed wait block is unreached there, so no regression risk.

- [ ] **Step 2.8: Commit**

```bash
cd /home/liupan/CC/clone-wars
git add lib/ipc.sh bin/spawn.sh tests/test_outbox_wait.sh
git commit -m "$(cat <<'EOF'
feat(ipc): cw_outbox_wait accepts event list + short-circuits on error (#6)

Today's spawn waits the full READY_TIMEOUT (30s codex / 60s claude)
even when the trooper has already emitted {error} during bootstrap.
This wastes a minute on every fast-fail.

cw_outbox_wait now accepts a space-separated event list in its 4th
arg (backward-compatible: a single event name still works since
'for event in single-name' iterates once). Returns the first matching
line; bin/spawn.sh consumes the line and branches on whether ready
or error arrived.

Both FAIL paths (timeout, explicit-error) archive state with the
FAILED suffix from Phase 1 and exit 1; the leading log line
distinguishes the two so the user knows whether the trooper hung
or actively reported failure.
EOF
)"
```

---

## Task 3 — `lib/ipc.sh`: atomic inbox write (#8)

**Files:**
- Modify: `/home/liupan/CC/clone-wars/lib/ipc.sh:95-110` (`cw_inbox_write`)
- Test: `/home/liupan/CC/clone-wars/tests/test_inbox_atomic.sh` (new)

**Codex review note.** Original plan used a deterministic `${inbox}.tmp` path. That protects READERS (rename-into-place is atomic) but NOT writers: two concurrent `send` calls truncate the same `${inbox}.tmp`, scramble each other's content, and one of the renames clobbers the other. The locked spec named "two sends in quick succession" as the explicit failure mode — so we use `mktemp "${inbox}.tmp.XXXXXX"` per invocation (each writer gets its own staging file) plus a trap that cleans up the tmp file on any abnormal exit. Test now includes a real concurrent-writer regression test, not just a static grep.

- [ ] **Step 3.1: Write the failing test**

Create `tests/test_inbox_atomic.sh`:

```bash
#!/usr/bin/env bash
# tests/test_inbox_atomic.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/state.sh
source ../lib/ipc.sh

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"
mkdir -p "$(cw_trooper_dir rex codex demo)"

# 1. cw_inbox_write produces a complete inbox.md ending with END_OF_INSTRUCTION.
cw_inbox_write rex codex demo "test task body"
INBOX=$(cw_inbox_path rex codex demo)
assert_file_exists "$INBOX" "inbox.md created"
tail -n1 "$INBOX" | grep -q '^END_OF_INSTRUCTION$' || {
  echo "FAIL: inbox.md doesn't end with END_OF_INSTRUCTION sentinel" >&2; exit 1; }
pass "inbox.md ends with sentinel"

# 2. After the write, no .tmp* files are left in the trooper dir.
DIR=$(cw_trooper_dir rex codex demo)
shopt -s nullglob
LEAKS=("$DIR"/inbox.md.tmp*)
(( ${#LEAKS[@]} == 0 )) || { echo "FAIL: tmp leaks: ${LEAKS[*]}" >&2; exit 1; }
shopt -u nullglob
pass "no tmp file leaks after single write"

# 3. Static wiring check: cw_inbox_write uses mktemp on a tmp under inbox dir
#    AND mv -f into the final inbox path. Without per-call tmp the concurrent
#    test below would fail intermittently — the static check is a quick
#    regression guard against accidental reverts to a deterministic tmp path.
grep -qE 'mktemp[[:space:]].*"\$\{?inbox\}?\.tmp\.XXXXXX"' ../lib/ipc.sh \
  || { echo "FAIL: cw_inbox_write doesn't use mktemp \"\${inbox}.tmp.XXXXXX\"" >&2; exit 1; }
grep -qE 'mv[[:space:]]-f[[:space:]]"\$tmp"[[:space:]]"\$inbox"' ../lib/ipc.sh \
  || { echo "FAIL: cw_inbox_write doesn't mv -f \"\$tmp\" \"\$inbox\"" >&2; exit 1; }
pass "atomic-write wired (mktemp per call + mv -f)"

# 4. Sequential overwrites land cleanly (no race, just regression check).
cw_inbox_write rex codex demo "first task"
cw_inbox_write rex codex demo "second task"
shopt -s nullglob
LEAKS2=("$DIR"/inbox.md.tmp*)
(( ${#LEAKS2[@]} == 0 )) || { echo "FAIL: tmp leaks after sequential writes: ${LEAKS2[*]}" >&2; exit 1; }
shopt -u nullglob
head -n1 "$INBOX" | grep -q 'second task' || {
  echo "FAIL: second write didn't replace inbox content" >&2; exit 1; }
pass "sequential overwrites land cleanly"

# 5. CONCURRENT-WRITER regression test (the failure mode #8 actually closes).
#    Spawn N writers in parallel; each writes a uniquely-tagged task body.
#    Afterwards: inbox.md must be exactly one of the N versions (atomic
#    final state); NO inbox.md.tmp* file may linger; the visible content
#    must end with END_OF_INSTRUCTION on its own line (no truncation).
N=20
PIDS=()
for ((i = 0; i < N; i++)); do
  ( cw_inbox_write rex codex demo "writer-$i: this is a concurrent test message body" ) &
  PIDS+=("$!")
done
for p in "${PIDS[@]}"; do wait "$p"; done
# (a) No tmp leaks after all writers exit.
shopt -s nullglob
LEAKS3=("$DIR"/inbox.md.tmp*)
(( ${#LEAKS3[@]} == 0 )) || { echo "FAIL: concurrent tmp leaks: ${LEAKS3[*]}" >&2; exit 1; }
shopt -u nullglob
pass "no tmp leaks after $N concurrent writers"
# (b) Final inbox.md ends with END_OF_INSTRUCTION (not truncated).
tail -n1 "$INBOX" | grep -q '^END_OF_INSTRUCTION$' || {
  echo "FAIL: concurrent-write final state truncated; tail was:" >&2
  tail -n3 "$INBOX" >&2
  exit 1; }
pass "final inbox.md ends with sentinel after $N concurrent writers"
# (c) Final content is one of the N writers' messages exactly (no interleaving).
HEAD_LINE=$(head -n1 "$INBOX")
[[ "$HEAD_LINE" =~ ^writer-[0-9]+: ]] || {
  echo "FAIL: concurrent-write head looks interleaved/corrupted: '$HEAD_LINE'" >&2; exit 1; }
pass "final content is one writer's message verbatim (no interleaving)"

echo "  ALL: ok"
```

- [ ] **Step 3.2: Run the test to verify it fails**

```bash
cd /home/liupan/CC/clone-wars && bash tests/test_inbox_atomic.sh
```

Expected: FAIL on test 3 — current `cw_inbox_write` cats directly to `$inbox`, no `mktemp`. Test 5 may also fail intermittently with the v0.0.3 implementation (concurrent truncates).

- [ ] **Step 3.3: Rewrite `cw_inbox_write` for atomic, concurrent-safe writes**

Find `cw_inbox_write` in `lib/ipc.sh` (currently around lines 92-110):

```bash
# cw_inbox_write <commander> <model> <topic> <task_text>
# Overwrite inbox.md with the task, terminating with the END_OF_INSTRUCTION
# sentinel so the trooper knows the message is complete.
cw_inbox_write() {
  local commander="$1" model="$2" topic="$3" task="$4"
  local inbox outbox
  inbox=$(cw_inbox_path "$commander" "$model" "$topic")
  outbox=$(cw_outbox_path "$commander" "$model" "$topic")
  cat > "$inbox" <<EOF
$task

When done, append a single JSONL line to $outbox:

\`{"event":"done","summary":"<one-line summary>","ts":"<iso-timestamp>"}\`

END_OF_INSTRUCTION
EOF
}
```

Replace with:

```bash
# cw_inbox_write <commander> <model> <topic> <task_text>
# Overwrite inbox.md with the task, terminating with the END_OF_INSTRUCTION
# sentinel so the trooper knows the message is complete.
#
# Atomic via per-call mktemp + rename: each invocation gets its OWN tmp file
# at "${inbox}.tmp.XXXXXX" (so concurrent callers can't truncate each other's
# in-flight content), then mv -f into place. POSIX rename within the same
# directory is atomic — readers and competing writers see exactly one of the
# completed versions, never a partial one. The trap unlinks the tmp on any
# abnormal exit (e.g. shell signal mid-write) so we don't leak in the
# trooper's state dir.
cw_inbox_write() {
  local commander="$1" model="$2" topic="$3" task="$4"
  local inbox outbox tmp
  inbox=$(cw_inbox_path "$commander" "$model" "$topic")
  outbox=$(cw_outbox_path "$commander" "$model" "$topic")
  tmp=$(mktemp "${inbox}.tmp.XXXXXX")
  trap 'rm -f "$tmp"' EXIT
  cat > "$tmp" <<EOF
$task

When done, append a single JSONL line to $outbox:

\`{"event":"done","summary":"<one-line summary>","ts":"<iso-timestamp>"}\`

END_OF_INSTRUCTION
EOF
  mv -f "$tmp" "$inbox"
  trap - EXIT
}
```

The `trap - EXIT` after the successful `mv` clears the cleanup trap so a normal-exit caller doesn't try to remove the (now-renamed-and-gone) tmp. The trap protects against signal-mid-write or downstream errors before the rename. Important: this trap is local to this function in the sense that it runs when the function's enclosing shell exits — for the typical `cw_inbox_write ...` invocation from `bin/send.sh`, that's at the end of `bin/send.sh`. If `bin/send.sh` calls `cw_inbox_write` then continues to do other work and crashes mid-script, the EXIT trap would still fire and remove a (no-longer-existing) tmp — `rm -f` is silent on missing files, so no harm.

- [ ] **Step 3.4: Run the test to verify it passes**

```bash
cd /home/liupan/CC/clone-wars && bash tests/test_inbox_atomic.sh
```

Expected: All 7 `PASS:` lines (the 5 numbered cases above each end with one or more `pass` calls), then `ALL: ok`.

- [ ] **Step 3.5: Run the full suite**

```bash
cd /home/liupan/CC/clone-wars && bash tests/run.sh
```

Expected: every test passes.

- [ ] **Step 3.6: Commit**

```bash
cd /home/liupan/CC/clone-wars
git add lib/ipc.sh tests/test_inbox_atomic.sh
git commit -m "$(cat <<'EOF'
feat(ipc): atomic, concurrent-safe inbox write (#8)

cw_inbox_write previously did `cat > "$inbox"` which truncates first
then writes. A concurrent reader (the trooper polling inbox.md via
the END_OF_INSTRUCTION sentinel) can race the truncate-write window
and see an empty/partial file. Two concurrent writers can each
truncate the inbox in the middle of the other's write.

Now uses mktemp "${inbox}.tmp.XXXXXX" per call (each writer gets its
own staging file) plus a cleanup trap, then mv -f into place.
POSIX rename within the same directory is atomic — readers and
competing writers see exactly one of the completed versions, never
a partial one.

Test exercises 20 concurrent writers and asserts: no .tmp leaks,
final inbox.md ends with END_OF_INSTRUCTION on its own line, and
the final content is one writer's message verbatim (no interleaving).
The static-grep wiring check guards against regression to a
deterministic tmp path.
EOF
)"
```

---

## Task 4 — `config/contracts.yaml` + `lib/contracts.sh` + `bin/spawn.sh`: contract-driven bootstrap sleep (#10)

**Files:**
- Modify: `/home/liupan/CC/clone-wars/config/contracts.yaml` (add `bootstrap_sleep_s:` per provider)
- Modify: `/home/liupan/CC/clone-wars/lib/contracts.sh` (add `cw_contract_bootstrap_sleep <provider>`)
- Modify: `/home/liupan/CC/clone-wars/bin/spawn.sh:155-161` (replace hardcoded case with contract lookup)
- Test: `/home/liupan/CC/clone-wars/tests/test_contracts.sh` (extend with new cases)

**Codex review note.** The naive default (`val=8` if field missing) silently regresses claude users on existing installs from 12s → 8s, because user-owned `~/.clone-wars/contracts.yaml` files don't get auto-overwritten on `/plugin update`. The fix preserves provider-specific legacy defaults INSIDE `cw_contract_bootstrap_sleep`: claude=12, all other providers=8. Once a user syncs the new field into their contracts.yaml (manual diff or fresh medic copy), the explicit value wins. The hardcoded defaults can be dropped in a future release after a migration window.

- [ ] **Step 4.1: Extend the failing test**

Open `/home/liupan/CC/clone-wars/tests/test_contracts.sh`. Read the current content. APPEND these new cases to the end of the file (BEFORE the final `pass` / suite-OK line if there is one — find the last `pass` call and add after it):

```bash
# === Phase 2: bootstrap_sleep_s contract field ===

# 7. cw_contract_bootstrap_sleep returns the field when set.
TMP_C=$(mktemp -d)
trap 'rm -rf "$TMP_C"' EXIT
cat > "$TMP_C/contracts.yaml" <<YAML
codex:
  binary: codex
  modes:
    full: [--bypass]
  default_mode: full
  ready_timeout_s: 30
  bootstrap_sleep_s: 5

claude:
  binary: claude
  modes:
    full: [--skip]
  default_mode: full
  ready_timeout_s: 60
  bootstrap_sleep_s: 12
YAML
got=$(CLONE_WARS_HOME="$TMP_C" cw_contract_bootstrap_sleep codex)
assert_eq "$got" "5" "codex bootstrap_sleep_s reads back"
got=$(CLONE_WARS_HOME="$TMP_C" cw_contract_bootstrap_sleep claude)
assert_eq "$got" "12" "claude bootstrap_sleep_s reads back"
pass "bootstrap_sleep_s field reads back"

# 8. Default value when field is missing — provider-specific legacy default.
#    claude=12 (preserves the v0.0.4 hardcoded BOOT_SLEEP for claude installs
#    that haven't synced the new field yet); everything else=8.
cat > "$TMP_C/contracts.yaml" <<YAML
codex:
  binary: codex
  modes:
    full: [--bypass]
  default_mode: full
  ready_timeout_s: 30

claude:
  binary: claude
  modes:
    full: [--skip]
  default_mode: full
  ready_timeout_s: 60

gemini:
  binary: gemini
  modes:
    full: [--yolo]
  default_mode: full
  ready_timeout_s: 30
YAML
got=$(CLONE_WARS_HOME="$TMP_C" cw_contract_bootstrap_sleep codex)
assert_eq "$got" "8" "missing bootstrap_sleep_s on codex defaults to 8"
got=$(CLONE_WARS_HOME="$TMP_C" cw_contract_bootstrap_sleep gemini)
assert_eq "$got" "8" "missing bootstrap_sleep_s on gemini defaults to 8"
got=$(CLONE_WARS_HOME="$TMP_C" cw_contract_bootstrap_sleep claude)
assert_eq "$got" "12" "missing bootstrap_sleep_s on claude defaults to 12 (legacy preservation)"
pass "bootstrap_sleep_s default is provider-specific (preserves claude=12 for existing installs)"

# 9. Unknown provider with no field → 8 (the safe global default).
got=$(CLONE_WARS_HOME="$TMP_C" cw_contract_bootstrap_sleep nosuchprovider)
assert_eq "$got" "8" "unknown provider with no field defaults to 8"
pass "unknown-provider default is 8"
```

- [ ] **Step 4.2: Run the test to verify it fails**

```bash
cd /home/liupan/CC/clone-wars && bash tests/test_contracts.sh
```

Expected: FAIL on case 7 — `cw_contract_bootstrap_sleep` doesn't exist yet (likely "command not found" in the subshell).

- [ ] **Step 4.3: Add `cw_contract_bootstrap_sleep` to `lib/contracts.sh`**

Open `/home/liupan/CC/clone-wars/lib/contracts.sh`. Find the existing `cw_contract_ready_timeout` function (it follows the same parser pattern we want). Add the new function IMMEDIATELY AFTER `cw_contract_ready_timeout`'s closing brace:

```bash
# cw_contract_bootstrap_sleep <provider>
# Print the seconds-to-sleep after launching the provider's TUI but BEFORE
# nudging it to read its identity. Mirrors the parser shape of
# cw_contract_ready_timeout.
#
# Default fallback when the field is unset is PROVIDER-SPECIFIC:
#   claude → 12 (preserves the v0.0.4 hardcoded BOOT_SLEEP)
#   anything else → 8
# This protects existing installs whose user-owned ~/.clone-wars/contracts.yaml
# was copied before the field was introduced — claude users don't silently
# regress to a too-short bootstrap. Once a user syncs bootstrap_sleep_s
# into their contracts.yaml, the explicit value wins. Drop the per-provider
# defaults in a future release after a migration window.
cw_contract_bootstrap_sleep() {
  local provider="$1" path val default
  case "$provider" in
    claude) default=12 ;;
    *)      default=8  ;;
  esac
  path=$(cw_contracts_path)
  [[ -f "$path" ]] || { printf '%s\n' "$default"; return; }
  val=$(awk -v p="$provider" '
    BEGIN { in_block = 0 }
    /^[A-Za-z][A-Za-z0-9_-]*:[[:space:]]*$/ {
      key = $0; sub(/:[[:space:]]*$/, "", key)
      in_block = (key == p); next
    }
    in_block && /^  bootstrap_sleep_s:[[:space:]]*/ {
      v = $0
      sub(/^  bootstrap_sleep_s:[[:space:]]*/, "", v)
      gsub(/^[ \t]+|[ \t\r]+$/, "", v)
      print v; exit
    }
  ' "$path")
  [[ -n "$val" ]] || val="$default"
  printf '%s\n' "$val"
}
```

- [ ] **Step 4.4: Add `bootstrap_sleep_s:` to each provider in `config/contracts.yaml`**

Open `/home/liupan/CC/clone-wars/config/contracts.yaml`. For each of the three providers (codex, gemini, claude), add a `bootstrap_sleep_s:` line immediately after the `ready_timeout_s:` line. Specifically:

In the `codex:` block, after `ready_timeout_s: 30`, add:

```yaml
  bootstrap_sleep_s: 8
```

In the `gemini:` block, after `ready_timeout_s: 30`, add:

```yaml
  bootstrap_sleep_s: 8
```

In the `claude:` block, after `ready_timeout_s: 60`, add:

```yaml
  bootstrap_sleep_s: 12
```

These values match the previously hardcoded BOOT_SLEEP case (claude=12, codex/gemini=8) — preserving exact behavior.

- [ ] **Step 4.5: Update `bin/spawn.sh` to use the contract field**

Find the bootstrap block in `bin/spawn.sh` (currently around lines 155-161 after Phase 1's edits):

```bash
case "$MODEL" in
  claude) BOOT_SLEEP=12 ;;
  *)      BOOT_SLEEP=8  ;;
esac
log_info "sleeping ${BOOT_SLEEP}s for $MODEL bootstrap"
sleep "$BOOT_SLEEP"
```

Replace with:

```bash
BOOT_SLEEP=$(cw_contract_bootstrap_sleep "$MODEL")
log_info "sleeping ${BOOT_SLEEP}s for $MODEL bootstrap"
sleep "$BOOT_SLEEP"
```

- [ ] **Step 4.6: Run tests**

```bash
cd /home/liupan/CC/clone-wars && bash tests/run.sh
```

Expected: every test passes including the extended `test_contracts.sh`.

- [ ] **Step 4.7: Commit**

```bash
cd /home/liupan/CC/clone-wars
git add config/contracts.yaml lib/contracts.sh bin/spawn.sh tests/test_contracts.sh
git commit -m "$(cat <<'EOF'
feat(contracts): bootstrap sleep is contract-driven (#10)

bin/spawn.sh previously hardcoded BOOT_SLEEP via case "$MODEL" in
claude) 12 / *) 8. Adding a new provider with slow startup meant
editing spawn.sh, not contracts.yaml.

Adds bootstrap_sleep_s field to each provider in contracts.yaml:
codex/gemini=8, claude=12 (exact preservation of the prior values).
New cw_contract_bootstrap_sleep reader mirrors the parser shape of
cw_contract_ready_timeout and defaults to 8 when the field is unset
(so tuning is opt-in and existing user-owned ~/.clone-wars/contracts.yaml
files keep working until the user syncs the field).
EOF
)"
```

---

## Task 5 — `bin/teardown.sh`: dedup graceful-shutdown logic (#11)

**Files:**
- Modify: `/home/liupan/CC/clone-wars/bin/teardown.sh` (extract `_teardown_batch`; collapse `teardown_topic` and the 2-arg branch onto it; remove `teardown_trooper`)

No new test file — the existing test suite plus manual smoke (running through a triple-test cycle once the branch is merged) covers the refactor.

- [ ] **Step 5.1: Read current `bin/teardown.sh` to confirm structure**

```bash
cd /home/liupan/CC/clone-wars && wc -l bin/teardown.sh && nl bin/teardown.sh | head -150
```

Verify the file has roughly the structure we expect (functions `teardown_trooper`, `teardown_topic`, plus the case dispatcher with `--all` / 1-arg / 2-arg branches).

- [ ] **Step 5.2: Replace the body of `bin/teardown.sh` (functions section only)**

The full target body for the functions section (everything between `source "$PLUGIN_ROOT/lib/colors.sh"` and the `case "${1:-}"` dispatcher) is:

```bash
# _teardown_batch <topic> <commander1>:<model1> <commander2>:<model2> ...
# Run the full graceful-shutdown + archive flow for each (commander, model)
# pair on <topic>. One graceful-banner phase fires in parallel across all
# live panes; one 9s sleep covers all banners; then hard-kill + archive.
#
# Pair encoding: "<commander>:<model>". Pane IDs start with '%' and never
# contain ':', and commander/model are validated to ^[a-z0-9-]+$, so the
# colon delimiter is unambiguous.
_teardown_batch() {
  local topic="$1"; shift
  local pairs=("$@")
  local pair commander model pane
  local pending_panes=()
  local last_file last_pane=""

  # Phase 1: graceful-kick each live pane (non-blocking — banner runs in pane).
  for pair in "${pairs[@]}"; do
    commander="${pair%:*}"
    model="${pair##*:}"
    pane=$(cw_pane_meta_read "$commander" "$model" "$topic" 2>/dev/null || echo '')
    if [[ -n "$pane" ]] && cw_pane_alive "$pane"; then
      log_info "graceful shutdown for $commander-$model on $topic (pane $pane)"
      cw_pane_kill_graceful "$pane"
      pending_panes+=("$pane")
    fi
  done

  # Phase 2: one sleep + hard-kill batch.
  if (( ${#pending_panes[@]} > 0 )); then
    log_info "waiting 9s for graceful banners to finish"
    sleep 9
    for pane in "${pending_panes[@]}"; do
      cw_pane_kill_now "$pane"
    done
  fi

  # Phase 3: archive each (state dirs are now safe to move).
  for pair in "${pairs[@]}"; do
    commander="${pair%:*}"
    model="${pair##*:}"
    local archived; archived=$(cw_state_archive "$commander" "$model" "$topic")
    log_ok "archived $commander-$model: $archived"
  done

  # Phase 4: clean topic .last_pane if it pointed at a killed pane.
  last_file="$(cw_state_root)/state/$(cw_repo_hash)/$topic/.last_pane"
  if [[ -f "$last_file" ]]; then
    last_pane=$(cat "$last_file")
    for pane in "${pending_panes[@]}"; do
      if [[ "$last_pane" == "$pane" ]]; then
        rm -f "$last_file"
        break
      fi
    done
  fi
}

teardown_topic() {
  local topic="$1"
  local topic_dir="$(cw_state_root)/state/$(cw_repo_hash)/$topic"
  [[ -d "$topic_dir" ]] || { log_warn "topic '$topic' has no state dir"; return; }

  shopt -s nullglob
  local pairs=()
  local trooper_dir
  for trooper_dir in "$topic_dir"/*/; do
    [[ -d "$trooper_dir" ]] || continue
    local _META; mapfile -t _META < <(cw_pane_meta_read_for_dir "$trooper_dir")
    pairs+=("${_META[0]}:${_META[1]}")
  done

  if (( ${#pairs[@]} > 0 )); then
    _teardown_batch "$topic" "${pairs[@]}"
  fi

  rm -f "$topic_dir/.last_pane" 2>/dev/null
  rmdir "$topic_dir" 2>/dev/null || true
}
```

Use the Read tool to find the EXACT current text of the existing `teardown_trooper` and `teardown_topic` functions, then `Edit` to replace them with the block above. The dispatcher (`case "${1:-}"`) below them stays as-is for now — Step 5.3 modifies just the 2-arg branch.

- [ ] **Step 5.3: Update the 2-arg branch in the dispatcher**

Find the `elif [[ $# -eq 2 ]]; then` branch in the case dispatcher (currently around lines 113-137 after Phase 1's edits). Replace its full body with:

```bash
    elif [[ $# -eq 2 ]]; then
      # Two args — commander + topic
      commander="$1" topic="$2"
      topic_dir="$(cw_state_root)/state/$(cw_repo_hash)/$topic"
      shopt -s nullglob
      pairs=()
      for d in "$topic_dir"/${commander}-*/; do
        [[ -d "$d" ]] || continue
        name="${d%/}"; name="${name##*/}"
        # Strip the known-commander prefix to recover the FULL model
        # (handles hyphenated models like claude-haiku correctly).
        model_hint="${name#${commander}-}"
        model=$(cw_pane_meta_model "$commander" "$model_hint" "$topic")
        pairs+=("$commander:$model")
      done
      (( ${#pairs[@]} > 0 )) || { log_error "no trooper '$commander' on topic '$topic'"; exit 1; }
      _teardown_batch "$topic" "${pairs[@]}"
      rm -f "$topic_dir/.last_pane" 2>/dev/null
      rmdir "$topic_dir" 2>/dev/null || true
```

The `--all` branch (which calls `teardown_topic` per topic) needs no change — `teardown_topic` is the same function, just with a refactored body.

- [ ] **Step 5.4: Lint-pass + run static-wiring test from Phase 1**

```bash
cd /home/liupan/CC/clone-wars
bash -n bin/teardown.sh && echo "syntax OK"
bash tests/test_teardown_hyphenated.sh
```

Expected: `syntax OK` then 3 PASS lines + `ALL: ok` (the static-grep test from Phase 1 still passes because the corrected `${name#${commander}-}` pattern is preserved in Step 5.3).

- [ ] **Step 5.5: Run the full suite**

```bash
cd /home/liupan/CC/clone-wars && bash tests/run.sh
```

Expected: every test passes. The teardown refactor has no new tests; correctness is asserted by Phase 1's `test_teardown_hyphenated.sh` (proves the parser fix survives) and the existing pattern-matching tests don't change.

- [ ] **Step 5.6: Manual smoke test (post-commit, in tmux)**

This is documentation for the controller / user post-merge. Not part of the implementer's automation.

```bash
# Spawn 3 troopers on a topic, then teardown via topic-mode.
bash bin/spawn.sh rex codex phase2-smoke
bash bin/spawn.sh cody codex phase2-smoke
bash bin/spawn.sh wolffe claude phase2-smoke
bash bin/list.sh phase2-smoke    # all three ready
bash bin/teardown.sh phase2-smoke
# Expect: ONE "waiting 9s for graceful banners" line for the whole batch
# (not three), all three archived, list now empty.

# Also smoke the 2-arg branch:
bash bin/spawn.sh rex codex phase2-2arg-smoke
bash bin/teardown.sh rex phase2-2arg-smoke
# Expect: one graceful banner, archived, list empty.
```

- [ ] **Step 5.7: Commit**

```bash
cd /home/liupan/CC/clone-wars
git add bin/teardown.sh
git commit -m "$(cat <<'EOF'
refactor(teardown): extract _teardown_batch helper (#11)

teardown_topic and the 2-arg dispatcher branch both implemented the
same "find panes -> graceful-kill -> sleep 9 -> hard-kill -> archive"
flow with subtly different conditions. DRY violation; bug-fixing both
copies in lockstep was fragile (Phase 1's hyphenated-model fix had
to land in two places).

Extract _teardown_batch <topic> <c1>:<m1> ... that takes a list of
commander:model pairs and runs the full shutdown in four explicit
phases (graceful-kick, sleep, hard-kill, archive). Both call sites
reduce to "iterate -> build pairs[] -> call _teardown_batch".

Removes the now-unused teardown_trooper helper. No behavior change;
the existing test_teardown_hyphenated.sh (Phase 1) still passes,
proving the parser fix survives the refactor.
EOF
)"
```

---

## Task 6 — Bump to `v0.0.5`

**Files:**
- Modify: `/home/liupan/CC/clone-wars/.claude-plugin/plugin.json:3`
- Modify: `/home/liupan/CC/clone-wars/.claude-plugin/marketplace.json` (both `version` keys)

- [ ] **Step 6.1: Update `plugin.json`**

In `/home/liupan/CC/clone-wars/.claude-plugin/plugin.json`, change `"version": "0.0.4"` → `"version": "0.0.5"`.

- [ ] **Step 6.2: Update `marketplace.json`**

In `/home/liupan/CC/clone-wars/.claude-plugin/marketplace.json`, change BOTH `"version": "0.0.4"` occurrences (the per-plugin entry and the top-level marketplace version) to `"version": "0.0.5"`.

- [ ] **Step 6.3: Final test-suite run**

```bash
cd /home/liupan/CC/clone-wars && bash tests/run.sh
```

Expected: every test passes.

- [ ] **Step 6.4: Commit**

```bash
cd /home/liupan/CC/clone-wars
git add .claude-plugin/plugin.json .claude-plugin/marketplace.json
git commit -m "$(cat <<'EOF'
chore: bump version 0.0.4 → 0.0.5 (Phase 2 hardening release)

Phase 2 of the hardening rollout per
docs/superpowers/specs/2026-04-26-clone-wars-hardening-design.md.

Includes:
- JSON-strict event matching via cw_event_match_pattern (#7)
- cw_outbox_wait short-circuits on terminal events (#6)
- atomic inbox write via tmp+rename (#8)
- contract-driven bootstrap sleep (#10)
- DRY teardown via _teardown_batch helper (#11)

#9 (archive timestamp collisions) was already implemented in Phase 1
Task 1 as part of cw_state_archive's collision counter, so Phase 2
shipped 5 fixes instead of 6.
EOF
)"
```

---

## Task 7 — Open the PR

**Files:** none (git/gh operations only).

- [ ] **Step 7.1: Push the branch**

```bash
cd /home/liupan/CC/clone-wars
git push -u origin chore/v0.0.5-hardening-phase-2
```

- [ ] **Step 7.2: Open the PR**

```bash
gh pr create --title "chore: v0.0.5 — Phase 2 hardening (fixes #6, #7, #8, #10, #11)" --body "$(cat <<'EOF'
## Summary
Phase 2 of the hardening rollout per
\`docs/superpowers/specs/2026-04-26-clone-wars-hardening-design.md\` § Phase 2.

Fixes:
- **#7** JSON-strict event matching via \`cw_event_match_pattern\` (anchored regex). Closes the false-positive class where a substring grep on \`'"event":"done"'\` would also match a progress note containing those bytes.
- **#6** \`cw_outbox_wait\` accepts a space-separated event list and short-circuits on the first match. \`bin/spawn.sh\` now waits for \`"ready error"\` and exits within ~1s on explicit error instead of waiting the full 30/60s timeout.
- **#8** \`cw_inbox_write\` is now atomic via tmp+rename. POSIX rename within the same directory is atomic; concurrent readers see either the old or new file, never a partially-written one.
- **#10** Bootstrap sleep is contract-driven via new \`bootstrap_sleep_s\` field per provider. Adding a slow-startup provider no longer requires editing \`bin/spawn.sh\`. Defaults to 8 if missing (so existing \`~/.clone-wars/contracts.yaml\` files keep working).
- **#11** \`bin/teardown.sh\` extracts \`_teardown_batch\` helper. \`teardown_topic\` and the 2-arg branch both reduce to "iterate, build pairs[], call _teardown_batch". Removes the duplicated graceful-shutdown logic.

Note on **#9** (archive timestamp collisions): the spec listed this for Phase 2 but it was already implemented in Phase 1 Task 1 as part of \`cw_state_archive\`'s collision-resolution loop. Phase 2 therefore ships 5 fixes instead of 6.

Bumps to **v0.0.5**.

## Test results
- 13 test files (3 new in Phase 2: \`test_event_match.sh\`, \`test_outbox_wait.sh\`, \`test_inbox_atomic.sh\`).
- \`bash tests/run.sh\` exits 0.

## Test plan (post-merge, with \`/plugin update\`)
- [ ] \`/clone-wars:medic\` still verdict-OK.
- [ ] Spawn → send → trooper appends \`{"event":"progress","note":"...event:done..."}\` then real \`{"event":"done"}\` — \`/clone-wars:collect\` matches the real one.
- [ ] Spawn against a provider that emits \`{"event":"error"}\` immediately — spawn exits within ~1s with \`[FAIL] reported {error} during bootstrap\` and a \`-FAILED\` archive.
- [ ] Spawn 3 troopers on a topic, \`teardown <topic>\` → ONE 9s "waiting for banners" line (not three), all archived.
- [ ] Add a custom provider with \`bootstrap_sleep_s: 20\` to \`~/.clone-wars/contracts.yaml\` → spawn that provider; observe \`sleeping 20s for ... bootstrap\`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 7.3: Surface the PR URL**

The user merges, retags `v0.0.5`, and runs `/plugin update`. Plan execution ends here.

---

## Self-review checklist

- [x] **Spec coverage:** Each of #6, #7, #8, #10, #11 has a dedicated task. #9 is correctly noted as already-shipped in Phase 1. Version bump and PR are explicit final tasks. ✓
- [x] **Placeholder scan:** No "TBD", "TODO", "implement later", or vague "add error handling" instructions. Every code step has the exact code; every command step has the exact invocation and expected output. ✓
- [x] **Type / signature consistency:**
  - `cw_event_match_pattern <event_name>` — defined in Task 1.3, called identically in Tasks 1.5, 1.6, 2.3.
  - `cw_outbox_wait <commander> <model> <topic> <event1> [<event2> ...] <timeout>` — Task 2.3 implements the spec-shaped varargs API: timeout is the FINAL positional arg, events fill positions between `<topic>` and timeout. Single-event call (`c m t ready 30`) preserved; multi-event call (`c m t ready error 30`) is the new short-circuit shape.
  - `cw_inbox_write <commander> <model> <topic> <task_text>` — signature unchanged; body switched to per-call `mktemp "${inbox}.tmp.XXXXXX"` + trap cleanup + `mv -f` for concurrent-writer safety.
  - `cw_contract_bootstrap_sleep <provider>` — defined in Task 4.3, called in Task 4.5. Provider-specific legacy defaults (claude=12, others=8) when the field is missing — protects existing installs from a silent regression.
  - `_teardown_batch <topic> <commander>:<model> ...` — defined in Task 5.2, called identically in Task 5.2 (`teardown_topic`) and Task 5.3 (2-arg branch).
- [x] **TDD discipline:** Tasks 1, 2, 3, 4 each have a failing-test step before implementation. Task 5 has no new test (refactor; Phase 1's `test_teardown_hyphenated.sh` is the regression guard).
- [x] **Frequent commits:** One commit per task. Stopping after any commit leaves the runtime strictly-better.
- [x] **No fix-list overrun:** Phase 2 ships 5 fixes per the spec — #6, #7, #8, #10, #11. No scope creep into Phase 3 territory.
- [x] **Codex adversarial review findings addressed:**
  - Finding 1 (high, atomic inbox concurrent-writer race) → Task 3 now uses per-call `mktemp` + cleanup trap; test 5 in `test_inbox_atomic.sh` exercises 20 concurrent writers and asserts no interleaving / no .tmp leaks. ✓
  - Finding 2 (high, claude bootstrap regression on existing installs) → `cw_contract_bootstrap_sleep` returns 12 for claude / 8 for others when the field is missing; test_contracts.sh case 8 covers all three providers' legacy defaults + an unknown-provider control. ✓
  - Finding 3 (medium, signature divergence from spec) → `cw_outbox_wait` uses varargs (events between topic and final timeout), matching the spec's example invocation `... ready error 30`. Single-event calls keep the same shape. ✓
