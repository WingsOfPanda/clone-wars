---
description: Health check for Clone Wars — verifies tmux, $CLONE_WARS_HOME, config files, and provider binaries
argument-hint: (no args)
allowed-tools: Bash
---

# /clone-wars:medic

Run the Clone Wars health check by invoking the medic script.

## Steps

1. Use the Bash tool to run:

   ```
   "${CLAUDE_PLUGIN_ROOT}/bin/medic.sh"
   ```

2. Show the script's output to the user verbatim — it is already formatted with status
   glyphs and a Verdict line.

3. If the verdict is `FAIL`, briefly summarize which checks failed and offer next steps:

   - **tmux missing or too old** → `apt install tmux` / `brew install tmux`; clone-wars
     requires tmux ≥ 3.0.
   - **`$TMUX` not set (warning)** → run `tmux new -s clone-wars` before spawning crews.
   - **state dir not writable** → check `$CLONE_WARS_HOME` (default `~/.clone-wars`); the
     parent directory must exist and be writable.
   - **config file missing** → reinstall the plugin: `/plugin install clone-wars@clone-wars`.
   - **all providers missing** → install at least one of `codex`, `gemini`, `claude`.

4. If the verdict is `OK`, no further action is needed; the user is ready to spawn troopers
   (once the runtime commands ship in v0.0.1 — until then, `/clone-wars:spawn` etc. print
   stub messages).
