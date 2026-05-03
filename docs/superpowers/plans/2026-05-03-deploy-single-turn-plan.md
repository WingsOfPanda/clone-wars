# Deploy Single-Turn Trooper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Collapse `/clone-wars:deploy`'s plan / implement / self-verify into one trooper turn per round; Yoda only re-engages at cross-verify and teardown.

**Architecture:** Add two new bin scripts (`deploy-turn-send.sh` + `deploy-turn-wait.sh`) and two new lib helpers (`cw_deploy_build_turn_prompt_round1` + `cw_deploy_build_turn_prompt_fix`); rewrite Steps 1.2/1.3/2.1 of `commands/deploy.md` into one collapsed Step 1 with auto-retry-once on failure; delete six obsolete bin scripts and four obsolete lib helpers; rename per-phase state files into one `turn-cody-<N>.txt` per round.

**Tech Stack:** bash 4.2+, tmux/file-IPC, existing `lib/{state,ipc,deploy,log}.sh` patterns, `tests/lib/assert.sh`, `tests/run.sh`.

**Spec:** `docs/superpowers/specs/2026-05-03-deploy-single-turn-design.md` (committed `65fc4cf`)

---

## File Map

| File | Action | Notes |
|---|---|---|
| `lib/deploy.sh` | modify | Add 2 helpers (Tasks 1, 2); delete 4 helpers (Task 7) |
| `bin/deploy-turn-send.sh` | create | Task 3 |
| `bin/deploy-turn-wait.sh` | create | Task 4 |
| `bin/medic.sh` | modify | Update probe + warn on legacy env vars (Task 5) |
| `commands/deploy.md` | rewrite | Collapse Steps 1.2/1.3/2.1 → Step 1; simplify Step 3 (Task 6) |
| `bin/deploy-{plan,implement,verify,fix}-{send,wait}.sh` | delete | 7 files (Task 8) |
| `tests/test_deploy_turn_helpers.sh` | create | Tasks 1, 2 |
| `tests/test_deploy_turn_send.sh` | create | Task 3 |
| `tests/test_deploy_turn_wait.sh` | create | Task 4 |
| `tests/test_deploy_helpers.sh` | modify | Replace deleted-helper assertions (Task 7) |
| `tests/test_medic.sh` | modify | Add legacy-env-var warning assertion (Task 5) |
| `tests/test_deploy_{plan,implement,verify,fix}_send.sh` | delete | 4 files (Task 8) |
| `tests/test_deploy_wait_scripts.sh` | delete | 1 file (Task 8) |
| `tests/test_deploy_v07_dogfood.sh` | create | Manual gate, Task 9 |
| `CLAUDE.md` | modify | Status checklist tick (Task 10) |

Total: 4 created bin/lib files, 2 created/modified directives + medic, 4 created tests, 12 deleted files, 1 final-validation step.

---

## Task 1: Add `cw_deploy_build_turn_prompt_round1` helper

**Files:**
- Modify: `lib/deploy.sh` (insert new helper near line 105, before existing `cw_deploy_build_plan_prompt`)
- Create: `tests/test_deploy_turn_helpers.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test_deploy_turn_helpers.sh`:

```bash
#!/usr/bin/env bash
# tests/test_deploy_turn_helpers.sh — unit coverage for new turn-prompt builders.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

# shellcheck disable=SC1091
source ../lib/log.sh
# shellcheck disable=SC1091
source ../lib/deploy.sh

# --- cw_deploy_build_turn_prompt_round1 ---
OUT=$(cw_deploy_build_turn_prompt_round1 "/abs/design.md" "/abs/plan.md" "/abs/verify-report-1.md")

echo "$OUT" | grep -q 'END_OF_INSTRUCTION' \
  || { echo "FAIL: round1 missing END_OF_INSTRUCTION sentinel" >&2; exit 1; }
pass "round1 prompt ends with END_OF_INSTRUCTION"

echo "$OUT" | grep -q 'superpowers:writing-plans' \
  || { echo "FAIL: round1 missing writing-plans skill mention" >&2; exit 1; }
pass "round1 names writing-plans skill"

echo "$OUT" | grep -q 'superpowers:subagent-driven-development' \
  || { echo "FAIL: round1 missing subagent-driven-development skill mention" >&2; exit 1; }
pass "round1 names subagent-driven-development skill"

echo "$OUT" | grep -q 'superpowers:verification-before-completion' \
  || { echo "FAIL: round1 missing verification-before-completion skill mention" >&2; exit 1; }
pass "round1 names verification-before-completion skill"

echo "$OUT" | grep -q '/abs/design.md' \
  || { echo "FAIL: round1 missing design path" >&2; exit 1; }
pass "round1 references design path"

echo "$OUT" | grep -q '/abs/plan.md' \
  || { echo "FAIL: round1 missing plan path" >&2; exit 1; }
pass "round1 references plan path"

echo "$OUT" | grep -q '/abs/verify-report-1.md' \
  || { echo "FAIL: round1 missing verify-report path" >&2; exit 1; }
pass "round1 references verify-report path"

echo "$OUT" | grep -qiE 'resume|already exists|skip' \
  || { echo "FAIL: round1 missing resume preamble" >&2; exit 1; }
pass "round1 includes resume preamble"

echo "$OUT" | grep -q 'VERDICT' \
  || { echo "FAIL: round1 missing VERDICT contract" >&2; exit 1; }
pass "round1 mentions VERDICT contract"

echo "ALL: ok"
```

- [ ] **Step 2: Run test to verify it fails**

```bash
bash tests/test_deploy_turn_helpers.sh
```

Expected: FAIL with `cw_deploy_build_turn_prompt_round1: command not found` (or first grep failing).

- [ ] **Step 3: Add the helper to `lib/deploy.sh`**

Insert this function in `lib/deploy.sh` immediately before line 106 (the existing `cw_deploy_build_plan_prompt`):

```bash
# cw_deploy_build_turn_prompt_round1 <design> <plan_out> <verify_out>
# Emits the round-1 inbox prompt for the collapsed plan+implement+verify
# trooper turn. Bound to writing-plans + subagent-driven-development +
# verification-before-completion skills. Includes resume-aware preamble so
# auto-retry on the same prompt picks up from disk state.
cw_deploy_build_turn_prompt_round1() {
  local design="$1" plan_out="$2" verify_out="$3"
  cat <<EOF
You are entering ROUND 1 of /clone-wars:deploy.

This is a single-turn workflow: you will write the implementation plan,
implement it, run the test suite, and write the verify report — all in
one autonomous run. The conductor will only re-engage when you emit done.

RESUME CHECK (do this BEFORE starting):
- If $plan_out already exists, skip the planning phase — read the
  existing plan and proceed to implementation.
- If \`git log --oneline\` shows commits past the design-doc commit on
  this branch, identify the next pending task from $plan_out's checkbox
  state and continue from there. Do not redo already-committed tasks.
- If $verify_out already exists, you previously completed implementation
  — re-run the test suite and update $verify_out if test outcomes changed.

PHASE 1: Plan (skip if $plan_out exists)
  Use the superpowers:writing-plans skill. Read the design doc at:
    $design
  Produce a comprehensive implementation plan and write it to:
    $plan_out

PHASE 2: Implement
  Use the superpowers:subagent-driven-development skill. Walk $plan_out
  task-by-task. Commit per task (Conventional Commits prefix). Run the
  full test suite (\`bash tests/run.sh\`) after each task and confirm green.

PHASE 3: Self-verify
  Use the superpowers:verification-before-completion skill. Run the full
  test suite, tee output to test-output-1.log alongside the verify
  report, and write a structured verify report to:
    $verify_out

  The report MUST start with \`VERDICT: PASS|PARTIAL|FAIL\` on the first
  line, followed by per-requirement evidence (file:line citations) and a
  short summary.

When all three phases are done AND the test suite is green AND
$verify_out exists with a VERDICT line, emit:
  {"event":"done","summary":"Round 1 complete","ts":"<iso>"}

END_OF_INSTRUCTION
EOF
}

```

