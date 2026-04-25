# Clone Wars

> **v0.0.1-pre1 — marketplace shell.** Plugin is installable; `/clone-wars:medic`
> works; the runtime commands (`spawn`/`send`/`collect`/`list`/`teardown`) ship
> as stubs and become real in v0.0.1 once the tracer-bullet validates the
> underlying tmux + IPC mechanics. See `CLAUDE.md` status checklist.

Multi-model tmux pane orchestration for Claude Code.

A Claude Code session orchestrates a crew of model TUIs — `codex`, `gemini`,
`claude` — as real, attachable tmux panes. Communication is file-based (inbox /
outbox / status), so panes survive conductor crashes and you can `tmux attach`
to any pane to watch the model think live.

Each pane is a clone trooper: `<commander>-<model>-<topic>` (e.g.
`rex-codex-auth-review`).

## Install

```
/plugin marketplace add WingsOfPanda/clone-wars
/plugin install clone-wars@clone-wars
```

## Quickstart

```
/clone-wars:medic
```

The medic command verifies that `tmux ≥ 3.0`, `$CLONE_WARS_HOME`, your config
files, and at least one provider binary are all healthy. Run it first.

The remaining commands are documented below; they print a "pending v0.0.1"
message until the tracer-bullet validates the runtime mechanics.

```
/clone-wars:spawn rex codex auth-review "review src/auth/oauth.py for token-refresh edge cases"
/clone-wars:collect rex auth-review
/clone-wars:teardown auth-review
```

## Why

Claude Code already renders Claude teammates as attachable tmux panes (via
`Agent + TeamCreate`). But when a teammate needs a different model — Codex for
heavy implementation, Gemini for long-context — it shells out to a hidden
subprocess. You lose visibility, conversational continuity, and the ability to
intervene live.

Clone Wars is the missing primitive: a Claude Code conductor spawns and
orchestrates real, interactive `codex` / `gemini` / `claude` TUIs as tmux panes
you can attach to. File-based IPC replaces in-process `SendMessage`. The
Admiral pays for visibility everywhere — including the layer doing the actual
work.

## Commands

| Command | Status | What it does |
|---|---|---|
| `/clone-wars:medic` | live | Health-check: tmux, `$CLONE_WARS_HOME`, configs, provider binaries |
| `/clone-wars:spawn <commander> <model> <topic> [--mode <full|read-only>] [prompt]` | stub | Spawn a trooper in a new tmux pane (in v0.0.1) |
| `/clone-wars:send <commander> <topic> <msg-or-@file>` | stub | Write to a trooper's inbox and nudge (in v0.0.1) |
| `/clone-wars:collect <commander> <topic> [--timeout s]` | stub | Block until trooper reports done/error (in v0.0.1) |
| `/clone-wars:list [<topic>]` | stub | Show active troopers (in v0.0.1) |
| `/clone-wars:teardown [<commander>] [<topic>] [--all]` | stub | Kill panes and archive state (in v0.0.1) |

Full command spec: `docs/DESIGN.md` §Slash commands.

## Configuration

State, archive, and config all live under `$CLONE_WARS_HOME`, defaulting to
`~/.clone-wars/`. Override with:

```bash
export CLONE_WARS_HOME=/path/to/wherever
```

Three config files live there (medic copies the shipped defaults on first run):

- `contracts.yaml` — provider binaries, mode args (`full` / `read-only`),
  ready timeouts. Edit to add custom provider variants or adjust default modes.
- `commanders.yaml` — clone-trooper name pool used by `random` keyword on spawn.
- `identity-template.md` — system prompt every trooper receives at spawn time.
- `config.yaml` — split direction, layout, default timeouts.

### Permission allowlist (optional)

To suppress permission prompts on every spawn, paste this into
`~/.claude/settings.local.json`:

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

This is optional — without it the plugin still works, you just see prompts on
first use.

## Troubleshooting

Run `/clone-wars:medic` first. It diagnoses the most common failures and prints
an `install:` hint per failed check.

| Symptom | Likely cause | Fix |
|---|---|---|
| medic says `\$TMUX not set` | not inside a tmux session | `tmux new -s clone-wars` |
| medic says `tmux: 2.x — requires >= 3.0` | tmux too old | upgrade tmux |
| spawn (in v0.0.1) prompts for permission on every tmux call | permission allowlist not added | paste the snippet above into `settings.local.json` |
| provider WARN'd but you don't use it | nothing to fix | medic verdict is OK as long as ≥1 provider is healthy |

For everything else: `docs/DESIGN.md` §Failure modes.

## License

MIT — see `LICENSE`.
