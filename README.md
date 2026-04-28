# Clone Wars

**Spawn Codex, Gemini, and Claude as real tmux panes you can attach to mid-task.**

Clone Wars is a Claude Code plugin that turns multi-model orchestration into something
you can *watch live*. Every model becomes a clone trooper — a named tmux pane
(`captain rex (codex)`, `commander cody (claude)`, `commander wolffe (gemini)`) running
its native TUI, talking to your Claude Code session via inbox/outbox files. Panes survive
conductor crashes; you can `tmux select-pane` mid-task and see exactly what each model
is doing.

[Install](#install) · [Quickstart](#quickstart) · [Commands](#commands) · [Design](docs/DESIGN.md)

---

## Why

When Claude Code dispatches a Claude teammate, you see it work in a real pane. When that
teammate shells out to Codex or Gemini, you don't — the model runs as a hidden subprocess.
You lose visibility, you lose mid-task intervention, you lose the conversation.

Clone Wars closes that gap. Every model gets a real attachable pane with the same
observability as a Claude teammate. File-based IPC replaces in-process `SendMessage`, so
panes survive crashes and stay forensically reconstructable after teardown.

---

## Install

```
/plugin marketplace add WingsOfPanda/clone-wars
/plugin install clone-wars@clone-wars
```

Then, inside a tmux session:

```
/clone-wars:medic
```

Medic verifies tmux ≥ 3.0, your `$CLONE_WARS_HOME`, the shipped configs, and per-provider
binary availability. Missing providers WARN (you don't need all three); zero healthy
providers FAIL.

---

## Quickstart

```
/clone-wars:spawn rex codex auth-review "review src/auth/oauth.py for token-refresh edge cases"
/clone-wars:list
/clone-wars:collect rex auth-review
/clone-wars:teardown auth-review
```

What just happened:

1. **spawn** opened a new pane labelled `captain rex (codex)` in Rex's blue, started Codex
   inside it, injected the trooper identity prompt, and dispatched the review task.
2. **list** shows every active trooper across topics — commander, model, topic, pane id, state.
3. **collect** blocks until Rex emits `{event: "done"}` in his outbox, then prints the summary.
4. **teardown** flashes a colored "MISSION ACCOMPLISHED" banner for 8 seconds, kills the pane,
   and archives Rex's state directory to `$CLONE_WARS_HOME/archive/...` for forensics.

Each trooper is identified by `<commander>-<model>-<topic>`: a name from a curated pool
(`rex`, `cody`, `wolffe`, `fives`, `echo`, ...), the model it runs (`codex` / `gemini` /
`claude`), and the operation slug. Multiple troopers can run on one topic; multiple topics
run concurrently.

---

## Commands

| Command | What it does |
|---|---|
| `/clone-wars:medic` | Health-check: tmux + `$CLONE_WARS_HOME` + configs + provider binaries. Run before spawning. |
| `/clone-wars:spawn <commander> <model> <topic> [--mode full\|read-only] [prompt]` | Open a tmux pane running the model's TUI. `commander` is a name from the pool, or `random`. `--mode read-only` sandboxes the trooper. Optional `prompt` is dispatched as the first task. |
| `/clone-wars:send <commander> <topic> <msg-or-@file>` | Write a task to a trooper's inbox; the pane reads it on nudge. `@path` inlines a file. |
| `/clone-wars:collect <commander> <topic> [--timeout s]` | Block until the trooper reports `done` or `error`, then print the summary. Exits non-zero on error/timeout so the conductor can chain commands. |
| `/clone-wars:list [<topic>]` | Show active troopers across topics, or scope to one. Flags `[ORPHAN]` panes for cleanup. |
| `/clone-wars:teardown <topic>` / `<commander> <topic>` / `--all` | Graceful shutdown: 8s colored banner, then kill the pane and archive state. |

Full spec: `docs/DESIGN.md` §Slash commands. Runtime IPC (the `END_OF_INSTRUCTION` sentinel,
JSONL outbox event types, status state machine) is in §File-IPC protocol.

---

## Orchestration: `/clone-wars:consult`

`/clone-wars:consult <topic>` is the first orchestration command on top of the
spawn/send/collect/teardown primitives. Use it for cross-verified research:

1. The conductor spawns `rex (codex)` and `cody (claude)` on a fresh topic.
2. Both research independently, writing structured `findings.md`.
3. The conductor diffs the findings via citation overlap (path normalization,
   line-range intersection, URL exact match).
4. Each side's unique claims dispatch back to the OTHER trooper for AGREE /
   DISPUTE / UNCERTAIN verification — using the SAME pane (codex and claude
   TUIs preserve in-session memory across the two calls).
5. The conductor adjudicates disputed items by reading the cited sources
   directly, then synthesizes a six-section report (Agreed / Cross-verified /
   Adjudicated / Contested / Not-verified / Trooper artifacts).

```
/clone-wars:consult "review src/auth/oauth.py for token-refresh edge cases"
```

The full spec is at `docs/superpowers/specs/2026-04-28-clone-wars-consult-design.md`.

---

## Visual identity

Each commander gets a Star Wars canon hue rendered in a Morandi (muted, low-saturation)
palette, with a contrasting accent for the model name:

| Commander | Color | Model accent |
|---|---|---|
| `captain rex (codex)` | dusty blue | codex stripe |
| `commander cody (claude)` | warm orange | claude stripe |
| `commander wolffe (gemini)` | dusty periwinkle | gemini stripe |
| `kix (claude)` | medic teal | claude stripe |
| `fives (codex)` | corporal slate | codex stripe |

Identity is carried by custom `@cw_*` tmux user-options on each pane (OSC-immune, so the
TUIs can't clobber labels when they emit terminal title sequences). The full pool lives in
`config/commanders.yaml`.

---

## Configuration

State, archive, and config all live under `$CLONE_WARS_HOME` (default `~/.clone-wars/`).
Override for CI, sandboxes, or shared dev hosts:

```bash
export CLONE_WARS_HOME=/path/to/wherever
```

Four config files (medic auto-copies the shipped defaults on first run):

- `contracts.yaml` — provider binaries, mode args (`full` / `read-only`), ready timeouts.
- `commanders.yaml` — the clone-trooper name pool that `/clone-wars:spawn random ...` draws from.
- `identity-template.md` — system prompt every trooper receives at spawn. `{{commander}}`,
  `{{model}}`, `{{topic}}`, `{{state_dir}}` are substituted.
- `config.yaml` — split direction, pane layout, default ready/collect timeouts.

### Suppress tmux permission prompts

The runtime shells out to `tmux` heavily. Without an allowlist, every spawn prompts. Paste
this into `~/.claude/settings.local.json`:

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

### Render the trooper labels (one-time tmux setup)

Append to `~/.tmux.conf`, then `tmux source-file ~/.tmux.conf`:

```tmux
set -g pane-border-status top
set -g pane-border-format ' #{?@cw_label_fmt,#{@cw_label_fmt},#[fg=#{?@cw_color,#{@cw_color},default}#,bold]#{?@cw_label,#{@cw_label},#{pane_title}}#[default]} '
```

Without this, panes still work — they just show the default tmux title instead of the
colored Star Wars label.

---

## Troubleshooting

Run `/clone-wars:medic` first. It diagnoses the most common failures and prints an
`install:` hint per failed check.

| Symptom | Cause | Fix |
|---|---|---|
| medic: `\$TMUX not set` | not inside a tmux session | `tmux new -s clone-wars` |
| medic: `tmux: 2.x — requires >= 3.0` | tmux too old | upgrade tmux |
| spawn prompts on every tmux call | allowlist not added | paste the `settings.local.json` snippet above |
| trooper labels missing or unstyled | `pane-border-format` not set | append the `tmux.conf` snippet above |
| spawn fails: `commander already deployed` | duplicate name on this topic | `/clone-wars:teardown <commander> <topic>` first, or pick a different commander |
| spawn fails: `ready timeout` | provider cold-start slower than `ready_timeout_s` | raise it in `contracts.yaml` |
| `[ORPHAN]` in list output | recorded pane died but state dir survives | `/clone-wars:teardown <commander> <topic>` |

For everything else: `docs/DESIGN.md` §Failure modes.

---

## License

MIT — see `LICENSE`.
