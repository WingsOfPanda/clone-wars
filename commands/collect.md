---
description: Block until a trooper reports done or error in outbox.jsonl
argument-hint: <commander> <topic> [--timeout <seconds>]
allowed-tools: Bash
---

# /clone-wars:collect

Block until the named trooper reports `{done}` (success) or `{error}` (failure) in its
outbox.jsonl, then print the matching JSON line.

- `commander` `topic` — same identifiers used at spawn.
- `--timeout` — seconds to wait, default 600.

Exits 0 on `{done}` and 1 on `{error}` or timeout, so the conductor can chain commands.

## Steps

1. Use the Bash tool to run:

   ```
   "${CLAUDE_PLUGIN_ROOT}/bin/collect.sh" $ARGUMENTS
   ```

2. Show the script's output to the user verbatim.