- [ ] **Step 4: Run test to verify it passes**

```bash
bash tests/test_deploy_turn_helpers.sh
```

Expected: 9 PASS lines, ends with `ALL: ok`.

- [ ] **Step 5: Commit**

```bash
git add lib/deploy.sh tests/test_deploy_turn_helpers.sh
git commit -m "feat(deploy): add round-1 turn prompt builder"
```

---

## Task 2: Add `cw_deploy_build_turn_prompt_fix` helper

**Files:**
- Modify: `lib/deploy.sh` (append new helper after `cw_deploy_build_turn_prompt_round1`)
- Modify: `tests/test_deploy_turn_helpers.sh` (extend)

- [ ] **Step 1: Extend the failing test**

Append to `tests/test_deploy_turn_helpers.sh` BEFORE the final `echo "ALL: ok"`:

```bash

# --- cw_deploy_build_turn_prompt_fix ---
TMPF=$(mktemp); trap 'rm -f "$TMPF"' EXIT
cat > "$TMPF" <<'BUNDLE'
- [bug] foo bar baz
- [spec-gap] quux
BUNDLE

OUT=$(cw_deploy_build_turn_prompt_fix "$TMPF" "/abs/verify-report-3.md" 3)

echo "$OUT" | grep -q 'END_OF_INSTRUCTION' \
  || { echo "FAIL: fix missing END_OF_INSTRUCTION" >&2; exit 1; }
pass "fix prompt ends with END_OF_INSTRUCTION"

echo "$OUT" | grep -q 'ROUND 3' \
  || { echo "FAIL: fix missing round number" >&2; exit 1; }
pass "fix prompt names round number"

echo "$OUT" | grep -q 'superpowers:systematic-debugging' \
  || { echo "FAIL: fix missing systematic-debugging routing" >&2; exit 1; }
pass "fix routes to systematic-debugging for [bug]/[regression]"

echo "$OUT" | grep -q 'superpowers:writing-plans' \
  || { echo "FAIL: fix missing writing-plans routing" >&2; exit 1; }
pass "fix routes to writing-plans for [spec-gap]"

echo "$OUT" | grep -q 'foo bar baz' \
  || { echo "FAIL: fix did not embed bundle content" >&2; exit 1; }
pass "fix embeds the bundle issue text"

echo "$OUT" | grep -q '/abs/verify-report-3.md' \
  || { echo "FAIL: fix missing verify-report path" >&2; exit 1; }
pass "fix references verify-report path"

echo "$OUT" | grep -qiE 'resume|already|skip' \
  || { echo "FAIL: fix missing resume preamble" >&2; exit 1; }
pass "fix includes resume preamble"

# Missing-bundle path
err=$(cw_deploy_build_turn_prompt_fix "/no/such/path.md" "/abs/v.md" 2 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: missing bundle should rc!=0" >&2; exit 1; }
echo "$err" | grep -qi 'not found\|missing\|unreadable' \
  || { echo "FAIL: missing-bundle error message unclear: $err" >&2; exit 1; }
pass "fix prompt rc!=0 + clear error when bundle missing"
```

- [ ] **Step 2: Run test to verify it fails**

```bash
bash tests/test_deploy_turn_helpers.sh
```

Expected: passes the round1 block, then fails with `cw_deploy_build_turn_prompt_fix: command not found`.

- [ ] **Step 3: Add the helper to `lib/deploy.sh`**

Append in `lib/deploy.sh` immediately after the `cw_deploy_build_turn_prompt_round1` function added in Task 1:

```bash
# cw_deploy_build_turn_prompt_fix <fix_bundle_path> <verify_out> <round>
# Emits the fix-round inbox prompt for the collapsed fix+verify trooper
# turn. Reads the user-authored fix bundle from disk, wraps it with
# routing instructions (systematic-debugging for [bug]/[regression],
# writing-plans for [spec-gap]) and the resume-aware preamble.
# Returns 1 on missing/unreadable bundle.
cw_deploy_build_turn_prompt_fix() {
  local bundle="$1" verify_out="$2" round="$3"
  [[ -f "$bundle" && -r "$bundle" ]] \
    || { log_error "fix bundle not found or unreadable: $bundle"; return 1; }
  local issues
  issues=$(cat "$bundle")
  cat <<EOF
You are entering ROUND $round of /clone-wars:deploy (fix loop).

This is a single-turn workflow: address each issue below, re-run the test
suite, and write the verify report — all in one autonomous run.

RESUME CHECK (do this BEFORE starting):
- Check \`git log --oneline\` for commits since the previous round's
  verify report was written. If some issues already have addressing
  commits, identify which remain unaddressed and start from those.
- If $verify_out already exists, re-run tests and update it if outcomes
  changed.

ISSUES TO ADDRESS:

$issues

ROUTING:
- For each issue tagged [bug] or [regression]: use the
  superpowers:systematic-debugging skill.
- For each issue tagged [spec-gap]: use the superpowers:writing-plans
  skill (re-plan the gap, then implement).

For EACH issue: implement the fix, commit per fix (Conventional Commits
prefix \`fix:\`, \`feat:\`, or \`test:\` as appropriate), then re-run
the full test suite. Do NOT skip any listed issue.

After all issues are addressed AND the test suite is green:
  Run the full test suite, tee output to test-output-$round.log
  alongside the verify report. Write the verify report to:
    $verify_out
  The report MUST start with \`VERDICT: PASS|PARTIAL|FAIL\`.

When done, emit:
  {"event":"done","summary":"Round $round complete","ts":"<iso>"}

END_OF_INSTRUCTION
EOF
}

```

- [ ] **Step 4: Run test to verify it passes**

```bash
bash tests/test_deploy_turn_helpers.sh
```

Expected: 17 PASS lines (9 from Task 1 + 8 new), ends with `ALL: ok`.

- [ ] **Step 5: Commit**

```bash
git add lib/deploy.sh tests/test_deploy_turn_helpers.sh
git commit -m "feat(deploy): add fix-round turn prompt builder"
```

---

## Task 3: Add `bin/deploy-turn-send.sh`

