---
description: Spawn a clone trooper as a tmux pane running codex/gemini/claude
argument-hint: <commander|random> <model> <topic> [--mode full|read-only] [initial-prompt]
allowed-tools: Bash, Write
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

The first trooper on a topic right-splits Master Yoda; subsequent troopers down-split
the most-recently-spawned trooper on the same topic (per `docs/DESIGN.md` §Pane layout).
The pane is labeled with the trooper's Morandi color and rank
(`captain-rex:codex:auth-review`); the active pane's border outlines in that color.

## Steps

The user's `$ARGUMENTS` may contain shell metacharacters. To prevent injection, we keep it out of any bash source: write it via the Write tool (a literal string parameter), then invoke the bin script with `--args-file`.

1. Use the Bash tool to resolve the args-file path:

   ```
   ARGS_DIR="${CLONE_WARS_HOME:-$HOME/.clone-wars}/_args"
   mkdir -p "$ARGS_DIR"
   echo "$ARGS_DIR/spawn.txt"
   ```

   The script prints the absolute path; remember it for steps 2 and 3.

2. Use the Write tool to put `$ARGUMENTS` into that path:

   - `file_path`: the path printed by step 1 (an absolute path under `~/.clone-wars/_args/`).
   - `content`: the literal value of `$ARGUMENTS` (the slash-command argument string, exactly as the user typed it).

   IMPORTANT: do NOT echo, printf, or otherwise quote `$ARGUMENTS` into a shell command — pass it directly as the Write tool's `content` parameter. This is the entire reason for the Write step.

3. Use the Bash tool to invoke spawn:

   ```
   "${CLAUDE_PLUGIN_ROOT}/bin/spawn.sh" --args-file "${CLONE_WARS_HOME:-$HOME/.clone-wars}/_args/spawn.txt"
   ```

4. Show the script's output to the user verbatim — it reports the spawned pane id, state directory, and ready status.

5. If spawn FAILs, the script also dumps the trooper pane's last 25 lines and its outbox contents to stderr — surface those to the user so they can diagnose. Common causes: commander already deployed on this topic (run `/clone-wars:teardown <commander> <topic>` first), provider binary not on PATH, or the trooper TUI took longer than the `ready_timeout_s` from `contracts.yaml` (raise it for that provider).
