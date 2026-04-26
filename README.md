# Clone Wars

**Watch any model think live, in a tmux pane you can attach to.**

Clone Wars is a Claude Code plugin that turns Codex, Gemini, and Claude TUIs into real,
attachable tmux panes — the same way Claude Code already does for its Claude teammates. Spawn
a Codex pane to write code, a Gemini pane to do long-context review, a Claude pane to plan;
each one a clone trooper named like `rex-codex-auth-review`. The conductor (your Claude
Code session) talks to them via files, so panes survive conductor crashes and you can
`tmux attach` mid-task to see what the model is actually doing.

## Why this exists

When Claude Code orchestrates a Claude teammate, the teammate runs in a tmux pane and you can
see everything it's doing. When that teammate needs a different model — Codex for heavy
implementation, Gemini for long-context review — it shells out to a hidden subprocess. You
lose visibility, conversation continuity across rounds, and the ability to intervene live.

Clone Wars closes that gap: every model gets a real, attachable tmux pane with the same
observability as a Claude teammate. File-based IPC (inbox / outbox / status) replaces
in-process `SendMessage`. The Admiral pays for visibility everywhere — including the layer
doing the actual work.

> **v0.0.1-pre1 — marketplace shell.** The plugin is installable, `/clone-wars:medic` verifies
> your environment, and the configuration surface is locked. The runtime commands
> (`/clone-wars:spawn`, `:send`, `:collect`, `:list`, `:teardown`) ship as documented stubs;
> they become real in v0.0.1 once the tracer-bullet validates tmux + IPC mechanics on real
> machines. See `CLAUDE.md` §Status for the roadmap.

## Install

```
/plugin marketplace add WingsOfPanda/clone-wars
/plugin install clone-wars@clone-wars
```

## Quickstart

**Today (works in v0.0.1-pre1):**

```
/clone-wars:medic
```

Verifies tmux ≥ 3.0, your `$CLONE_WARS_HOME`, the shipped config files, and per-provider
binary availability. Run it first to confirm Clone Wars can do its job on this machine.
Missing providers are WARNed (you don't need all three); zero healthy providers FAILs.

**v0.0.1 preview (these print stub messages until the runtime ships):**

```
/clone-wars:spawn rex codex auth-review "review src/auth/oauth.py for token-refresh edge cases"
/clone-wars:collect rex auth-review
/clone-wars:teardown auth-review
```

Each clone trooper is identified by `<commander>-<model>-<topic>`: a name from a curated pool
(`rex`, `cody`, `wolffe`, ...), the model it runs (`codex` / `gemini` / `claude`), and the
operation topic. Multiple troopers can run on one topic; multiple topics can run concurrently.
Topic doubles as the implicit crew name — `/clone-wars:list auth-review` shows every trooper
on that operation; `/clone-wars:teardown auth-review` kills them all.

## Commands

| Command | Status | What it does |
|---|---|---|
| `/clone-wars:medic` | live | Health-check: tmux + `$CLONE_WARS_HOME` + configs + provider binaries. Run before spawning. |
| `/clone-wars:spawn <commander> <model> <topic> [--mode <full\|read-only>] [prompt]` | stub (v0.0.1) | Open a tmux pane running the model's TUI. Example: `rex codex auth-review` to spawn a Codex pane that watches you implement auth. `--mode read-only` sandboxes the trooper. |
| `/clone-wars:send <commander> <topic> <msg-or-@file>` | stub (v0.0.1) | Write a message to a trooper's inbox; the pane reads it on nudge. `@path` inlines a file. |
| `/clone-wars:collect <commander> <topic> [--timeout s]` | stub (v0.0.1) | Block until the trooper reports `done` or `error`, then print the summary. |
| `/clone-wars:list [<topic>]` | stub (v0.0.1) | Show active troopers across topics, or scoped to one. Flags orphan panes for cleanup. |
| `/clone-wars:teardown [<commander>] [<topic>] [--all]` | stub (v0.0.1) | Kill panes and archive trooper state to `$CLONE_WARS_HOME/archive/` for forensics. |

Full command spec: `docs/DESIGN.md` §Slash commands. Runtime IPC (inbox/outbox/status files,
the `END_OF_INSTRUCTION` sentinel, the JSONL outbox event types) is in §File-IPC protocol.

## Configuration

State, archive, and config all live under `$CLONE_WARS_HOME` (default `~/.clone-wars/`).
Override to put state elsewhere — useful for CI, sandboxes, or shared dev hosts:

```bash
export CLONE_WARS_HOME=/path/to/wherever
```

Four config files live there (medic auto-copies the shipped defaults on first run):

- `contracts.yaml` — provider binaries, mode args (`full` / `read-only`), ready timeouts.
  Edit to swap `codex` for a different binary, add provider variants, or change default modes.
- `commanders.yaml` — the clone-trooper name pool that `/clone-wars:spawn random ...` draws from.
- `identity-template.md` — system prompt every trooper receives at spawn time. `{{commander}}`,
  `{{model}}`, `{{topic}}`, `{{state_dir}}` are substituted.
- `config.yaml` — split direction, pane layout, default ready/collect timeouts.

### Permission allowlist (for the v0.0.1 runtime — not medic)

The runtime commands (in v0.0.1) shell out to `tmux` heavily. Without an allowlist you'll
see permission prompts on every spawn. Paste this into `~/.claude/settings.local.json` to
suppress them:

```jsonc
{
  "permissions": {
    "allow": [
      "Bash(tmux:*)",
      "Bash(command -v *)",
      "Read(~/.clone-wars/**)",
      "Write(~/.clone-wars/**)",
      "Edit(~/.clone-wars/**)"
    ]
  }
}
```

`/clone-wars:medic` (v0.0.1-pre1) doesn't need any of these; it only reads from
`~/.clone-wars/` and runs `tmux -V`, both of which Claude Code allows by default.

## Troubleshooting

Run `/clone-wars:medic` first. It diagnoses the most common failures and prints an `install:`
hint per failed check.

| Symptom | Likely cause | Fix |
|---|---|---|
| medic says `\$TMUX not set` | not inside a tmux session | `tmux new -s clone-wars` |
| medic says `tmux: 2.x — requires >= 3.0` | tmux too old | upgrade tmux |
| spawn (in v0.0.1) prompts for permission on every tmux call | permission allowlist not added | paste the snippet above into `settings.local.json` |
| provider WARN'd but you don't use it | nothing to fix | medic verdict is OK as long as ≥1 provider is healthy |

For everything else: `docs/DESIGN.md` §Failure modes.

## License

MIT — see `LICENSE`.
