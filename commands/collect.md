---
description: Block until a trooper reports done or error in outbox.jsonl
argument-hint: <commander> <topic> [--timeout <seconds>]
allowed-tools: Bash, Write
---

# /clone-wars:collect

Block until the named trooper reports `{done}` (success) or `{error}` (failure) in its
outbox.jsonl, then print the matching JSON line.

- `commander` `topic` — same identifiers used at spawn.
- `--timeout` — seconds to wait, default 600.

Exits 0 on `{done}` and 1 on `{error}` or timeout, so Master Yoda can chain commands.

## Steps

The user's `$ARGUMENTS` may contain shell metacharacters. To prevent injection, we keep it out of any bash source: write it via the Write tool (a literal string parameter), then invoke the bin script with `--args-file`.

1. Use the Bash tool to resolve the args-file path:

   ```
   ARGS_DIR="${CLONE_WARS_HOME:-$HOME/.clone-wars}/_args"
   mkdir -p "$ARGS_DIR"
   echo "$ARGS_DIR/collect.txt"
   ```

   The script prints the absolute path; remember it for steps 2 and 3.

2. Use the Write tool to put `$ARGUMENTS` into that path:

   - `file_path`: the path printed by step 1 (an absolute path under `~/.clone-wars/_args/`).
   - `content`: the literal value of `$ARGUMENTS` (the slash-command argument string, exactly as the user typed it).

   IMPORTANT: do NOT echo, printf, or otherwise quote `$ARGUMENTS` into a shell command — pass it directly as the Write tool's `content` parameter. This is the entire reason for the Write step.

3. Use the Bash tool to invoke collect:

   ```
   "${CLAUDE_PLUGIN_ROOT}/bin/collect.sh" --args-file "${CLONE_WARS_HOME:-$HOME/.clone-wars}/_args/collect.txt"
   ```

4. Show the script's output to the user verbatim.
