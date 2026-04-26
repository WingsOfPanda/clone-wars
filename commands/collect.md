---
description: Block until a trooper reports done/error in outbox.jsonl (RUNTIME PENDING)
argument-hint: <commander> <topic> [--timeout <sec>]
allowed-tools: Bash
---

# /clone-wars:collect

Block until a trooper reports `done` or `error`, then print the summary.

**Note:** in v0.0.1-pre1 this command is a stub. The runtime ships in v0.0.1 after the
tracer-bullet validates tmux + IPC mechanics. Spec: `docs/DESIGN.md` §`/clone-wars-collect`.

## Steps

1. Use the Bash tool to run:

   ```
   "${CLAUDE_PLUGIN_ROOT}/bin/collect.sh" $ARGUMENTS
   ```

2. Show the script's output to the user verbatim.