**Files:**
- Create: `bin/deploy-turn-send.sh`
- Create: `tests/test_deploy_turn_send.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test_deploy_turn_send.sh`:

```bash
#!/usr/bin/env bash
# tests/test_deploy_turn_send.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

# Static wiring: sources lib, builds round-1 prompt, writes OFFSET, calls send.sh.
grep -q 'source.*lib/deploy.sh' ../bin/deploy-turn-send.sh \
  || { echo "FAIL: missing lib source" >&2; exit 1; }
grep -q 'cw_deploy_assert_topic' ../bin/deploy-turn-send.sh \
  || { echo "FAIL: missing topic assert" >&2; exit 1; }
grep -q 'cw_deploy_build_turn_prompt_round1' ../bin/deploy-turn-send.sh \
  || { echo "FAIL: missing round-1 prompt builder" >&2; exit 1; }
grep -q 'cw_deploy_build_turn_prompt_fix' ../bin/deploy-turn-send.sh \
  || { echo "FAIL: missing fix prompt builder" >&2; exit 1; }
grep -q 'wc -c' ../bin/deploy-turn-send.sh \
  || { echo "FAIL: missing wc -c offset capture" >&2; exit 1; }
grep -q 'OFFSET=' ../bin/deploy-turn-send.sh \
  || { echo "FAIL: missing OFFSET= write" >&2; exit 1; }
grep -q 'turn-cody-' ../bin/deploy-turn-send.sh \
  || { echo "FAIL: missing turn-cody-N state file ref" >&2; exit 1; }
pass "deploy-turn-send static wiring"

# Build a fake topic dir + cody trooper outbox.
RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
TOPIC=turn-send-fixture
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
mkdir -p "$TD/_deploy" "$TD/cody-codex"
echo "fake design body" > "$TD/_deploy/design.md"
touch "$TD/cody-codex/outbox.jsonl"
printf '{"pane_id":"%%99","spawned_at":"x"}\n' > "$TD/cody-codex/pane.json"
printf '{"state":"idle","updated":"x","last_event":"ready"}\n' > "$TD/cody-codex/status.json"

# Bad arg counts rejected.
err=$(../bin/deploy-turn-send.sh 2>&1) && rc=0 || rc=$?
[[ "$rc" -eq 2 ]] || { echo "FAIL: zero args should rc=2 (got $rc)" >&2; exit 1; }
pass "deploy-turn-send rc=2 on zero args"

err=$(../bin/deploy-turn-send.sh "$TOPIC" 2>&1) && rc=0 || rc=$?
[[ "$rc" -eq 2 ]] || { echo "FAIL: missing round arg should rc=2 (got $rc)" >&2; exit 1; }
pass "deploy-turn-send rc=2 on missing round"

err=$(../bin/deploy-turn-send.sh "$TOPIC" "abc" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: non-numeric round should rc!=0" >&2; exit 1; }
echo "$err" | grep -qi 'round\|numeric' \
  || { echo "FAIL: non-numeric round error message unclear: $err" >&2; exit 1; }
pass "deploy-turn-send rejects non-numeric round"

# Bad topic rejected.
err=$(../bin/deploy-turn-send.sh "../bad" 1 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: bad topic should rc!=0" >&2; exit 1; }
pass "deploy-turn-send rejects bad topic"

# Round-1 idempotency-fail-loud: pre-populate state file.
echo "OFFSET=0" > "$TD/_deploy/turn-cody-1.txt"
err=$(../bin/deploy-turn-send.sh "$TOPIC" 1 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && echo "$err" | grep -q 'already exists' \
  || { echo "FAIL: should refuse with existing state file. rc=$rc out=$err" >&2; exit 1; }
pass "deploy-turn-send fails loud on existing state file"
rm -f "$TD/_deploy/turn-cody-1.txt"

# Round >=2 missing fix-prompt rejected.
err=$(../bin/deploy-turn-send.sh "$TOPIC" 2 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && echo "$err" | grep -qi 'fix-prompt\|fix bundle\|not found' \
  || { echo "FAIL: round>=2 should require fix-prompt-N.md. rc=$rc out=$err" >&2; exit 1; }
pass "deploy-turn-send round>=2 requires fix-prompt-N.md"

# Trooper-not-idle rejected.
printf '{"state":"working","updated":"x","last_event":"ack"}\n' > "$TD/cody-codex/status.json"
err=$(../bin/deploy-turn-send.sh "$TOPIC" 1 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && echo "$err" | grep -qi 'not idle\|in flight\|busy' \
  || { echo "FAIL: not-idle status should be refused. rc=$rc out=$err" >&2; exit 1; }
pass "deploy-turn-send refuses when trooper not idle"

echo "ALL: ok"
```

- [ ] **Step 2: Run test to verify it fails**

```bash
bash tests/test_deploy_turn_send.sh
```

Expected: FAIL — script does not exist.

- [ ] **Step 3: Create `bin/deploy-turn-send.sh`**

```bash
#!/usr/bin/env bash
# bin/deploy-turn-send.sh — single-turn dispatch (codex).
#
# Usage: bin/deploy-turn-send.sh <topic> <round>
#
# Round 1: writes _deploy/turn-cody-1.txt (OFFSET=<n>) using the
# round-1 prompt (plan + implement + verify in one turn).
# Round >=2: reads _deploy/fix-prompt-<round>.md from disk and
# wraps it with the fix-round preamble.
# Refuses if the state file already exists (idempotency-fail-loud) OR if
# the trooper's status.json shows state != idle.

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/deploy.sh"

[[ $# -eq 2 ]] || { echo "Usage: $0 <topic> <round>" >&2; exit 2; }
TOPIC="$1"
ROUND="$2"
[[ "$ROUND" =~ ^[1-9][0-9]*$ ]] || { log_error "round must be a positive integer (got: $ROUND)"; exit 1; }
cw_deploy_assert_topic "$TOPIC"

ART_DIR="$(cw_deploy_art_dir "$TOPIC")"
[[ -d "$ART_DIR" ]] || { log_error "$ART_DIR not found — run deploy-init first"; exit 1; }

STATE_FILE="$ART_DIR/turn-cody-$ROUND.txt"
[[ ! -e "$STATE_FILE" ]] || { log_error "$STATE_FILE already exists; rm to retry"; exit 1; }

TROOPER_DIR=$(cw_trooper_dir cody codex "$TOPIC")
OUTBOX="$TROOPER_DIR/outbox.jsonl"
STATUS="$TROOPER_DIR/status.json"
[[ -f "$OUTBOX" ]] || { log_error "outbox not found at $OUTBOX — was cody spawned?"; exit 1; }

# Trooper-not-idle gate (prevents racing the previous turn's mid-write).
if [[ -f "$STATUS" ]]; then
  STATE=$(grep -oE '"state":"[^"]*"' "$STATUS" | head -1 | sed 's/.*"state":"\([^"]*\)".*/\1/')
  if [[ -n "$STATE" && "$STATE" != "idle" ]]; then
    log_error "trooper not idle (state=$STATE); previous turn still in flight"
    exit 1
  fi
fi

PROMPT_FILE="$ART_DIR/cody_turn_prompt_$ROUND.md"

if [[ "$ROUND" -eq 1 ]]; then
  DESIGN="$ART_DIR/design.md"
  PLAN_OUT="$ART_DIR/plan.md"
  VERIFY_OUT="$ART_DIR/verify-report-1.md"
  cw_deploy_build_turn_prompt_round1 "$DESIGN" "$PLAN_OUT" "$VERIFY_OUT" > "$PROMPT_FILE"
else
  FIX_BUNDLE="$ART_DIR/fix-prompt-$ROUND.md"
  [[ -f "$FIX_BUNDLE" ]] || { log_error "fix-prompt-$ROUND.md not found at $FIX_BUNDLE; the directive must write it before invoking"; exit 1; }
  VERIFY_OUT="$ART_DIR/verify-report-$ROUND.md"
  if ! cw_deploy_build_turn_prompt_fix "$FIX_BUNDLE" "$VERIFY_OUT" "$ROUND" > "$PROMPT_FILE"; then
    log_error "failed to build fix-round prompt"
    exit 1
  fi
fi

OFFSET=$(wc -c < "$OUTBOX" | tr -d ' ')
printf 'OFFSET=%s\n' "$OFFSET" > "$STATE_FILE"

if ! "$PLUGIN_ROOT/bin/send.sh" cody "$TOPIC" "@$PROMPT_FILE" >/dev/null; then
  log_error "send.sh failed; state file kept for retry"
  exit 1
fi

log_info "[turn-send] cody round=$ROUND offset=$OFFSET"
```

