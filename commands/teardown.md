---
description: Kill panes and archive state (RUNTIME PENDING — see roadmap)
argument-hint: [<commander>] [<topic>] [--all]
allowed-tools: Bash
---

# /clone-wars:teardown

Kill clone-trooper panes and archive their state.

**Note:** in v0.0.1-pre1 this command is a stub. The runtime ships in v0.0.1 after the
tracer-bullet validates tmux + IPC mechanics. Spec: `docs/DESIGN.md` §`/clone-wars-teardown`.

## Steps

1. Use the Bash tool to run:

   ```
   "${CLAUDE_PLUGIN_ROOT}/bin/teardown.sh" $ARGUMENTS
   ```

2. Show the script's output to the user verbatim.
