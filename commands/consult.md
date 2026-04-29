---
description: Spawn rex+codex and cody+claude on a topic; cross-verify their findings; synthesize a final report
argument-hint: <topic — what to research>
---

# /clone-wars:consult

Run a cross-verified dual-model investigation on `$ARGUMENTS`. The conductor
spawns one codex pane (`rex`) and one claude pane (`cody`), dispatches an
independent research task to each, diffs their findings via citation overlap,
dispatches each side's unique claims to the OTHER trooper for AGREE / DISPUTE /
UNCERTAIN verification (using the SAME pane — TUI memory carries between
calls), then makes the conductor adjudicate disputed items by reading the
cited sources directly.

Both panes stay attached for the entire run — `tmux select-pane` to watch.

Spec: `docs/superpowers/specs/2026-04-28-clone-wars-consult-design.md`

## Task list (use TaskCreate × 13 BEFORE step 1)

Before running anything, create a 13-item task list using the harness's
`TaskCreate` tool. The harness pins the list to the bottom of the user's
terminal and re-renders it in place as you call `TaskUpdate` — the user sees
the whole arc up front and watches items tick off without scrolling chat.

**Do not** print a markdown checklist in chat. The `TaskCreate` / `TaskUpdate`
tools are how this list is shown.

### Step 0 — create the 13 tasks (in this order)

For each row below, call `TaskCreate` with the given `subject` and
`activeForm`. Description can be empty — keep the subject short and
greppable. Note the returned task IDs; you'll need them for `TaskUpdate`.

| # | subject | activeForm |
|---|---|---|
| 0   | `0   Stage args-file [conductor]`               | `Staging args-file` |
| 1.1 | `1.1 Spawn rex (codex) [conductor]`             | `Spawning rex` |
| 1.2 | `1.2 Spawn cody (claude) [conductor]`           | `Spawning cody` |
| 1.3 | `1.3 Research [rex/codex]`                      | `Rex researching` |
| 1.4 | `1.4 Research [cody/claude]`                    | `Cody researching` |
| 1.5 | `1.5 Diff findings [conductor]`                 | `Diffing findings` |
| 1.6 | `1.6 Cross-verify cody-only items [rex/codex]`  | `Rex verifying` |
| 1.7 | `1.7 Cross-verify rex-only items [cody/claude]` | `Cody verifying` |
| 2   | `2   Resolve PENDING items [conductor]`         | `Resolving PENDING items` |
| 3.1 | `3.1 Synthesize report [conductor]`             | `Synthesizing` |
| 3.2 | `3.2 Teardown panes [conductor]`                | `Tearing down` |
| 3.3 | `3.3 Archive _consult/ [conductor]`             | `Archiving` |
| 4   | `4   Present final synthesis [conductor]`       | `Presenting synthesis` |

The actor column on each subject reflects who *does the work* —
`bin/consult.sh` and `bin/consult-finalize.sh` are tools the conductor runs,
not actors. Only the two troopers (rex and cody) appear as non-conductor
actors, on the four items that genuinely happen inside their TUI sessions.

### Status updates (call TaskUpdate at these boundaries)

The bin scripts cover multiple checklist items each, so you can't tick every
sub-item live mid-run. Instead, mark items in batches at four observable
boundaries:

| Boundary | `TaskUpdate(taskId, status)` calls |
|---|---|
| Right before invoking `bin/consult.sh` | `0` → `in_progress` (already done implicitly), then immediately `0` → `completed`; `1.1` → `in_progress` |
| `bin/consult.sh` returns rc=0 | `1.1`–`1.7` → `completed`; `2` → `in_progress` |
| `adjudicated.md` has no `^- PENDING:` (you finished the Edit pass) | `2` → `completed`; `3.1` → `in_progress` |
| `bin/consult-finalize.sh` returns rc=0 | `3.1`–`3.3` → `completed`; `4` → `in_progress` |
| Final synthesis presented | `4` → `completed` |

You may set the *currently-running* item to `in_progress` more granularly if
you want a livelier spinner — for instance, before staging the args-file set
`0` → `in_progress`, after Write succeeds set `0` → `completed`. The
batch-completion boundaries above are the minimum required.

If anything fails partway (spawn error, research timeout, finalize refuses on
PENDING), update only the items that genuinely completed; leave the rest
`pending` or `in_progress`. Do not tick optimistically.

## Steps

The user's `$ARGUMENTS` may contain shell metacharacters. Write it via the
Write tool, then invoke the bin script with `--args-file`.

1. Set task `0` → `in_progress`. Use the Bash tool to resolve the args-file
   path:

   ```
   ARGS_DIR="${CLONE_WARS_HOME:-$HOME/.clone-wars}/_args"
   mkdir -p "$ARGS_DIR"
   echo "$ARGS_DIR/consult.txt"
   ```

2. Use the Write tool to put `$ARGUMENTS` into that path:

   - `file_path`: the absolute path printed by step 1
   - `content`: the literal value of `$ARGUMENTS`

   When Write succeeds, set task `0` → `completed` and task `1.1` →
   `in_progress`.

3. Use the Bash tool to run consult Phases 1–5:

   ```
   "$CLAUDE_PLUGIN_ROOT/bin/consult.sh" --args-file "$ARGS_DIR/consult.txt"
   ```

   The script ends by printing the path to `adjudicated.md` and the path to
   `bin/consult-finalize.sh`. **Do not finalize yet.**

   On rc=0, set tasks `1.1`–`1.7` → `completed` and task `2` → `in_progress`.

4. **CONDUCTOR RESPONSIBILITY — resolve PENDING items before finalizing.**

   Open the printed `adjudicated.md` with the Read tool. For every line that
   begins with `- PENDING:`:

   a. Note the citation in `[brackets]` and the original claim.
   b. Open the cited source (file at the path, or fetch the URL via WebFetch).
   c. Decide:
      - **CONFIRMED** — the original claim is correct.
      - **REFUTED**   — the original claim is wrong.
      - **CONTESTED** — the source is genuinely ambiguous.
   d. Use the Edit tool to rewrite the line:
      - For CONFIRMED / REFUTED: replace `- PENDING:` with `- CONFIRMED:` or
        `- REFUTED:`, append a one-line evidence note (the file:line or quote
        you read).
      - For CONTESTED: move the entire line under `## Contested` and drop the
        `PENDING:` prefix.

   When done, no `^- PENDING:` line should remain. Set task `2` →
   `completed` and task `3.1` → `in_progress`.

5. Use the Bash tool to finalize:

   ```
   "$CLAUDE_PLUGIN_ROOT/bin/consult-finalize.sh" <consult-topic>
   ```

   Replace `<consult-topic>` with the topic the previous output printed (e.g.
   `consult-review-auth`). The script will refuse to run if any `^- PENDING:`
   line remains — that's the enforcement gate that prevents shipping a stale
   report.

   On rc=0, set tasks `3.1`–`3.3` → `completed` and task `4` → `in_progress`.

6. Show the user the final synthesis (already printed by the finalize script).
   Do NOT show the draft from step 3 as the final answer; the user only sees
   the synthesis from step 5. Set task `4` → `completed`.

## What the user should expect

Two tmux panes spawn, do their research, swap verify items, then teardown.
The conductor (you) does the source-reading adjudication step in step 4.
End-to-end this takes 10–20 minutes for a non-trivial topic; longer for
complex ones (default research timeout is 600s per side).
