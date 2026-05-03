---
description: Audit a design doc, dispatch it to a Codex trooper for plan/implement/self-verify, then cross-verify and fix-loop until PASS or 5 rounds.
argument-hint: [<design-path>] [--no-branch] [--branch <name>] [--topic <slug>] [--max-rounds 5]
---

# /clone-wars:execute-design

Run a Codex-implements / Yoda-verifies pipeline on `$ARGUMENTS`. Master Yoda
audits the design doc; spawns one persistent Codex trooper (`cody-codex-<topic>`);
delegates plan + implementation + self-verification to the trooper using
superpowers skills; and cross-verifies after every codex self-verify pass,
sending fix bundles back until PASS or 5 rounds (then `AskUserQuestion`).

The cody pane stays attached for the entire run — `tmux select-pane` to watch.

Spec: `docs/superpowers/specs/2026-05-02-clone-wars-execute-design.md`

## Source defaulting

If `$ARGUMENTS` does not include a `.md` path, look for the most recent
`state/<repo-hash>/<topic>/_consult/synthesis.md` under `$CLONE_WARS_HOME`
(consult writes synthesis.md INSIDE `_consult/`, not at the topic root) and
prompt the user via `AskUserQuestion` to confirm. If no synthesis.md is found
and no explicit path was given, refuse with a usage hint.

## Task list (TaskCreate × 8 BEFORE step 0)

| # | subject | activeForm |
|---|---|---|
| 0   | `0   Audit design doc [yoda]`               | `Auditing design doc` |
| 1.1 | `1.1 Spawn cody (codex) [yoda]`             | `Spawning cody` |
| 1.2 | `1.2 Plan [cody/codex]`                     | `Cody planning` |
| 1.3 | `1.3 Implement [cody/codex]`                | `Cody implementing` |
| 2.1 | `2.1 Self-verify [cody/codex]`              | `Cody self-verifying` |
| 2.2 | `2.2 Cross-verify [yoda]`                   | `Yoda cross-verifying` |
| 3   | `3   Fix loop (if needed) [yoda + cody]`    | `Running fix loop` |
| 4   | `4   Teardown + archive [yoda]`             | `Tearing down` |

## Steps

The user's `$ARGUMENTS` may contain shell metacharacters. Write it via the
Write tool, then invoke sub-scripts with the resolved values.

### Step 0 — Audit design doc

Set task `0` → `in_progress`.

1. Resolve args path:
   ```
   ARGS_DIR="${CLONE_WARS_HOME:-$HOME/.clone-wars}/_args"
   mkdir -p "$ARGS_DIR"; echo "$ARGS_DIR/execute-design.txt"
   ```
