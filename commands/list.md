---
description: Show active troopers (RUNTIME PENDING — see roadmap)
argument-hint: [<topic>]
allowed-tools: Bash
---

# /clone-wars:list

Show the active troopers (panes + state). With no argument, lists every active trooper
across every topic; with `<topic>` arg, scopes to that topic.

**Note:** in v0.0.1-pre1 this command is a stub. The runtime ships in v0.0.1 after the
tracer-bullet validates tmux + IPC mechanics. Spec: `docs/DESIGN.md` §`/clone-wars-list`.

## Steps

1. Use the Bash tool to run:

   ```
   "${CLAUDE_PLUGIN_ROOT}/bin/list.sh" $ARGUMENTS
   ```

2. Show the script's output to the user verbatim.
