---
description: Spawn a clone trooper as a tmux pane (RUNTIME PENDING — see roadmap)
argument-hint: <commander> <model> <topic> [--mode full|read-only] [initial-prompt]
allowed-tools: Bash
---

# /clone-wars:spawn

Spawn a clone trooper as a tmux pane.

**Note:** in v0.0.1-pre1 this command is a stub. The runtime ships in v0.0.1 after the
tracer-bullet validates tmux + IPC mechanics. The spec is in `docs/DESIGN.md` §Slash
commands → `/clone-wars-spawn`.

## Steps

1. Use the Bash tool to run, passing through `$ARGUMENTS`:

   ```
   "${CLAUDE_PLUGIN_ROOT}/bin/spawn.sh" $ARGUMENTS
   ```

2. Show the script's output to the user verbatim. It explains that the runtime is pending
   and points to `/clone-wars:medic` and `docs/DESIGN.md`.

3. If the user asks why this isn't working yet, summarize: "Clone Wars v0.0.1-pre1 ships the
   marketplace shell + medic. The runtime commands (spawn/send/collect/list/teardown) become
   real in v0.0.1 once the tracer-bullet validates tmux/IPC mechanics — see CLAUDE.md status."