2. Parse `--max-rounds <N>` out of `$ARGUMENTS` BEFORE writing the args file.
   The init script rejects unknown flags, so this flag must never reach it.
   Scan `$ARGUMENTS` token-by-token: when you see `--max-rounds`, capture the
   NEXT token into `MAX_ROUNDS_OVERRIDE` (export it for Step 2's loop init)
   and drop both tokens. Write the REMAINING tokens (space-joined) to the
   args file via the Write tool — not `$ARGUMENTS` verbatim.

   Example transformation:
   - `$ARGUMENTS` = `path/to/spec.md --topic foo --max-rounds 3 --no-branch`
   - `MAX_ROUNDS_OVERRIDE` = `3`
   - args-file contents = `path/to/spec.md --topic foo --no-branch`

   If `--max-rounds` is absent, leave `MAX_ROUNDS_OVERRIDE` unset (Step 2
   defaults to 5) and write `$ARGUMENTS` unchanged.
3. Write tool: `file_path` = the path printed in step 1; `content` = the
   filtered argument string from step 2 (or `$ARGUMENTS` verbatim if no
   `--max-rounds` was found).
4. Inspect the args file to detect "no positional .md arg given". If so,
   apply source defaulting:
   - Find the most recent consult synthesis under this repo's state root:
     ```
     source "$CLAUDE_PLUGIN_ROOT/lib/state.sh"
     REPO_HASH=$(cw_repo_hash)
     STATE_ROOT="${CLONE_WARS_HOME:-$HOME/.clone-wars}"
     CANDIDATE=$(find "$STATE_ROOT/state/$REPO_HASH" \
                   -path '*/_consult/synthesis.md' -type f \
                   -printf '%T@ %p\n' 2>/dev/null \
                   | sort -n | tail -1 | cut -d' ' -f2-)
     ```
   - If `CANDIDATE` is non-empty, `AskUserQuestion` (options: "Use this",
     "Cancel"). On "Use this", append the path to the args file (so init.sh
     receives it as the positional argument). On "Cancel", exit 0.
   - If `CANDIDATE` is empty and no `.md` path is in the args file, refuse
     with a usage hint and exit 1.
5. Init (init.sh consumes the args file directly — its argv parser handles
   `--no-branch` / `--branch` / `--topic` / `<design-path>`):
   ```
   source "$CLAUDE_PLUGIN_ROOT/lib/state.sh"
   REPO_HASH=$(cw_repo_hash)
   TOPIC=$("$CLAUDE_PLUGIN_ROOT/bin/execute-design-init.sh" \
              --args-file "$ARGS_DIR/execute-design.txt")
   TOPIC_DIR="${CLONE_WARS_HOME:-$HOME/.clone-wars}/state/$REPO_HASH/$TOPIC"
   ART_DIR="$TOPIC_DIR/_execute"
   # Record branch base for cross-verify diff range (used in Step 2.2 + Step 4).
   # init.sh creates feat/exec-<topic> from HEAD, so HEAD right now IS the
   # commit the new branch was created from — exactly the diff base we want.
   # Do NOT use `git merge-base HEAD main` here: when invoked from a topic
   # branch that already diverged from main, merge-base returns the prior
   # branch's divergence point (over-counting unrelated commits).
   git rev-parse HEAD > "$ART_DIR/branch-base.sha"
   BRANCH_BASE=$(cat "$ART_DIR/branch-base.sha")
   ```
6. Run audit and persist verdict:
   ```
   source "$CLAUDE_PLUGIN_ROOT/lib/execute_design.sh"
   AUDIT=$(cw_execute_design_audit_doc "$ART_DIR/design.md" 2>&1) && AUDIT_RC=0 || AUDIT_RC=$?
   printf '%s\n' "$AUDIT" > "$ART_DIR/design-audit.md"
   ```
7. Branch on `AUDIT_RC` — distinguish unreadable doc from FAIL verdict:
   ```
   if (( AUDIT_RC == 2 )); then
     log_error "design-doc unreadable; aborting."
     "$CLAUDE_PLUGIN_ROOT/bin/execute-design-archive.sh" "$TOPIC"
     exit 1
   elif (( AUDIT_RC == 1 )); then
     # Audit FAIL — read the design doc yourself, weigh the flagged issues, then:
     # AskUserQuestion (options: "Proceed anyway", "Abort and edit doc").
     # Abort → bin/execute-design-archive.sh "$TOPIC" + exit 1
     # Proceed → continue.
     :
   fi
   ```

Set task `0` → `completed`.

### Step 1.1 — Spawn cody-codex

Set task `1.1` → `in_progress`.
```
"$CLAUDE_PLUGIN_ROOT/bin/spawn.sh" cody codex "$TOPIC"
```
Set task `1.1` → `completed`. If spawn fails, archive `_execute/` and exit.

### Step 1.2 — Plan

Set task `1.2` → `in_progress`.
```
"$CLAUDE_PLUGIN_ROOT/bin/execute-design-plan-send.sh" "$TOPIC"
"$CLAUDE_PLUGIN_ROOT/bin/execute-design-plan-wait.sh" "$TOPIC"
```
Read the last `PS=` line from `$ART_DIR/plan-cody.txt`:
- `PS=ok` → set task `1.2` → `completed`.
- `PS=failed`/`PS=timeout` → AskUserQuestion (Retry / Abort).
  - Retry recipe (clear sentinel + state file, then re-run send + wait):
    ```
    rm -f "$ART_DIR/plan-cody.txt" "$ART_DIR/plan-cody.done"
    "$CLAUDE_PLUGIN_ROOT/bin/execute-design-plan-send.sh" "$TOPIC"
    "$CLAUDE_PLUGIN_ROOT/bin/execute-design-plan-wait.sh" "$TOPIC"
    ```
  - Abort: teardown + archive + exit.

Note: a `bin/send.sh` failure during dispatch surfaces here as `PS=timeout`;
use the same Retry recipe.

**Yoda does not read `plan.md`.**

### Step 1.3 — Implement

Set task `1.3` → `in_progress`.

**Skill (cody-side):** the implement prompt binds cody to
`superpowers:subagent-driven-development` to walk plan.md task-by-task.
```
"$CLAUDE_PLUGIN_ROOT/bin/execute-design-implement-send.sh" "$TOPIC"
"$CLAUDE_PLUGIN_ROOT/bin/execute-design-implement-wait.sh" "$TOPIC"
```
Read `IS=` from `implement-cody.txt`:
- `IS=ok` → set task `1.3` → `completed`.
- `IS=failed`/`IS=timeout` → read last 30 lines of cody outbox; AskUserQuestion
  (Retry / Hand-off / Abort).
  - Retry recipe:
    ```
    rm -f "$ART_DIR/implement-cody.txt" "$ART_DIR/implement-cody.done"
    "$CLAUDE_PLUGIN_ROOT/bin/execute-design-implement-send.sh" "$TOPIC"
    "$CLAUDE_PLUGIN_ROOT/bin/execute-design-implement-wait.sh" "$TOPIC"
    ```

Note: codex's question protocol is NOT wired in v0.6. If codex emits a question
event, the wait-script will time out (only matches `done|error`). Surfaces as
`IS=timeout` — handle via the Retry recipe above.

Note: a `bin/send.sh` failure during dispatch surfaces here as `IS=timeout`;
use the same Retry recipe.

### Step 2 — Verify-fix loop

Initialize:
```
ROUND=1
MAX_ROUNDS="${MAX_ROUNDS_OVERRIDE:-5}"
```

Loop while `ROUND <= MAX_ROUNDS + 1`:

<!-- +1 means round 6 hits the "exhaustion" AskUserQuestion branch; without +1, round 5's FAIL would silently exit the loop without asking. -->


#### Step 2.1 — Self-verify (per round)

Set task `2.1` → `in_progress` (use the same task across rounds; only the
activeForm reflects round number).
```
"$CLAUDE_PLUGIN_ROOT/bin/execute-design-verify-send.sh" "$TOPIC" "$ROUND"
"$CLAUDE_PLUGIN_ROOT/bin/execute-design-verify-wait.sh" "$TOPIC" "$ROUND"
```
Read `VS=` from `verify-cody-$ROUND.txt`. On non-`ok` status, AskUserQuestion
(Retry / Hand-off / Abort).
- Retry recipe (round N):
  ```
  rm -f "$ART_DIR/verify-cody-$ROUND.txt" "$ART_DIR/verify-cody-$ROUND.done"
  "$CLAUDE_PLUGIN_ROOT/bin/execute-design-verify-send.sh" "$TOPIC" "$ROUND"
  "$CLAUDE_PLUGIN_ROOT/bin/execute-design-verify-wait.sh" "$TOPIC" "$ROUND"
  ```

Note: codex's question protocol is NOT wired in v0.6. If codex emits a question
event, the wait-script will time out (only matches `done|error`). Surfaces as
`VS=timeout` — handle via the Retry recipe above.

Note: a `bin/send.sh` failure during dispatch surfaces here as `VS=timeout`;
use the same Retry recipe.

Set task `2.1` → `completed` for this round.

#### Step 2.2 — Cross-verify (per round)

Set task `2.2` → `in_progress`.

**Skill:** invoke `superpowers:verification-before-completion`.

Yoda's reads (capped):
- `$ART_DIR/verify-report-$ROUND.md`
- `$ART_DIR/test-output-$ROUND.log` (grep tail for pass/fail counts)
- `git log --oneline "$BRANCH_BASE"..HEAD`
- `git diff --stat "$BRANCH_BASE"..HEAD`
- Up to 3 spot-checks: pick the highest-stakes diff hunk per critical
  requirement and Read just that hunk.

(`$BRANCH_BASE` was captured into `$ART_DIR/branch-base.sha` in Step 0.)

Write the verdict to `$ART_DIR/cross-verify-$ROUND.md`:
- Top-line `VERDICT: PASS` or `VERDICT: FAIL`.
- If FAIL: bullet list of issues, each tagged `[bug]`, `[regression]`, or
  `[spec-gap]`, with (a) requirement reference, (b) evidence (file:line or
  commit), (c) suggested fix direction.

If `VERDICT: PASS` → set task `2.2` → `completed`, exit the loop, jump to
Step 4.

If `VERDICT: FAIL` and `ROUND > MAX_ROUNDS`:
- Write `$ART_DIR/RESUME.md` with the topic dir, branch name, latest
  cross-verify summary, and instructions for manual takeover.
- AskUserQuestion: "5 fix rounds exhausted. Continue (1 more round) /
  Hand off (preserve state) / Abort (teardown + archive)." Default: hand off.
- Hand off: log the topic dir + RESUME.md path, exit (do not teardown). Set
  task `3` → `completed` and task `4` → `completed` with note.
- Abort: teardown + archive, exit.
- Continue: increment `MAX_ROUNDS` by 1 and continue the loop.

If `VERDICT: FAIL` and `ROUND <= MAX_ROUNDS` → continue to Step 3.

#### Step 3 — Fix-prompt + dispatch

Set task `3` → `in_progress`.

Group issues from `cross-verify-$ROUND.md` by tag:
- `[bug]` and `[regression]` → bundle preamble names
  `superpowers:systematic-debugging`.
- `[spec-gap]` → bundle preamble names `superpowers:writing-plans` (replan)
  → then implement.

If the cross-verify mixes both, write **two** files:
- `$ART_DIR/fix-prompt-$ROUND-debug.md` (bugs/regressions)
- `$ART_DIR/fix-prompt-$ROUND-gap.md` (spec gaps)

If only one classification, write a single `$ART_DIR/fix-prompt-$ROUND.md`.

Each file's preamble (one short paragraph at the top) must:
- Name the required skill (`superpowers:systematic-debugging` or
  `superpowers:writing-plans`).
- Tell codex to commit per fix and re-run the full test suite after each.
- Forbid skipping any listed issue.

Then dispatch sequentially. **If both bundles exist, you MUST wait for the
debug bundle's `done` event in the outbox before dispatching the gap bundle**
— otherwise gap's inbox.md write races with debug consumption and codex
silently drops the bug-fix prompt.

Source the IPC helpers inline (the wait function is already defined there):
```
source "$CLAUDE_PLUGIN_ROOT/lib/state.sh"
source "$CLAUDE_PLUGIN_ROOT/lib/ipc.sh"
OUTBOX="$(cw_trooper_dir cody codex "$TOPIC")/outbox.jsonl"
```

Dispatch debug bundle (if any):
```
# Capture pre-send byte offset so the wait matches THIS dispatch's done event,
# not a stale prior event.
OFFSET=$( [[ -f "$OUTBOX" ]] && wc -c < "$OUTBOX" || echo 0 )
"$CLAUDE_PLUGIN_ROOT/bin/execute-design-fix-send.sh" "$TOPIC" "$ROUND" debug

# Wait for codex to finish the debug bundle before sending gap.
# Timeout 1200s mirrors the implement-wait default; tune if your suite is slow.
cw_outbox_wait_since cody codex "$TOPIC" "$OFFSET" done error 1200 || true
# Read the matched event from the outbox (line at $OFFSET-onwards). If it's
# 'error' or the wait timed out, AskUserQuestion (Continue with gap / Abort).
# If 'done', proceed to gap.
```

Dispatch gap bundle (if any):
```
# Capture pre-send byte offset BEFORE the gap-send fires, so the wait
# matches THIS dispatch's done event (mirrors the debug-bundle pattern).
GAP_OFFSET=$( [[ -f "$OUTBOX" ]] && wc -c < "$OUTBOX" || echo 0 )
"$CLAUDE_PLUGIN_ROOT/bin/execute-design-fix-send.sh" "$TOPIC" "$ROUND" gap

# Wait for codex to finish the gap bundle before incrementing ROUND.
# Without this wait, the next verify-send (Step 2.1) races with codex's
# inbox.md read of the gap prompt and silently overwrites it.
cw_outbox_wait_since cody codex "$TOPIC" "$GAP_OFFSET" done error 1200 || true
# Read the matched event; if 'error' or the wait timed out, AskUserQuestion
# (Continue to verify / Abort). If 'done', proceed.
```

Increment `ROUND`. Loop back to Step 2.1 (which dispatches verify-send for
the new round).

### Step 4 — Teardown + archive

Set task `4` → `in_progress`.
```
"$CLAUDE_PLUGIN_ROOT/bin/execute-design-teardown.sh" "$TOPIC"
"$CLAUDE_PLUGIN_ROOT/bin/execute-design-archive.sh" "$TOPIC"
```

Print final summary to the user:
- Branch name (with commit count from `git log --oneline "$BRANCH_BASE"..HEAD`).
- Final cross-verify verdict (PASS or hand-off note).
- Archive path.

Set task `4` → `completed`.

## Intervention patterns

### Abandoned run cleanup
If a previous run wedged (panes alive, state intact), tear down explicitly:
```
"$CLAUDE_PLUGIN_ROOT/bin/execute-design-teardown.sh" <topic>
"$CLAUDE_PLUGIN_ROOT/bin/execute-design-archive.sh" <topic>
```

### Manual takeover (after hand-off)
The cody pane stays alive after a 5-round hand-off. Attach:
```
tmux select-pane -t <pane_id>   # printed by spawn.sh
```
Use the cody session directly. RESUME.md in `$ART_DIR/` documents context.

### Auto-created branch survives audit-FAIL and spawn-FAIL
If the audit or spawn fails, the directive aborts and archives `_execute/`
but the auto-created `feat/exec-<topic>` branch is left in place. Clean up
manually if undesired:
```
git checkout - && git branch -D feat/exec-<topic>
```
