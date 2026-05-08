---
description: Health check (tmux/state/config/providers) plus interactive trooper-roster picker — selects the active set for /clone-wars:consult
argument-hint: (no args)
allowed-tools: Bash, Write, AskUserQuestion
---

# /clone-wars:medic

Run the Clone Wars health check, then interactively pick which detected
providers should be the active roster for `/clone-wars:consult`.

## Steps

Steps 1–6 below are the bash wrapper around `bin/medic.sh` (mechanical
health checks). Steps A–G are the Claude-side interactive
trooper-selection flow added in v0.18.0.

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

6. If the verdict is `OK`, no further action is needed; the user is ready
   to run `/clone-wars:consult` or `/clone-wars:deploy`.

## Trooper selection (v0.18.0)

After the health table renders (steps 1–6 above), interactively pick which
detected providers should be the active roster for `/clone-wars:consult`.
Selection persists at `$state_root/providers-active.txt` (global, one per
machine/install). `bin/consult-init.sh` prefers this file over
`providers-available.txt` when present; this is the user's "preference layer"
on top of medic's mechanical detection.

**Always-interactive policy:** every `/clone-wars:medic` invocation runs
Steps A–G. Whether the user actually sees an `AskUserQuestion` prompt
depends on the detected count (Step C — auto-handles 0 and 1, prompts
for 2+). Steps A–G also run when the verdict is `FAIL` — as long as
`providers-available.txt` exists with ≥1 entry, the user can still pick
an active subset; if the file is missing or empty, Step A exits the
section cleanly.

**Trigger phrases.** Beyond explicit `/clone-wars:medic` invocation,
suggest this command when the user says any of: "switch consult roster",
"change which troopers /consult uses", "use only rex and cody", "pick
troopers", "re-pick the roster", or after they install/uninstall a
provider binary (claude / codex / opencode).

#### Step A — Read detected set

Use the Bash tool:

```
state_root="${CLONE_WARS_HOME:-$HOME/.clone-wars}"
grep -vE '^[[:space:]]*(#|$)' "$state_root/providers-available.txt" 2>/dev/null
```

Capture the result as `DETECTED` (one provider per line). If the file is
missing or unreadable, log `warn: providers-available.txt not found;
skipping trooper selection` and exit this section — Steps B–G are
skipped. (medic's existing FAIL handling has already surfaced the
underlying problem in step 5 above.)

#### Step B — Read prior selection if any

```
[[ -f "$state_root/providers-active.txt" ]] \
  && grep -vE '^[[:space:]]*(#|$)' "$state_root/providers-active.txt"
```

Capture the result as `PRIOR`. Filter `PRIOR` against `DETECTED` (drop
entries that are no longer detected — e.g. user uninstalled a binary
or the provider was removed from `contracts.yaml`). For each entry
dropped, print one line:

```
note: removed <provider> from active set (no longer detected)
```

If `PRIOR` is empty after filtering, treat it as no-prior for Steps D
and E (recommended option defaults switch from "keep current" to
"include all").

#### Step C — Decide whether to prompt

Branch on `DETECTED` count:

| Count | Behavior |
|---|---|
| `0`   | No prompt. medic already FAILed; nothing to choose. Skip Steps D–G. |
| `1`   | No prompt. Auto-write `providers-active.txt` with that one provider via Write tool. Print `auto-selected: <provider> (only detected provider)`. Skip Steps D–G. |
| `2`–`3` | Go to Step D (preset menu). |
| `4`   | Skip Step D (11+ subset options is too cluttered). Go directly to Step E (per-provider walk). |

#### Step D — Preset-subset menu (N=2 or N=3)

Build options from `DETECTED`, mapping each provider to its commander
via `codex → rex`, `claude → cody`, `opencode → bly` (matches
`cw_consult_provider_to_commander` in `lib/consult.sh`).

`AskUserQuestion`'s schema caps each question at 4 options, so the
menu shape differs by N:

For **N=2** (`DETECTED = [A, B]`) — single `AskUserQuestion`, 4 options:

- `Both <commander-A> + <commander-B>` (default recommended)
- `<commander-A> only`
- `<commander-B> only`
- `Customize…`

For **N=3** (`DETECTED = [A, B, C]`) — two-step nested
`AskUserQuestion`, because a flat 5-option menu (`All three` + 3 pairs +
`Customize`) exceeds the 4-option cap. Step D.1 is the high-level
choice (3 options); Step D.2 only fires if the user picks `Pick a pair`.

**Step D.1** (high-level, 3 options):

- `All three (<commander-A> + <commander-B> + <commander-C>)` (default recommended)
- `Pick a pair (drill in)`
- `Customize…`

**Step D.2** — fires only when D.1 returns `Pick a pair`. 3 options:

- `<commander-A> + <commander-B>` (drop C)
- `<commander-A> + <commander-C>` (drop B)
- `<commander-B> + <commander-C>` (drop A)

If `PRIOR` matches one of the preset subsets exactly:

- N=2 — relabel the matching top-level option to start with
  `Keep current selection (…)` and recommend it.
- N=3 — if `PRIOR` is exactly all three, relabel the `All three` option
  with `Keep current selection (…)`. If `PRIOR` is one of the pairs,
  recommend `Pick a pair` in D.1 and pre-select the matching pair in
  D.2's recommendation.

User picks anything except `Customize…` → write `providers-active.txt`
via the Write tool with the chosen subset (one provider per line, in
the same order they appear in `DETECTED`). Skip Steps E and F. Go to
Step G's confirmation print.

User picks `Customize…` → fall through to Step E.

#### Step E — Per-provider walk (Customize, or N≥4)

For each provider in `DETECTED` (in order), one `AskUserQuestion` with
question `Include <commander> (<provider>)?` and 2 options:

- `Include`
- `Exclude`

Pre-select `Include` as the recommended option if the provider is in
`PRIOR` (after Step B's stale filter), OR if `PRIOR` is empty
(first-time selection). Otherwise `Exclude` is recommended.

After walking all providers, collect the included subset → `INCLUDED`.

#### Step F — Empty-set guard

If `INCLUDED` is empty (user excluded every provider), print:

```
error: must select at least one provider; selection unchanged
```

and exit this section. **Do not** write `providers-active.txt`. Prior
state is left intact (or absent if it didn't exist). Don't auto re-prompt;
the user can re-run `/clone-wars:medic` if they want another shot.

#### Step G — Atomic write

Use the **Write tool** to write `$state_root/providers-active.txt`.
File contents (replace tokens in angle brackets):

```
# generated <ISO-8601 UTC timestamp> by /clone-wars:medic
# active providers selected by user
<provider-1>
<provider-2>
…
```

Generate the timestamp with Bash: `date -u +%Y-%m-%dT%H:%M:%SZ`.

Print a confirmation line:

```
active set: <commander-A>, <commander-B> (written to providers-active.txt)
```

(Use commander names, not provider names, in the confirmation — matches
the AskUserQuestion option labels the user just saw.)
