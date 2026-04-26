---
description: Write a task to a trooper's inbox and nudge the pane to read it
argument-hint: <commander> <topic> <message-or-@file>
allowed-tools: Bash
---

# /clone-wars:send

Write a task to a trooper's inbox and nudge the pane to read it.

- `commander` — must already be deployed on `topic` (via `/clone-wars:spawn`).
- `topic` — the operation slug.
- `message-or-@file` — literal text (multi-word OK; the rest of the line is one task) OR
  `@<path>` to inline a file as the task body. The script appends the
  `END_OF_INSTRUCTION` sentinel automatically.

The trooper's pane is identified by `pane.json` (written at spawn time). If the recorded
pane has died, send fails with an [ORPHAN] message and a hint to teardown.

This is fire-and-forget — pair with `/clone-wars:collect` to wait for `{done}`.

## Steps

1. Use the Bash tool to run:

   ```
   "${CLAUDE_PLUGIN_ROOT}/bin/send.sh" $ARGUMENTS
   ```

2. Show the script's output to the user verbatim.
