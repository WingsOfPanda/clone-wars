---
description: Show active troopers (panes + state); optionally scoped to a topic
argument-hint: [<topic>]
allowed-tools: Bash, Write
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
| `stale` | trooper was `working` but its `outbox.jsonl` hasn't been written to in more than `CW_STALE_THRESHOLD_S` seconds (default `180`). Display-only; the trooper may still be doing useful work, just silently. Override the threshold via `CW_STALE_THRESHOLD_S=<seconds>`. |
| `idle (done)` | last task completed cleanly |
| `idle (error)` | last task failed; trooper still alive |
| `[ORPHAN]` | state dir exists but the recorded pane is dead — run teardown |

## Steps

The user's `$ARGUMENTS` may contain shell metacharacters. To prevent injection, we keep it out of any bash source: write it via the Write tool (a literal string parameter), then invoke the bin script with `--args-file`.

1. Use the Bash tool to resolve a unique args-file path (v0.31.0: project-local
   + mktemp per invocation so parallel sessions don't collide):

   ```
   source "$CLAUDE_PLUGIN_ROOT/lib/state.sh"
   ARGS_DIR="$(cw_state_root)/_args"
   mkdir -p "$ARGS_DIR"
   mktemp -p "$ARGS_DIR" -t 'list.XXXXXX'
   ```

   The script prints the absolute path; remember it for steps 2 and 3.

2. Use the Write tool to put `$ARGUMENTS` into that path:

   - `file_path`: the path printed by step 1 (an absolute path under `<conductor-cwd>/.clone-wars/_args/`).
   - `content`: the literal value of `$ARGUMENTS` (the slash-command argument string, exactly as the user typed it).

   IMPORTANT: do NOT echo, printf, or otherwise quote `$ARGUMENTS` into a shell command — pass it directly as the Write tool's `content` parameter. This is the entire reason for the Write step.

3. Use the Bash tool to invoke list. Pass the path printed by step 1 as the `--args-file` arg (the script consumes + deletes it via `cw_args_file_consume`):

   ```
   "${CLAUDE_PLUGIN_ROOT}/bin/list.sh" --args-file <ARGS_PATH-from-step-1>
   ```

4. Show the script's output to the user verbatim.
