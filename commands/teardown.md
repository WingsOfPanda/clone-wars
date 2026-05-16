---
description: Gracefully kill trooper panes (8s colored banner) and archive their state
argument-hint: <topic> | <commander> <topic> | --all
allowed-tools: Bash, Write
---

# /clone-wars:teardown

Gracefully shut down trooper panes and archive their state for forensics.

Three modes:

- `<topic>` — tear down every trooper on `<topic>` (the most common case).
- `<commander> <topic>` — tear down just that one trooper.
- `--all` — tear down EVERY trooper across every topic in this repo (asks confirmation).

Each pane gets the colored "MISSION ACCOMPLISHED" banner with an 8-second countdown
(in the trooper's Morandi color) before it actually closes — so you have time to read
the final state. State directories are moved to
`$CLONE_WARS_HOME/archive/<repo-hash>/<topic>/<commander>-<model>-<timestamp>/` so
deploys driven by Clone Wars stay forensically reconstructable.

## Steps

The user's `$ARGUMENTS` may contain shell metacharacters. To prevent injection, we keep it out of any bash source: write it via the Write tool (a literal string parameter), then invoke the bin script with `--args-file`.

1. Use the Bash tool to resolve a unique args-file path (v0.31.0: project-local
   + mktemp per invocation so parallel sessions don't collide):

   ```
   source "${CLAUDE_PLUGIN_ROOT}/lib/state.sh"
   ARGS_DIR="$(cw_state_root)/_args"
   mkdir -p "$ARGS_DIR"
   mktemp -p "$ARGS_DIR" -t 'teardown.XXXXXX'
   ```

   The script prints the absolute path; remember it for steps 2 and 3.

2. Use the Write tool to put `$ARGUMENTS` into that path:

   - `file_path`: the path printed by step 1 (an absolute path under `<conductor-cwd>/.clone-wars/_args/`).
   - `content`: the literal value of `$ARGUMENTS` (the slash-command argument string, exactly as the user typed it).

   IMPORTANT: do NOT echo, printf, or otherwise quote `$ARGUMENTS` into a shell command — pass it directly as the Write tool's `content` parameter. This is the entire reason for the Write step.

3. Use the Bash tool to invoke teardown. Pass the path printed by step 1 as the `--args-file` arg (the script consumes + deletes it via `cw_args_file_consume`):

   ```
   "${CLAUDE_PLUGIN_ROOT}/bin/teardown.sh" --args-file <ARGS_PATH-from-step-1>
   ```

4. Show the script's output to the user verbatim. The script blocks for ~9 seconds while the graceful banner countdown runs, so the response will be a beat slower than the other commands — this is normal.
