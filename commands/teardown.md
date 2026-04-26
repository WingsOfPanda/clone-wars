---
description: Gracefully kill trooper panes (8s colored banner) and archive their state
argument-hint: <topic> | <commander> <topic> | --all
allowed-tools: Bash
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

1. Use the Bash tool to run:

   ```
   "${CLAUDE_PLUGIN_ROOT}/bin/teardown.sh" $ARGUMENTS
   ```

2. Show the script's output to the user verbatim. The script blocks for ~9 seconds while
   the graceful banner countdown runs, so the response will be a beat slower than the
   other commands — this is normal.