```bash
chmod +x bin/deploy-turn-send.sh
```

- [ ] **Step 4: Run test to verify it passes**

```bash
bash tests/test_deploy_turn_send.sh
```

Expected: 9 PASS lines, ends with `ALL: ok`.

- [ ] **Step 5: Commit**

```bash
git add bin/deploy-turn-send.sh tests/test_deploy_turn_send.sh
git commit -m "feat(deploy): add deploy-turn-send (single-turn dispatch)"
```

---

## Task 4: Add `bin/deploy-turn-wait.sh`

**Files:**
- Create: `bin/deploy-turn-wait.sh`
- Create: `tests/test_deploy_turn_wait.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test_deploy_turn_wait.sh`:

```bash
#!/usr/bin/env bash
# tests/test_deploy_turn_wait.sh — parameterized integration test for the wait script.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"
export CW_DEPLOY_TURN_TIMEOUT=2  # short timeout for the timeout-path case

RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')

setup_topic() {
  local topic="$1"
  local td="$CLONE_WARS_HOME/state/$RH/$topic"
  mkdir -p "$td/_deploy" "$td/cody-codex"
  touch "$td/cody-codex/outbox.jsonl"
  printf 'OFFSET=0\n' > "$td/_deploy/turn-cody-1.txt"
  echo "$td"
}

# --- Case 1: done event + verify-report present → TS=ok ---
TD=$(setup_topic ok-fixture)
echo '{"event":"done","summary":"x","ts":"y"}' >> "$TD/cody-codex/outbox.jsonl"
echo "VERDICT: PASS" > "$TD/_deploy/verify-report-1.md"
../bin/deploy-turn-wait.sh ok-fixture 1 >/dev/null
grep -q '^TS=ok$' "$TD/_deploy/turn-cody-1.txt" \
  || { echo "FAIL: case 1 expected TS=ok" >&2; cat "$TD/_deploy/turn-cody-1.txt"; exit 1; }
[[ -f "$TD/_deploy/turn-cody-1.done" ]] \
  || { echo "FAIL: case 1 missing .done sentinel" >&2; exit 1; }
pass "wait writes TS=ok + sentinel on done event with verify-report present"

# --- Case 2: done event but verify-report missing → TS=failed ---
TD=$(setup_topic missing-verify)
echo '{"event":"done","summary":"x","ts":"y"}' >> "$TD/cody-codex/outbox.jsonl"
../bin/deploy-turn-wait.sh missing-verify 1 >/dev/null
grep -q '^TS=failed$' "$TD/_deploy/turn-cody-1.txt" \
  || { echo "FAIL: case 2 expected TS=failed" >&2; cat "$TD/_deploy/turn-cody-1.txt"; exit 1; }
pass "wait writes TS=failed when done but verify-report missing"

# --- Case 3: error event → TS=failed ---
TD=$(setup_topic err-fixture)
echo '{"event":"error","message":"boom","ts":"y"}' >> "$TD/cody-codex/outbox.jsonl"
echo "VERDICT: FAIL" > "$TD/_deploy/verify-report-1.md"
../bin/deploy-turn-wait.sh err-fixture 1 >/dev/null
grep -q '^TS=failed$' "$TD/_deploy/turn-cody-1.txt" \
  || { echo "FAIL: case 3 expected TS=failed" >&2; cat "$TD/_deploy/turn-cody-1.txt"; exit 1; }
pass "wait writes TS=failed on error event"

# --- Case 4: no event before timeout → TS=timeout ---
TD=$(setup_topic timeout-fixture)
# Empty outbox; CW_DEPLOY_TURN_TIMEOUT=2 means short wait.
../bin/deploy-turn-wait.sh timeout-fixture 1 >/dev/null
grep -q '^TS=timeout$' "$TD/_deploy/turn-cody-1.txt" \
  || { echo "FAIL: case 4 expected TS=timeout" >&2; cat "$TD/_deploy/turn-cody-1.txt"; exit 1; }
pass "wait writes TS=timeout when no event lands"

# --- Case 5: bad args ---
err=$(../bin/deploy-turn-wait.sh 2>&1) && rc=0 || rc=$?
[[ "$rc" -eq 2 ]] || { echo "FAIL: zero args should rc=2 (got $rc)" >&2; exit 1; }
pass "wait rc=2 on zero args"

err=$(../bin/deploy-turn-wait.sh some-topic 2>&1) && rc=0 || rc=$?
[[ "$rc" -eq 2 ]] || { echo "FAIL: missing round should rc=2 (got $rc)" >&2; exit 1; }
pass "wait rc=2 on missing round"

# --- Case 6: per-round state file (not the legacy plan-cody.txt) ---
TD=$(setup_topic per-round-fixture)
mv "$TD/_deploy/turn-cody-1.txt" "$TD/_deploy/turn-cody-3.txt"
echo '{"event":"done","summary":"x","ts":"y"}' >> "$TD/cody-codex/outbox.jsonl"
echo "VERDICT: PASS" > "$TD/_deploy/verify-report-3.md"
../bin/deploy-turn-wait.sh per-round-fixture 3 >/dev/null
grep -q '^TS=ok$' "$TD/_deploy/turn-cody-3.txt" \
  || { echo "FAIL: case 6 round=3 state file not updated" >&2; exit 1; }
[[ -f "$TD/_deploy/turn-cody-3.done" ]] \
  || { echo "FAIL: case 6 round=3 sentinel missing" >&2; exit 1; }
pass "wait honors per-round state file (round=3)"

echo "ALL: ok"
```

