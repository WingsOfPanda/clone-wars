---
description: Health check for Clone Wars — verifies tmux, `$CLONE_WARS_HOME`, config files, and provider binaries
argument-hint: (no args)
allowed-tools: Bash, Write
---

# /clone-wars:medic

Run the Clone Wars health check by invoking the medic script.

## Steps

The user's `$ARGUMENTS` may contain shell metacharacters. To prevent injection, we keep it out of any bash source: write it via the Write tool (a literal string parameter), then invoke the bin script with `--args-file`.

1. Use the Bash tool to resolve the args-file path:

   ```
   ARGS_DIR="${CLONE_WARS_HOME:-$HOME/.clone-wars}/_args"
   mkdir -p "$ARGS_DIR"
   echo "$ARGS_DIR/medic.txt"
   ```

   The script prints the absolute path; remember it for steps 2 and 3.

2. Use the Write tool to put `$ARGUMENTS` into that path:

   - `file_path`: the path printed by step 1 (an absolute path under `~/.clone-wars/_args/`).
   - `content`: the literal value of `$ARGUMENTS` (the slash-command argument string, exactly as the user typed it).

   IMPORTANT: do NOT echo, printf, or otherwise quote `$ARGUMENTS` into a shell command — pass it directly as the Write tool's `content` parameter. This is the entire reason for the Write step.

3. Use the Bash tool to invoke medic:

   ```
   "${CLAUDE_PLUGIN_ROOT}/bin/medic.sh" --args-file "${CLONE_WARS_HOME:-$HOME/.clone-wars}/_args/medic.txt"
   ```

4. Show the script's output to the user verbatim — it is already formatted with status glyphs and a Verdict line.

5. If the verdict is `FAIL`, briefly summarize which checks failed and offer next steps:

   - **tmux missing or too old** → `apt install tmux` / `brew install tmux`; clone-wars
     requires tmux ≥ 3.0.
   - **`$TMUX` not set (warning)** → run `tmux new -s clone-wars` before spawning crews.
   - **state dir not writable** → check `$CLONE_WARS_HOME` (default `~/.clone-wars`); the
     parent directory must exist and be writable.
   - **config file missing** → reinstall the plugin: `/plugin install clone-wars@clone-wars`.
   - **all providers missing** → install at least one of `codex`, `gemini`, `claude`.

6. If the verdict is `OK`, no further action is needed; the user is ready to spawn troopers
   (once the runtime commands ship in v0.0.1 — until then, `/clone-wars:spawn` etc. print
   stub messages).
