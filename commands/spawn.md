---
description: Spawn a clone trooper as a tmux pane running codex/gemini/claude
argument-hint: <commander|random> <model> <topic> [--mode full|read-only] [initial-prompt]
allowed-tools: Bash
---

# /clone-wars:spawn

Spawn a clone trooper as a new tmux pane running the chosen model TUI.

- `commander` — name from `$CLONE_WARS_HOME/commanders.yaml` (case-insensitive), or
  `random` to pick an unused one (biased toward globally-unused names first).
- `model` — provider key from `$CLONE_WARS_HOME/contracts.yaml` (`codex` / `gemini` /
  `claude` by default).
- `topic` — operation slug, `[a-z0-9-]+` up to 32 chars.
- `--mode` — `full` (default; the provider's yolo/bypass arg set) or `read-only`
  (sandboxed). Pulled from the provider's `modes:` map in `contracts.yaml`.
- `initial-prompt` — optional first task to dispatch via inbox after spawn returns.

The first trooper on a topic right-splits the conductor; subsequent troopers down-split
the most-recently-spawned trooper on the same topic (per `docs/DESIGN.md` §Pane layout).
The pane is labeled with the trooper's Morandi color and rank
(`captain-rex:codex:auth-review`); the active pane's border outlines in that color.

## Steps

1. Use the Bash tool to run, passing through `$ARGUMENTS`:

   ```
   "${CLAUDE_PLUGIN_ROOT}/bin/spawn.sh" $ARGUMENTS
   ```

2. Show the script's output to the user verbatim — it reports the spawned pane id, state
   directory, and ready status.

3. If spawn FAILs, the script also dumps the trooper pane's last 25 lines and its outbox
   contents to stderr — surface those to the user so they can diagnose. Common causes:
   commander already deployed on this topic (run `/clone-wars:teardown <commander> <topic>`
   first), provider binary not on PATH, or the trooper TUI took longer than the
   `ready_timeout_s` from `contracts.yaml` (raise it for that provider).