- [ ] **Step 2: Run test to verify it fails**

```bash
bash tests/test_deploy_turn_wait.sh
```

Expected: FAIL — script does not exist.

- [ ] **Step 3: Create `bin/deploy-turn-wait.sh`**

```bash
#!/usr/bin/env bash
# bin/deploy-turn-wait.sh — single-turn wait.
#
# Usage: bin/deploy-turn-wait.sh <topic> <round>
#
# Reads OFFSET= from _deploy/turn-cody-<round>.txt; appends TS=<status>.
# Returns rc=0 always — status field carries the outcome.
#
# Status values:
#   ok       — done event + verify-report-<round>.md exists with content
#   failed   — done event but verify-report missing/empty, OR error event
#   timeout  — no done|error event before CW_DEPLOY_TURN_TIMEOUT (default 14400s)

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/deploy.sh"

[[ $# -eq 2 ]] || { echo "Usage: $0 <topic> <round>" >&2; exit 2; }
TOPIC="$1"
ROUND="$2"
[[ "$ROUND" =~ ^[1-9][0-9]*$ ]] || { log_error "round must be a positive integer (got: $ROUND)"; exit 1; }
cw_deploy_assert_topic "$TOPIC"

ART_DIR="$(cw_deploy_art_dir "$TOPIC")"
STATE_FILE="$ART_DIR/turn-cody-$ROUND.txt"
[[ -f "$STATE_FILE" ]] || { log_error "$STATE_FILE missing — run deploy-turn-send first"; exit 1; }
# shellcheck disable=SC1090
source "$STATE_FILE"
[[ -n "${OFFSET:-}" ]] || { log_error "OFFSET not set in $STATE_FILE"; exit 1; }

TIMEOUT="${CW_DEPLOY_TURN_TIMEOUT:-14400}"
log_info "[turn-wait] cody round=$ROUND offset=$OFFSET timeout=${TIMEOUT}s"

cw_outbox_wait_since cody codex "$TOPIC" "$OFFSET" done error "$TIMEOUT" >/dev/null || true

TROOPER_DIR=$(cw_trooper_dir cody codex "$TOPIC")
OUTBOX="$TROOPER_DIR/outbox.jsonl"
TAIL=$(tail -c "+$(( OFFSET + 1 ))" "$OUTBOX" 2>/dev/null || true)
MATCHED=$(printf '%s\n' "$TAIL" | grep -m1 -E '"event":"(done|error)"' || true)
EVENT=$(printf '%s' "$MATCHED" | sed -n 's/.*"event":"\([^"]*\)".*/\1/p')

VERIFY_OUT="$ART_DIR/verify-report-$ROUND.md"

case "$EVENT" in
  done)
    if [[ -f "$VERIFY_OUT" && -s "$VERIFY_OUT" ]]; then
      printf 'TS=ok\n' >> "$STATE_FILE"
      log_info "[turn-wait] cody round=$ROUND TS=ok"
    else
      printf 'TS=failed\n' >> "$STATE_FILE"
      log_warn "[turn-wait] cody round=$ROUND TS=failed (done but verify-report-$ROUND.md empty/missing)"
    fi
    ;;
  error)
    printf 'TS=failed\n' >> "$STATE_FILE"
    log_warn "[turn-wait] cody round=$ROUND TS=failed (error event)"
    ;;
  '')
    printf 'TS=timeout\n' >> "$STATE_FILE"
    log_warn "[turn-wait] cody round=$ROUND TS=timeout"
    ;;
  *)
    printf 'TS=failed\n' >> "$STATE_FILE"
    log_warn "[turn-wait] cody round=$ROUND TS=failed (unknown event '$EVENT')"
    ;;
esac

# background-await sentinel
touch "${STATE_FILE%.txt}.done"
exit 0
```

```bash
chmod +x bin/deploy-turn-wait.sh
```

- [ ] **Step 4: Run test to verify it passes**

```bash
bash tests/test_deploy_turn_wait.sh
```

Expected: 7 PASS lines, ends with `ALL: ok`.

- [ ] **Step 5: Commit**

```bash
git add bin/deploy-turn-wait.sh tests/test_deploy_turn_wait.sh
git commit -m "feat(deploy): add deploy-turn-wait (single-turn wait)"
```

---

## Task 5: Update `bin/medic.sh` (new probe + legacy env-var warnings)

**Files:**
- Modify: `bin/medic.sh` (lines 128-139 + new section after probe)
- Modify: `tests/test_medic.sh` (add legacy-env-var assertion)

- [ ] **Step 1: Update the failing test**

Inspect the current `tests/test_medic.sh` shape:

```bash
sed -n '1,50p' tests/test_medic.sh
```

Append at the end of `tests/test_medic.sh` (before any final `echo "ALL: ok"` line):

```bash

# --- legacy env-var warnings ---
out=$(CW_DEPLOY_PLAN_TIMEOUT=999 bash ../bin/medic.sh 2>&1) || true
echo "$out" | grep -qi 'CW_DEPLOY_PLAN_TIMEOUT.*deprecated\|CW_DEPLOY_PLAN_TIMEOUT.*ignored' \
  || { echo "FAIL: medic should warn on CW_DEPLOY_PLAN_TIMEOUT" >&2; exit 1; }
pass "medic warns on legacy CW_DEPLOY_PLAN_TIMEOUT env var"

out=$(CW_DEPLOY_IMPLEMENT_TIMEOUT=999 bash ../bin/medic.sh 2>&1) || true
echo "$out" | grep -qi 'CW_DEPLOY_IMPLEMENT_TIMEOUT.*deprecated\|CW_DEPLOY_IMPLEMENT_TIMEOUT.*ignored' \
  || { echo "FAIL: medic should warn on CW_DEPLOY_IMPLEMENT_TIMEOUT" >&2; exit 1; }
pass "medic warns on legacy CW_DEPLOY_IMPLEMENT_TIMEOUT env var"

out=$(CW_DEPLOY_VERIFY_TIMEOUT=999 bash ../bin/medic.sh 2>&1) || true
echo "$out" | grep -qi 'CW_DEPLOY_VERIFY_TIMEOUT.*deprecated\|CW_DEPLOY_VERIFY_TIMEOUT.*ignored' \
  || { echo "FAIL: medic should warn on CW_DEPLOY_VERIFY_TIMEOUT" >&2; exit 1; }
pass "medic warns on legacy CW_DEPLOY_VERIFY_TIMEOUT env var"

out=$(CW_DEPLOY_FIX_TIMEOUT=999 bash ../bin/medic.sh 2>&1) || true
echo "$out" | grep -qi 'CW_DEPLOY_FIX_TIMEOUT.*deprecated\|CW_DEPLOY_FIX_TIMEOUT.*ignored' \
  || { echo "FAIL: medic should warn on CW_DEPLOY_FIX_TIMEOUT" >&2; exit 1; }
pass "medic warns on legacy CW_DEPLOY_FIX_TIMEOUT env var"

# Probe still passes after the helper rename.
out=$(bash ../bin/medic.sh 2>&1) || true
echo "$out" | grep -q 'deploy helpers load clean' \
  || { echo "FAIL: medic deploy-helpers probe regressed" >&2; exit 1; }
pass "medic deploy-helpers probe still clean after refactor"
```

