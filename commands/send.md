---
description: Write a task to a trooper's inbox and nudge the pane to read it
argument-hint: [--from <sender>] <commander> <topic> <message-or-@file>
allowed-tools: Bash, Write
---

# /clone-wars:send

Write a task to a trooper's inbox and nudge the pane to read it.

- `commander` — must already be deployed on `topic` (via `/clone-wars:spawn`).
- `topic` — the operation slug.
- `message-or-@file` — literal text (multi-word OK; the rest of the line is one task) OR
  `@<path>` to inline a file as the task body. The script appends the
  `END_OF_INSTRUCTION` sentinel automatically.
- `--from <sender>` (optional, default `master-yoda`) — sets the sender attribution. Recipients see `From: <sender>` as the first line of the inbox message. Use this when relaying messages between troopers (e.g., `--from cody`) to make the source clear in the trooper's identity-template-aware parsing. Sender names must match `^[a-zA-Z0-9_-]+$`.

The trooper's pane is identified by `pane.json` (written at spawn time). If the recorded
pane has died, send fails with an [ORPHAN] message and a hint to teardown.

This is fire-and-forget — pair with `/clone-wars:collect` to wait for `{done}`.

## Steps

The user's `$ARGUMENTS` may contain shell metacharacters. To prevent injection, we keep it out of any bash source: write it via the Write tool (a literal string parameter), then invoke the bin script with `--args-file`.

1. Use the Bash tool to resolve the args-file path:

   ```
   ARGS_DIR="${CLONE_WARS_HOME:-$HOME/.clone-wars}/_args"
   mkdir -p "$ARGS_DIR"
   echo "$ARGS_DIR/send.txt"
   ```

   The script prints the absolute path; remember it for steps 2 and 3.

2. Use the Write tool to put `$ARGUMENTS` into that path:

   - `file_path`: the path printed by step 1 (an absolute path under `~/.clone-wars/_args/`).
   - `content`: the literal value of `$ARGUMENTS` (the slash-command argument string, exactly as the user typed it).

   IMPORTANT: do NOT echo, printf, or otherwise quote `$ARGUMENTS` into a shell command — pass it directly as the Write tool's `content` parameter. This is the entire reason for the Write step.

3. Use the Bash tool to invoke send:

   ```
   "${CLAUDE_PLUGIN_ROOT}/bin/send.sh" --args-file "${CLONE_WARS_HOME:-$HOME/.clone-wars}/_args/send.txt"
   ```

4. Show the script's output to the user verbatim.
