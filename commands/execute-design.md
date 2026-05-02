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
`state/<repo-hash>/consult-*/synthesis.md` under `$CLONE_WARS_HOME` and prompt
the user via `AskUserQuestion` to confirm. If no synthesis.md is found and no
explicit path was given, refuse with a usage hint.

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
2. Write tool: `file_path` = the path printed; `content` = `$ARGUMENTS` exactly.
3. Parse `--source <path>`, `--topic <slug>`, `--no-branch`, `--branch <name>`,
   `--max-rounds <n>` (default 5) from the args file. The remaining positional
   token (if any) is the design-doc path.
4. If no design-doc path is given, find the most recent
   `state/$REPO_HASH/consult-*/synthesis.md` and offer it via
   `AskUserQuestion` (options: "Use this", "Cancel"). Cancel → exit 0.
5. Init:
   ```
   source "$CLAUDE_PLUGIN_ROOT/lib/state.sh"
   REPO_HASH=$(cw_repo_hash)
   TOPIC=$("$CLAUDE_PLUGIN_ROOT/bin/execute-design-init.sh" \
              ${NO_BRANCH:+--no-branch} \
              ${BRANCH_OVERRIDE:+--branch "$BRANCH_OVERRIDE"} \
              ${TOPIC_OVERRIDE:+--topic "$TOPIC_OVERRIDE"} \
              "$DESIGN_PATH")
   TOPIC_DIR="${CLONE_WARS_HOME:-$HOME/.clone-wars}/state/$REPO_HASH/$TOPIC"
   ART_DIR="$TOPIC_DIR/_execute"
   ```
6. Run audit and persist verdict:
   ```
   source "$CLAUDE_PLUGIN_ROOT/lib/execute_design.sh"
   AUDIT=$(cw_execute_design_audit_doc "$ART_DIR/design.md" 2>&1) && AUDIT_RC=0 || AUDIT_RC=$?
   printf '%s\n' "$AUDIT" > "$ART_DIR/design-audit.md"
   ```
7. If `AUDIT_RC != 0`: read the design doc yourself, weigh the flagged issues,
   and use `AskUserQuestion` (options: "Proceed anyway", "Abort and edit doc").
   Abort → run `bin/execute-design-archive.sh` and exit. Proceed → continue.

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
- `PS=failed`/`PS=timeout` → AskUserQuestion (Retry / Abort). Retry: `rm
  $ART_DIR/plan-cody.txt $ART_DIR/plan-cody.done` then re-run the two
  scripts. Abort: teardown + archive + exit.

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
  (Retry / Hand-off / Abort). Retry: same pattern as plan.

### Step 2 — Verify-fix loop

Initialize:
```
ROUND=1
MAX_ROUNDS="${MAX_ROUNDS_OVERRIDE:-5}"
```

Loop while `ROUND <= MAX_ROUNDS + 1`:

#### Step 2.1 — Self-verify (per round)

Set task `2.1` → `in_progress` (use the same task across rounds; only the
activeForm reflects round number).
```
"$CLAUDE_PLUGIN_ROOT/bin/execute-design-verify-send.sh" "$TOPIC" "$ROUND"
"$CLAUDE_PLUGIN_ROOT/bin/execute-design-verify-wait.sh" "$TOPIC" "$ROUND"
```
Read `VS=` from `verify-cody-$ROUND.txt`. On non-`ok` status, AskUserQuestion
the same way as the implement phase.

Set task `2.1` → `completed` for this round.

#### Step 2.2 — Cross-verify (per round)

Set task `2.2` → `in_progress`.

**Skill:** invoke `superpowers:verification-before-completion`.

Yoda's reads (capped):
- `$ART_DIR/verify-report-$ROUND.md`
- `$ART_DIR/test-output-$ROUND.log` (grep tail for pass/fail counts)
- `git log --oneline <branch-base>..HEAD`
- `git diff --stat <branch-base>..HEAD`
- Up to 3 spot-checks: pick the highest-stakes diff hunk per critical
  requirement and Read just that hunk.

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

Then dispatch (in order — debug first if both):
```
# debug bundle (if any)
"$CLAUDE_PLUGIN_ROOT/bin/execute-design-fix-send.sh" "$TOPIC" "$ROUND" debug
# wait for done by re-running the verify-wait — but verify-wait
# expects its own state file. The fix-send doesn't update VS=; instead,
# we wait by polling the outbox for the next done event past the current
# OFFSET. Simplest path: re-run the verify cycle for round N+1.

# gap bundle (if any)
"$CLAUDE_PLUGIN_ROOT/bin/execute-design-fix-send.sh" "$TOPIC" "$ROUND" gap
```

Increment `ROUND`. Loop back to Step 2.1 (which dispatches verify-send for
the new round; codex's done event from the fix is consumed by the next
verify-wait).

### Step 4 — Teardown + archive

Set task `4` → `in_progress`.
```
"$CLAUDE_PLUGIN_ROOT/bin/execute-design-teardown.sh" "$TOPIC"
"$CLAUDE_PLUGIN_ROOT/bin/execute-design-archive.sh" "$TOPIC"
```

Print final summary to the user:
- Branch name (with commit count from `git log --oneline <base>..HEAD`).
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
