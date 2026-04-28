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

## Steps

The user's `$ARGUMENTS` may contain shell metacharacters. Write it via the
Write tool, then invoke the bin script with `--args-file`.

1. Use the Bash tool to resolve the args-file path:

   ```
   ARGS_DIR="${CLONE_WARS_HOME:-$HOME/.clone-wars}/_args"
   mkdir -p "$ARGS_DIR"
   echo "$ARGS_DIR/consult.txt"
   ```

2. Use the Write tool to put `$ARGUMENTS` into that path:

   - `file_path`: the absolute path printed by step 1
   - `content`: the literal value of `$ARGUMENTS`

3. Use the Bash tool to run consult Phases 1–5:

   ```
   "$CLAUDE_PLUGIN_ROOT/bin/consult.sh" --args-file "$ARGS_DIR/consult.txt"
   ```

   The script ends by printing the path to `adjudicated.md` and the path to
   `bin/consult-finalize.sh`. **Do not finalize yet.**

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

   When done, no `^- PENDING:` line should remain.

5. Use the Bash tool to finalize:

   ```
   "$CLAUDE_PLUGIN_ROOT/bin/consult-finalize.sh" <consult-topic>
   ```

   Replace `<consult-topic>` with the topic the previous output printed (e.g.
   `consult-review-auth`). The script will refuse to run if any `^- PENDING:`
   line remains — that's the enforcement gate that prevents shipping a stale
   report.

6. Show the user the final synthesis (already printed by the finalize script).
   Do NOT show the draft from step 3 as the final answer; the user only sees
   the synthesis from step 5.

## What the user should expect

Two tmux panes spawn, do their research, swap verify items, then teardown.
The conductor (you) does the source-reading adjudication step in step 4.
End-to-end this takes 10–20 minutes for a non-trivial topic; longer for
complex ones (default research timeout is 600s per side).
