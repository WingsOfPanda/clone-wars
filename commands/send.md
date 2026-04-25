---
description: Write to a trooper's inbox and nudge it (RUNTIME PENDING — see roadmap)
argument-hint: <commander> <topic> <message-or-@file>
allowed-tools: Bash
---

# /clone-wars:send

Write a message to a trooper's inbox and nudge the pane to read it.

**Note:** in v0.0.1-pre1 this command is a stub. The runtime ships in v0.0.1 after the
tracer-bullet validates tmux + IPC mechanics. Spec: `docs/DESIGN.md` §`/clone-wars-send`.

## Steps

1. Use the Bash tool to run:

   ```
   "${CLAUDE_PLUGIN_ROOT}/bin/send.sh" $ARGUMENTS
   ```

2. Show the script's output to the user verbatim.