- [ ] **Step 2: Run test to verify it fails**

```bash
bash tests/test_medic.sh
```

Expected: FAIL on the new env-var assertions (no warning emitted).

- [ ] **Step 3: Update `bin/medic.sh` probe + add env-var warnings**

Modify `bin/medic.sh` lines 128-139 (the `4d. deploy helpers source-load sanity` block). Replace `cw_deploy_topic_dir test-topic >/dev/null` with `cw_deploy_build_turn_prompt_round1 /a /b /c >/dev/null`:

```bash
# 4d. deploy helpers source-load sanity (turn-based deploy).
if ( source "$PLUGIN_ROOT/lib/state.sh" \
     && source "$PLUGIN_ROOT/lib/log.sh" \
     && source "$PLUGIN_ROOT/lib/consult.sh" \
     && source "$PLUGIN_ROOT/lib/deploy.sh" \
     && cw_deploy_build_turn_prompt_round1 /a /b /c >/dev/null ) 2>/dev/null; then
  log_ok "deploy helpers load clean"
else
  log_warn "deploy helpers FAILED to load"
  warn=1
fi

# 4e. legacy deploy env vars (now ignored — CW_DEPLOY_TURN_TIMEOUT is the single knob).
for legacy_var in CW_DEPLOY_PLAN_TIMEOUT CW_DEPLOY_IMPLEMENT_TIMEOUT \
                  CW_DEPLOY_VERIFY_TIMEOUT CW_DEPLOY_FIX_TIMEOUT; do
  if [[ -n "${!legacy_var:-}" ]]; then
    log_warn "$legacy_var is deprecated and ignored; use CW_DEPLOY_TURN_TIMEOUT (default 14400s)"
    warn=1
  fi
done
```

- [ ] **Step 4: Run test to verify it passes**

```bash
bash tests/test_medic.sh
```

Expected: previous tests still PASS + 5 new PASS lines, ends with `ALL: ok`.

- [ ] **Step 5: Commit**

```bash
git add bin/medic.sh tests/test_medic.sh
git commit -m "chore(medic): probe new turn helpers; warn on legacy deploy env vars"
```

---

## Task 6: Rewrite `commands/deploy.md` directive

**Files:**
- Modify: `commands/deploy.md` (collapse Steps 1.2/1.3/2.1 into one Step 1; simplify Step 3)

This is a larger rewrite. The deploy directive's TaskCreate block, audit, spawn, teardown, and archive sections stay unchanged. The plan/implement/verify-fix machinery becomes one unified loop.

- [ ] **Step 1: Read the current directive to anchor the rewrite**

```bash
sed -n '1,60p' commands/deploy.md  # task-list block + intro
sed -n '140,260p' commands/deploy.md  # current Steps 1.2/1.3/2 fix-loop
```

- [ ] **Step 2: Update the TaskCreate table**

Replace the current task table (around lines 30-45 of `commands/deploy.md`) with the new shape:

```markdown
## Task list (TaskCreate × 6 BEFORE step 0)

| # | subject | activeForm |
|---|---|---|
| 0   | `0   Audit design doc [yoda]`              | `Auditing design doc` |
| 1.1 | `1.1 Spawn cody (codex) [yoda]`            | `Spawning cody` |
| 1   | `1   Run trooper turn (round N) [cody]`    | `Cody running turn (round N)` |
| 2   | `2   Cross-verify (round N) [yoda]`        | `Yoda cross-verifying (round N)` |
| 3   | `3   Author fix bundle (if needed) [yoda]` | `Authoring fix bundle` |
| 4   | `4   Teardown + archive [yoda]`            | `Tearing down` |
```

(The subject lines should reflect the round number using activeForm updates — same pattern as the existing verify task.)

- [ ] **Step 3: Replace Steps 1.2 + 1.3 + 2.1 with a single Step 1 block**

Delete the current Step 1.2 (Plan), Step 1.3 (Implement), Step 2.1 (Self-verify) sections entirely. Replace with:

```markdown
### Step 1 — Run trooper turn (round-aware, auto-retry-once)

Set task `1` → `in_progress`. Use the same task across rounds; only the
activeForm reflects the round number (e.g. `Cody running turn (round 2)`).

Initialize (only on first entry, NOT on retry):

```
ROUND=1
RETRY_COUNT=0
MAX_ROUNDS="${MAX_ROUNDS_OVERRIDE:-5}"
```

**Dispatch:**

```
"$CLAUDE_PLUGIN_ROOT/bin/deploy-turn-send.sh" "$TOPIC" "$ROUND"
```

If round 1, the script generates the round-1 prompt (plan + implement +
self-verify in one turn). If round >= 2, the script reads
`$ART_DIR/fix-prompt-$ROUND.md` (which Step 3 wrote on the previous round)
and wraps it with the fix-round preamble. **Yoda authors fix-prompt-$ROUND.md
in Step 3 BEFORE incrementing ROUND and re-entering Step 1.**

**Wait (background — Yoda's pane stays interactive):**

```
Bash(
  command='"$CLAUDE_PLUGIN_ROOT/bin/deploy-turn-wait.sh" "$TOPIC" "$ROUND"',
  run_in_background: true,
  description='master yoda await cody round=$ROUND turn (background)'
)
```

Default timeout is 4 hours (`CW_DEPLOY_TURN_TIMEOUT=14400`). Override
with the env var if your topic is unusually large.

**On harness completion notification:**

Read `TS=` from `$ART_DIR/turn-cody-$ROUND.txt`:

```
TS=$(grep '^TS=' "$ART_DIR/turn-cody-$ROUND.txt" | tail -1 | cut -d= -f2)
```

Branch on TS:

- `TS=ok` → set task `1` → `completed` for this round; jump to Step 2.
- `TS=failed` or `TS=timeout` → auto-retry path:

  ```
  if (( RETRY_COUNT == 0 )); then
    log "auto-retry round=$ROUND attempt=2"
    rm -f "$ART_DIR/turn-cody-$ROUND.txt" "$ART_DIR/turn-cody-$ROUND.done"
    rm -f "$ART_DIR/cody_turn_prompt_$ROUND.md"
    RETRY_COUNT=1
    # re-dispatch turn-send + turn-wait (loop back to top of Step 1)
  else
    # Two attempts failed.
    AskUserQuestion (Hand-off / Abort / Try-again).
    Hand-off: write $ART_DIR/RESUME.md with topic dir + branch + last
      cross-verify summary; preserve cody pane (do NOT teardown); exit.
    Abort: bin/deploy-teardown.sh + bin/deploy-archive.sh; exit.
    Try-again: RETRY_COUNT=0; loop back to top of Step 1.
  fi
  ```
```

- [ ] **Step 4: Replace Step 2.2 → Step 2 (cross-verify, drop the .1/.2 split)**

