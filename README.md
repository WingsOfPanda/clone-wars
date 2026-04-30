# Clone Wars

**Spawn Codex, Gemini, and Claude as real tmux panes you can attach to mid-task.**

Clone Wars is a Claude Code plugin that turns multi-model orchestration into something
you can *watch live*. Every model becomes a clone trooper — a named tmux pane
(`captain rex (codex)`, `commander cody (claude)`, `commander wolffe (gemini)`) running
its native TUI, talking to your Claude Code session via inbox/outbox files. Panes survive
Master Yoda crashes; you can `tmux select-pane` mid-task and see exactly what each model
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
| `/clone-wars:collect <commander> <topic> [--timeout s]` | Block until the trooper reports `done` or `error`, then print the summary. Exits non-zero on error/timeout so Master Yoda can chain commands. |
| `/clone-wars:list [<topic>]` | Show active troopers across topics, or scope to one. Flags `[ORPHAN]` panes for cleanup. |
| `/clone-wars:teardown <topic>` / `<commander> <topic>` / `--all` | Graceful shutdown: 8s colored banner, then kill the pane and archive state. |

Full spec: `docs/DESIGN.md` §Slash commands. Runtime IPC (the `END_OF_INSTRUCTION` sentinel,
JSONL outbox event types, status state machine) is in §File-IPC protocol.

---

## Orchestration: `/clone-wars:consult`

`/clone-wars:consult <topic>` is the cross-verified dual-model
investigation command. The slash directive walks Master Yoda through
13 step boundaries via per-phase sub-scripts under `bin/`:

1. `consult-init` derives a slug + creates the consult topic dir.
2. Parallel `spawn.sh rex codex` + `spawn.sh cody claude`.
3. Parallel `consult-research-send` to both troopers (writes
   `_consult/research-<commander>.txt` with offset).
4. Parallel `consult-research-wait` per trooper (appends FS status).
5. `consult-diff` — citation overlap, writes `diff.md` and `*_only_items.txt`.
6. Parallel `consult-verify-send` (rex grades cody-only items, vice
   versa; either skipped if peer has no items).
7. Parallel `consult-verify-wait` per trooper.
8. `consult-adjudicate` writes `adjudicated-draft.md`. Master Yoda copies
   to `adjudicated.md` and resolves PENDING items via Edit.
9. `consult-synthesize` (refuses on any remaining PENDING) writes
   `synthesis.md`.
10. `consult-teardown` + `consult-archive`.

Between every step Master Yoda regains control: if a trooper writes
malformed findings, Master Yoda can `cw_send` a clarifying prompt,
then `consult-offset-reset` + re-run the affected phase. The retry
contract is fully documented in the slash directive.

```
/clone-wars:consult "review src/auth/oauth.py for token-refresh edge cases"
```

The full v0.2 spec is at `docs/superpowers/specs/2026-04-29-clone-wars-consult-v2-design.md`.

### v0.3 — trooper question protocol + skill routing

Topic-shaped skill hints let the consult run with `superpowers:brainstorming`
or `superpowers:systematic-debugging` inside each trooper. When a skill
asks a design question, the trooper writes `{"event":"question",...}` to
its outbox; Master Yoda either answers from topic context (non-critical)
or escalates to the user via `AskUserQuestion` (critical). Most questions
never reach the user.

- Topic classifier (regex over topic text) writes `_consult/skill.txt`
  with one of `brainstorming` / `systematic-debugging` / `none`.
- Send-scripts append `config/skill-hints/<skill>.md` to the inbox prompt.
  The hint contains the autonomy contract (encoding rules, document Q&A
  in findings.md, ask the general not the user).
- Wait-scripts catch `question` events with terminal-event precedence
  (done/error win) and head -n1 semantics among questions (serialization).
- `CW_CONSULT_SKILL_OVERRIDE=none` env-var disables hints mid-run.

Limitations (v0.3.0): question payloads are printable ASCII only; special
chars must be percent-encoded (`%0A %09 %22 %5C %2C %25`). Multi-byte
content is rejected. Full JSON decoding deferred to v0.3.1+.

Spec: `docs/superpowers/specs/2026-04-29-clone-wars-consult-question-protocol-design.md`.

### What's new in v0.5.0 — "Octogent Steals"

- 🦑 **Yoda stays interactive during consult waits.** Background-await pattern means you can chat with Master Yoda or run `/clone-wars:list` while troopers are working.
- 👁 **`/clone-wars:list` flags stale troopers.** Working troopers whose outbox has been silent for >180s render as `stale`. Override via `CW_STALE_THRESHOLD_S`.
- ✉️ **`cw_send --from <sender>`** lets messages carry sender attribution (default `master-yoda`); paves the way for v0.6+ trooper-to-trooper messaging.
- 🧱 **Prompts are versioned templates.** Per-phase markdown under `config/prompt-templates/consult/` makes them grep-able, diff-able, and easier to evolve.

Inspired by [octogent](https://github.com/hesamsheikh/octogent)'s orchestration patterns, adapted for clone-wars' pure-shell + tmux + file-IPC model.

### v0.4 — design-doc mode

Consult can produce a brainstorming-style design doc at the end of an
investigation. Two ways in:

- **Implicit:** `/clone-wars:consult <topic>` — after synthesis, if the
  topic classifier returned `brainstorming`, Master Yoda asks whether to
  walk through a design doc. Decline → run ends at synthesis.md as before.
- **Explicit:** `/clone-wars:consult --design-doc <topic>` — skips the
  prompt; Step 8.5 always runs.

Step 8.5 walks the user through five sections — Architecture, Components,
Data Flow, Error Handling, Testing — with `AskUserQuestion` per section
(Approve / Revise / Drill deeper / Skip). "Drill deeper" sends a focused
follow-up to one trooper before tearing down. The approved sections are
assembled with a standard header into
`docs/clone-wars/specs/YYYY-MM-DD-<slug>-design.md`, self-reviewed for
placeholders, and committed.

Investigation topics (bug hunts, audits) skip the prompt entirely — the
classifier marks them `systematic-debugging` or `none` and consult ends
at synthesis.md.

Spec: `docs/superpowers/specs/2026-04-29-clone-wars-consult-design-doc-mode-design.md`.

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
