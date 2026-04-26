---
description: Show active troopers (panes + state); optionally scoped to a topic
argument-hint: [<topic>]
allowed-tools: Bash
---

# /clone-wars:list

Show every active trooper across topics, or scope to a single topic.

For each trooper the table shows: commander, model, topic, pane id, and state derived
from the last outbox event:

| State | Means |
|---|---|
| `spawning` | pane created but trooper hasn't emitted any event yet |
| `ready` | trooper read identity, idle waiting for inbox |
| `working` | trooper acked an inbox; task in progress |
| `idle (done)` | last task completed cleanly |
| `idle (error)` | last task failed; trooper still alive |
| `[ORPHAN]` | state dir exists but the recorded pane is dead — run teardown |

## Steps

1. Use the Bash tool to run:

   ```
   "${CLAUDE_PLUGIN_ROOT}/bin/list.sh" $ARGUMENTS
   ```

2. Show the script's output to the user verbatim.