Rename "Step 2.2" to "Step 2 — Cross-verify (per round)". Body is unchanged
except for the task ID references (`task 2.2` → `task 2`). The reads,
`cross-verify-$ROUND.md` write contract, PASS/FAIL branching, and round
exhaustion handling (`ROUND > MAX_ROUNDS`) all stay the same.

- [ ] **Step 5: Replace Step 3 (Fix-prompt + dispatch) with a simpler version**

Delete the current Step 3 entirely (debug/gap split, deploy-fix-send.sh,
inter-bundle wait, GAP_OFFSET, CW_DEPLOY_FIX_TIMEOUT). Replace with:

```markdown
### Step 3 — Author fix bundle

Set task `3` → `in_progress`.

Read `cross-verify-$ROUND.md`. For every issue listed under `## Issues`,
preserve its tag (`[bug]`, `[regression]`, `[spec-gap]`) and its
`(file:line)` evidence. Group all issues into a single fix bundle file:

```
$ART_DIR/fix-prompt-$((ROUND + 1)).md
```

The fix bundle is a markdown body — NO preamble, NO skill mention, NO
END_OF_INSTRUCTION sentinel. The turn-send script wraps it with all of
those when it dispatches. Just list the issues, one per markdown bullet,
each starting with the tag:

```markdown
- [bug] <evidence> — <suggested fix direction>
- [spec-gap] <evidence> — <suggested fix direction>
```

After writing the bundle:

```
ROUND=$((ROUND + 1))
RETRY_COUNT=0
```

Set task `3` → `completed`; loop back to Step 1.
```

- [ ] **Step 6: Update env-var documentation block at the end of the directive**

Add a short env-var section near the bottom of `commands/deploy.md` (before
the "Intervention patterns" section):

```markdown
## Environment variables

- `CW_DEPLOY_TURN_TIMEOUT` (default `14400` / 4hr) — max wall time for one
  trooper turn (plan+implement+verify in round 1; fix+verify in fix
  rounds). Set to a larger value for very long-running specs; reduce
  only for testing.
- `MAX_ROUNDS_OVERRIDE` (default `5`) — fix-round ceiling before
  exhaustion AskUserQuestion fires.

The following legacy env vars are **deprecated and ignored** (medic warns
when set):
- `CW_DEPLOY_PLAN_TIMEOUT`
- `CW_DEPLOY_IMPLEMENT_TIMEOUT`
- `CW_DEPLOY_VERIFY_TIMEOUT`
- `CW_DEPLOY_FIX_TIMEOUT`
```

- [ ] **Step 7: Run the focused tests to confirm directive references stay coherent**

```bash
bash tests/test_deploy_helpers.sh
bash tests/test_deploy_turn_helpers.sh
bash tests/test_deploy_turn_send.sh
bash tests/test_deploy_turn_wait.sh
bash tests/test_medic.sh
```

Expected: each ends with `ALL: ok`. (test_deploy_helpers.sh is updated in Task 7.)

- [ ] **Step 8: Commit**

```bash
git add commands/deploy.md
git commit -m "feat(deploy): collapse plan/implement/verify into single trooper turn"
```

---

## Task 7: Delete obsolete `lib/deploy.sh` helpers + update test_deploy_helpers.sh

**Files:**
- Modify: `lib/deploy.sh` (delete 4 helpers around lines 106-200)
- Modify: `tests/test_deploy_helpers.sh` (replace assertions on deleted helpers)

- [ ] **Step 1: Inspect current test_deploy_helpers.sh assertions**

```bash
grep -n 'cw_deploy_build' tests/test_deploy_helpers.sh
```

Note which lines reference `cw_deploy_build_plan_prompt`,
`cw_deploy_build_implement_prompt`, `cw_deploy_build_verify_prompt`,
`cw_deploy_build_fix_prompt`.

- [ ] **Step 2: Update tests/test_deploy_helpers.sh**

Delete every block in `tests/test_deploy_helpers.sh` that references
the four deleted helpers. The branch override / git-repo gate / audit
/ branch-create assertions stay unchanged.

If the file ends up missing prompt-builder coverage entirely, that's
fine — the new builders are covered by `tests/test_deploy_turn_helpers.sh`
and don't need duplicate assertions here.

- [ ] **Step 3: Run the test to confirm it still passes after the deletions**

```bash
bash tests/test_deploy_helpers.sh
```

Expected: ends with `ALL: ok` (with fewer PASS lines than before — the
prompt-builder PASS lines are gone, but no new failures).

- [ ] **Step 4: Delete the four obsolete helpers from `lib/deploy.sh`**

Remove these functions from `lib/deploy.sh` (currently around lines 106-200):

- `cw_deploy_build_plan_prompt`
- `cw_deploy_build_implement_prompt`
- `cw_deploy_build_verify_prompt`
- `cw_deploy_build_fix_prompt`

Each function's body and the comment header above it. Keep
`cw_deploy_build_turn_prompt_round1` and `cw_deploy_build_turn_prompt_fix`
(added in Tasks 1 + 2).

- [ ] **Step 5: Run the test again to confirm nothing in tests references the deleted helpers**

```bash
bash tests/test_deploy_helpers.sh
bash tests/test_deploy_turn_helpers.sh
```

Expected: both end with `ALL: ok`. If `test_deploy_helpers.sh` fails with
`cw_deploy_build_plan_prompt: command not found`, return to Step 2 and
delete the missed reference.

- [ ] **Step 6: Commit**

```bash
git add lib/deploy.sh tests/test_deploy_helpers.sh
git commit -m "refactor(deploy): drop obsolete per-phase prompt builders"
```

---

## Task 8: Delete obsolete bin scripts and tests

**Files:**
- Delete (7): `bin/deploy-plan-send.sh`, `bin/deploy-plan-wait.sh`, `bin/deploy-implement-send.sh`, `bin/deploy-implement-wait.sh`, `bin/deploy-verify-send.sh`, `bin/deploy-verify-wait.sh`, `bin/deploy-fix-send.sh`
- Delete (5): `tests/test_deploy_plan_send.sh`, `tests/test_deploy_implement_send.sh`, `tests/test_deploy_verify_send.sh`, `tests/test_deploy_fix_send.sh`, `tests/test_deploy_wait_scripts.sh`

- [ ] **Step 1: Confirm nothing in the codebase still references the deleted scripts**

```bash
grep -rn 'deploy-plan-\|deploy-implement-\|deploy-verify-\|deploy-fix-' \
  bin commands lib tests config 2>/dev/null
```

Expected: empty output. If anything remains (e.g. a stale README or doc
reference), update it to point at `deploy-turn-send.sh` /
`deploy-turn-wait.sh` instead.

- [ ] **Step 2: Delete the 7 obsolete bin scripts**

```bash
git rm bin/deploy-plan-send.sh bin/deploy-plan-wait.sh \
       bin/deploy-implement-send.sh bin/deploy-implement-wait.sh \
       bin/deploy-verify-send.sh bin/deploy-verify-wait.sh \
       bin/deploy-fix-send.sh
```

- [ ] **Step 3: Delete the 5 obsolete test files**

```bash
git rm tests/test_deploy_plan_send.sh \
       tests/test_deploy_implement_send.sh \
       tests/test_deploy_verify_send.sh \
       tests/test_deploy_fix_send.sh \
       tests/test_deploy_wait_scripts.sh
```

- [ ] **Step 4: Run the full test suite**

```bash
bash tests/run.sh
```

Expected: all remaining `test_*.sh` files PASS, suite ends green. If any
test references one of the deleted bin scripts, return to Step 1.

- [ ] **Step 5: Commit**

```bash
git commit -m "refactor(deploy): delete obsolete per-phase scripts and tests"
```

---

## Task 9: Add manual dogfood gate

**Files:**
- Create: `tests/test_deploy_v07_dogfood.sh`

This is a manual gate (skipped by `tests/run.sh` automatically — it
mirrors the gating pattern of `tests/test_deploy_v070_dogfood.sh`).

- [ ] **Step 1: Inspect the existing dogfood script for the gating + skip pattern**

```bash
head -40 tests/test_deploy_v070_dogfood.sh
grep -n 'SKIP\|tmux\|TMUX\|codex' tests/test_deploy_v070_dogfood.sh | head -10
```

Note the skip-banner shape and the `tests/run.sh` skip mechanism.

- [ ] **Step 2: Create the new dogfood script**

Create `tests/test_deploy_v07_dogfood.sh`:

```bash
#!/usr/bin/env bash
# tests/test_deploy_v07_dogfood.sh — manual gate for the single-turn deploy.
# Skipped by tests/run.sh; run manually to validate end-to-end behavior.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

if [[ "${CW_RUN_DOGFOOD:-}" != "1" ]]; then
  echo "SKIP: set CW_RUN_DOGFOOD=1 to run the v07 single-turn dogfood"
  exit 0
fi

# Gate on tmux + $TMUX + codex.
if ! command -v tmux >/dev/null; then
  echo "SKIP: tmux not on PATH"
  exit 0
fi
if [[ -z "${TMUX:-}" ]]; then
  echo "SKIP: \$TMUX not set (run inside a tmux session)"
  exit 0
fi
if ! command -v codex >/dev/null; then
  echo "SKIP: codex not on PATH"
  exit 0
fi

echo "Manual dogfood gate for /clone-wars:deploy single-turn refactor."
echo ""
echo "Steps to validate:"
echo "  1. Spawn cody-codex on a small fixture spec; dispatch round-1 turn."
echo "     Confirm plan.md + implementation commits + verify-report-1.md"
echo "     all land BEFORE the done event lands in outbox.jsonl."
echo "  2. Force a TS=timeout mid-implement (kill the codex pane manually)."
echo "     Confirm Yoda's auto-retry fires once, the new prompt re-dispatches,"
echo "     and the trooper resumes from git log + plan.md state rather than"
echo "     re-planning from scratch."
echo "  3. Force a cross-verify FAIL on round 1. Confirm fix-prompt-2.md is"
echo "     authored by Yoda, the second turn is dispatched as a fix-round"
echo "     prompt (single skill router, no -debug/-gap split), and the trooper"
echo "     skips already-committed fixes via the resume contract."
echo ""
echo "If all three scenarios pass, this gate is GREEN — flip the v07 release"
echo "checkbox in CLAUDE.md."
echo ""
echo "ALL: ok"
```

```bash
chmod +x tests/test_deploy_v07_dogfood.sh
```

- [ ] **Step 3: Confirm tests/run.sh skips it cleanly**

```bash
bash tests/run.sh 2>&1 | grep -i 'v07_dogfood\|SKIP'
```

Expected: the dogfood file is either not invoked, or invoked and prints
SKIP cleanly without affecting the suite verdict.

- [ ] **Step 4: Commit**

```bash
git add tests/test_deploy_v07_dogfood.sh
git commit -m "test(deploy): add v07 manual dogfood gate for single-turn refactor"
```

---

## Task 10: Final validation + CLAUDE.md status update

**Files:**
- Modify: `CLAUDE.md` (add v0.8 status entry)

- [ ] **Step 1: Run the full test suite**

```bash
bash tests/run.sh 2>&1 | tee /tmp/deploy-single-turn-final.log | tail -15
```

Expected: every `test_*.sh: ok` line, ends with the suite's final OK marker.
If any test fails, return to its task.

- [ ] **Step 2: Run medic + confirm clean**

```bash
bash bin/medic.sh
```

Expected: `Verdict: OK`. Confirm "deploy helpers load clean" line is
present. Confirm no unexpected warnings.

- [ ] **Step 3: Confirm directive surface unchanged from user perspective**

```bash
grep -E '^/clone-wars:|^- /clone-wars:' README.md commands/*.md 2>/dev/null | head -20
```

Expected: `/clone-wars:deploy` still listed; `medic` / `consult` /
`teardown` / `list` still listed; no obsolete `/clone-wars:plan` or similar.

- [ ] **Step 4: Update `CLAUDE.md` status checklist**

Find the status checklist section near the bottom of `CLAUDE.md` and
append a new line:

```markdown
- [x] v0.8.0: deploy single-turn — plan+implement+verify run in one trooper turn per round; auto-retry-once; CW_DEPLOY_TURN_TIMEOUT=14400 default; 6 bin scripts and 4 lib helpers deleted
- [ ] v0.8.0 strict-dogfood pass on a real machine (release gate)
```

- [ ] **Step 5: Commit + final summary**

```bash
git add CLAUDE.md
git commit -m "docs(claude): mark v0.8.0 deploy single-turn complete"
git log --oneline main..HEAD
```

Expected: 10 commits on the branch (one per task), all conventional-commits formatted.

---

## Self-review notes

- **Spec coverage:**
  - Single inbox per round → Tasks 1, 2, 3, 6
  - Resume-aware prompt template → Tasks 1, 2 (preamble in builder bodies)
  - `CW_DEPLOY_TURN_TIMEOUT=14400` → Task 4 (wait script default), Task 5 (medic warns on legacy), Task 6 (directive doc)
  - Single `turn-cody-N.txt` state file → Tasks 3, 4
  - Auto-retry-once → Task 6 (directive logic)
  - Medic warns on legacy env vars → Task 5
  - All cross-verify reads, fix-bundle authoring, 5-round ceiling, taxonomy unchanged → Task 6 (Steps 2 + 3 are unchanged in shape)
  - Six bin scripts + four lib helpers deleted, two of each added → Tasks 1-4 (add), Tasks 7-8 (delete)
  - `tests/run.sh` stays green → Task 10 (validation)

- **Type / name consistency:** `cw_deploy_build_turn_prompt_round1`, `cw_deploy_build_turn_prompt_fix`, `bin/deploy-turn-send.sh`, `bin/deploy-turn-wait.sh`, `turn-cody-<N>.txt`, `TS=ok|failed|timeout`, `CW_DEPLOY_TURN_TIMEOUT` — used identically across all tasks.

- **No placeholders:** every step has explicit code or commands. The directive rewrite (Task 6) shows the exact markdown to insert; the bin scripts (Tasks 3 + 4) show the full file contents.
