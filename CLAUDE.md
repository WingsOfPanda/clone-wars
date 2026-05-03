# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Clone Wars — Working Notes for Claude Code

This repository is a **Claude Code plugin** that lets a Claude Code session orchestrate
multiple model TUIs (`codex`, `gemini`, `claude`) as **real tmux panes** the user can
attach to and watch live. File-based IPC (inbox / outbox / status) replaces in-process
`SendMessage`. Pane identity follows clone-trooper naming: `<commander>-<model>-<topic>`
(e.g. `rex-codex-auth-review`).

The frozen design lives at **`docs/DESIGN.md`** — read it first; it is the canonical
reference for architecture, IPC protocol, contracts table, identity prompt, and the
out-of-scope list. Anything you change should be reflected back into that file (or
documented as a deliberate departure with a why-line).

## Why this exists

- **OMC reference**: oh-my-claudecode (`/home/liupan/ref/oh-my-claudecode`) ships a much larger
  surface (worktrees, role routing, MCP servers, HUD, Telegram, learning). Clone Wars is the
  **trimmed primitive**: spawn, send, collect, list, teardown. Nothing else.
- **ARS reference**: `/strike-team` and `/executeorder66` already orchestrate Claude teammates
  via `Agent + TeamCreate` (in-process). Clone Wars is **additive** — not replacing them.
  Future integration: a strike-team DAG part with `provider: codex` could spawn a Clone Wars
  trooper instead of a Claude teammate.
- **Why a separate plugin** (not an ARS command): Clone Wars is general-purpose; it shouldn't
  know about medical-AI workflows. Lives in its own repo so it can be installed independently
  on any project.

## Commands

v0.0.1-pre1 has shipped: marketplace shell + `/clone-wars:medic` + lib helpers + tests. The runtime
commands (`spawn`/`send`/`collect`/`list`/`teardown`) are stubs pending the tracer-bullet (Plan B).

```bash
# Verify the host can run Clone Wars (works today)
bash bin/medic.sh
# or from a Claude Code session: /clone-wars:medic

# Run the test suite (4 test files, 22 tests)
bash tests/run.sh

# Inspect/clean per-trooper state while iterating (Plan B will populate state/)
ls ~/.clone-wars/state/      # active troopers (empty until v0.0.1)
ls ~/.clone-wars/archive/    # archived after teardown (empty until v0.0.1)
rm -rf ~/.clone-wars/state/* # nuke active state if a tracer run wedges (Plan B)

# Plan B work (not yet built — gated on tracer-bullet validating tmux/IPC mechanics)
# bash tracer/tracer-bullet.sh
```

No `package.json` and no separate test framework — pure bash + `tests/run.sh`. Use `shellcheck`
locally if you want extra linting; not required.

## Repository layout

```
clone-wars/
├── CLAUDE.md                  ← this file (Claude Code working notes)
├── README.md                  ← user-facing intro (write last, when plugin works)
├── LICENSE                    ← MIT
├── docs/
│   ├── DESIGN.md              ← runtime/IPC design (Plan B is informed by this)
│   └── superpowers/
│       ├── specs/             ← per-feature design specs (e.g. marketplace-prep)
│       └── plans/             ← implementation plans
├── bin/                       ← real executable shell scripts (one per command)
│   ├── medic.sh               ← health check (live in v0.0.1-pre1)
│   ├── spawn.sh               ← stub in v0.0.1-pre1; real in v0.0.1
│   ├── send.sh
│   ├── collect.sh
│   ├── list.sh
│   └── teardown.sh
├── commands/                  ← slash command directives (markdown; Claude reads, dispatches to bin/)
│   ├── medic.md               ← bare verbs auto-namespaced as /clone-wars:<verb>
│   ├── spawn.md
│   ├── send.md
│   ├── collect.md
│   ├── list.md
│   └── teardown.md
├── lib/                       ← shell helpers
│   ├── log.sh                 ← log_info/warn/error/ok (stderr); TTY-guarded color
│   ├── state.sh               ← $CLONE_WARS_HOME resolution; cw_repo_hash
│   ├── deps.sh                ← cw_have_cmd; tmux version + session checks
│   ├── contracts.sh           ← provider enumeration + binary lookup (awk)
│   └── (Plan B: tmux.sh, ipc.sh, commanders.sh — not yet written)
├── config/                    ← shipped defaults (copied to ~/.clone-wars/ on install)
│   ├── commanders.yaml        ← curated commander pool
│   ├── contracts.yaml         ← three default rows: claude, codex, gemini
│   ├── config.yaml            ← split direction, layout, default timeouts
│   └── identity-template.md   ← system prompt every trooper receives at spawn
└── tracer/
    └── tracer-bullet.sh       ← end-to-end validation script (build this FIRST)
```

v0.0.1-pre1 populates `.claude-plugin/`, `bin/`, `commands/`, `config/`, `lib/`, `tests/`. The
tracer-bullet under `tracer/` is the next thing to build (Plan B step 1) — don't fill it
speculatively until you've decided whether the load-bearing tmux/IPC assumptions in
`docs/DESIGN.md` actually hold on this machine.
Slash commands are markdown directives that invoke the matching `bin/*.sh` via the Bash tool — they are not themselves bash scripts.

## Design summary (one-page version)

A **conductor** is a Claude Code session running `/clone-wars:*` commands. Each command
shells out to `tmux split-window` to spawn a model TUI in a new pane the conductor's user
can attach to with `tmux select-pane`. The pane runs `codex`, `gemini`, or `claude`
interactively — not a one-shot `codex exec`. Lead and trooper communicate via files:

```
~/.clone-wars/state/<repo-hash>/<topic>/<commander>-<model>/
├── identity.md       ← system prompt injected at spawn
├── inbox.md          ← conductor writes; trooper reads on nudge; ends with END_OF_INSTRUCTION
├── outbox.jsonl      ← trooper appends; conductor tails
├── status.json       ← {state: idle|working|done|error, updated, last_event}
└── pane.json         ← {pane_id, pid, spawned_at}
```

Conductor lifecycle for one trooper:

1. **Spawn** — `tmux split-window -P -F '#{pane_id}'` captures pane ID; `tmux send-keys`
   the launch line (`env … codex --dangerously-bypass-approvals-and-sandbox`). After bootstrap,
   `tmux load-buffer` + `paste-buffer` the path of `identity.md` so the trooper reads its role.
   Wait for `{event: "ready"}` in outbox.jsonl.
2. **Dispatch** — write `inbox.md` (overwrite), terminate with `END_OF_INSTRUCTION`. Nudge the
   pane: type the inbox path. Trooper reads and ack's.
3. **Collect** — tail `outbox.jsonl` until `{event: "done"}` or `{event: "error"}`. Print summary.
4. **Teardown** — `tmux kill-pane`, `mv` state dir to `~/.clone-wars/archive/`.

## Build order

These steps are deliberate. Don't skip ahead — early steps de-risk the later ones.

### Step 1 — Tracer-bullet (`tracer/tracer-bullet.sh`)

A standalone shell script (no plugin packaging, no slash commands) that proves the
end-to-end IPC works for **one Codex pane**:

1. Pick state dir: `~/.clone-wars/state/<sha256-cwd>/tracer/rex-codex/`.
2. Write `identity.md` from `config/identity-template.md` with substitutions.
3. `tmux split-window -P -F '#{pane_id}' -h` to capture pane ID.
4. `tmux send-keys` launch line: `codex --dangerously-bypass-approvals-and-sandbox`.
5. Sleep ~3s, then `tmux load-buffer <identity.md>` + `paste-buffer -t <pane_id>` + `Enter`.
6. Poll `outbox.jsonl` for `{event: "ready"}` (timeout 30s).
7. Write `inbox.md`: "Read /tmp/clone-wars-tracer-input.md and reply with a one-line summary.\nEND_OF_INSTRUCTION".
8. Nudge: `send-keys` the inbox path.
9. Tail outbox.jsonl for `{event: "done"}` (timeout 60s).
10. Print summary, `tmux kill-pane`, archive state.

If step 5–7 surprise us (ANSI bleed, `send-keys` keymap interpretation, paste-buffer missing
characters), the design changes. **Discover those surprises before writing 5 slash commands.**

Validation: run the tracer 3 times in a row. Three clean spawns + dones = move to step 2.

### Step 2 — Provider validation

Re-run tracer-bullet against `gemini` and `claude` (just swap the contract row). Each provider
has its own bootstrap quirks (Gemini's auth flow, Claude's permissions prompt). Validate all
three before committing to the slash-command surface.

### Step 3 — `lib/` helpers

Extract the working tracer into `lib/tmux.sh`, `lib/ipc.sh`, `lib/contracts.sh`,
`lib/commanders.sh`, `lib/state.sh`. Each function should be unit-testable from bash.
Don't add abstractions until you've extracted the working code three times and seen the duplication.

### Step 4 — Slash commands

Author the six `commands/*.md` files (medic + the five orchestration verbs). Each one is a thin wrapper that sources the lib helpers
and orchestrates one user-facing operation. Aim for **<60 lines per command**; if a command is
longer, the abstraction in `lib/` is wrong.

### Step 5 — `plugin.json` + `package.json`

Marketplace metadata. Don't write these until step 4 works end-to-end. A half-built plugin in
the marketplace is worse than no plugin.

### Step 6 — Dogfood

Use Clone Wars on **one real task** — e.g. dual-model code review of a PR, or "Codex implements
while Gemini reviews." Don't generalize until you've used it for real once.

### Step 7 — README + marketplace publish

When the plugin actually works, write the user-facing `README.md` (motivation, quickstart,
six commands × example each, troubleshooting). Then publish.

### Step 8 — (Future) Strike-team integration

Once Clone Wars is stable, add a `provider:` field to `/strike-team`'s DAG so a part can be
dispatched to a Clone Wars trooper instead of a Claude teammate. That's a separate design doc
in the ARS repo, not here.

## Conventions

- **Shell**: bash 4.2+ (Linux + macOS). No bashisms past 4.2; we want broad compat.
- **No Node/Python deps in the runtime**. The plugin is pure shell + tmux + the user's
  chosen model CLI. (We might use Node for `plugin.json` packaging if Claude Code requires it,
  but never for the runtime hot path.)
- **State paths are absolute**. Always resolve `~/.clone-wars/...` to the absolute path before
  using it. Relative paths bite when the pane's cwd differs from the conductor's.
- **No `cd`** in scripts that spawn panes. Use `tmux split-window -c <abs-path>` to set the
  pane's working directory; never rely on the conductor's cwd inheriting.
- **Atomic file writes**. `status.json` and `pane.json` are written via `tmp + rename` to avoid
  partial reads. `outbox.jsonl` is append-only single-line JSON.
- **No emojis** in shipped output unless the user explicitly opts in. Preserves grep-ability.
- **Errors go to stderr, not outbox**. The plugin's CLI errors go to the conductor's terminal;
  the trooper's outbox is reserved for trooper-side events.

## Things to verify in the tracer (the load-bearing unknowns)

These are the questions DESIGN.md flagged. Tracer-bullet answers them empirically:

1. **`tmux send-keys` vs `tmux load-buffer + paste-buffer`** for typing the launch command and
   inbox path nudges. Send-keys streams character-by-character (interpreted by the TUI's
   keymap); paste-buffer pastes the whole string atomically. Paste-buffer should be more
   robust for multi-line content. Verify with codex specifically.
2. **Default ready timeout per provider**. Codex starts in ~5s, Gemini ~3s, Claude ~10s on
   reasonable hardware. 30s default is conservative. Measure actual cold-start in tracer logs.
3. **ANSI escape contamination of outbox.jsonl**. The trooper must `tee` plain-text events;
   if any terminal escape codes leak, the JSONL parse fails. Identity prompt forbids this,
   but verify in tracer that the model actually obeys.
4. **`END_OF_INSTRUCTION` sentinel race**. Trooper polls inbox.md; if it polls between the
   conductor's `truncate` and `write`, it sees an empty file. Sentinel guarantees correctness:
   trooper waits for last-line == `END_OF_INSTRUCTION` before reading. Confirm with a
   stress test (rapid send-collect cycles).
5. **Pane-cleanup semantics**. If the conductor (Claude Code) crashes, panes survive. If the
   user kills the conductor pane via tmux, are the trooper panes orphaned correctly?
   Verify and document.

## What is explicitly out of scope

Re-stating from `docs/DESIGN.md` so you don't drift:

- Worktree isolation per pane.
- Role routing / tier models (orchestrator/planner/executor abstractions).
- Tier-based model fallback chains.
- Multi-conductor coordination (>1 Claude Code session sharing crews).
- MCP server interface (we want CLI panes, not in-process subagents).
- Standalone CLI (`clone-wars team ...` from a bare terminal). Slash commands only for v1.
- DeepSeek and arbitrary OpenAI-compat providers. Closed set: claude / codex / gemini.
- Auto-decompose / planning. The conductor decides decomposition; the plugin only dispatches.
- HUD / Telegram / mobile control / learning / pattern extraction. All rejected.

If you find yourself adding any of these, stop and write a separate design doc justifying it.
The whole point of Clone Wars is to be smaller than OMC.

## Reference repos to mine

- **`/home/liupan/ref/oh-my-claudecode`** — the source pattern. Specifically:
  - `bridge/cli.cjs:28553` — `CONTRACTS` table (claude/codex/gemini launch flags).
  - `bridge/cli.cjs:28825` — `buildWorkerStartCommand` (env + shell + rc + exec).
  - `bridge/cli.cjs:28950` — `createTeamSession` (split-window orchestration).
  - `bridge/cli.cjs:29088` — `spawnWorkerInPane` (send-keys to start the worker).
  - `bridge/team-bridge.cjs:255` — `TeamPaths` (inbox/outbox/heartbeat layout).
  - `docs/TEAM-WORKTREE-MODE.md` — the worktree-isolation contract (future-feature reference).
- **`/home/liupan/ARS/docs/designs/2026-04-25-clone-wars-plugin.md`** — the original design doc.
  Use `docs/DESIGN.md` (this repo's copy) as canonical going forward; the ARS copy will become
  a redirect or get deleted.

## Local development

- **Working dir**: `/home/liupan/CC/clone-wars` (this repo).
- **Test environment**: any tmux session. Run `tmux` first if you're not already in one.
- **Required CLIs for full testing**: `tmux`, `codex`, `gemini`, `claude`. Use `command -v <name>`
  to detect; skip provider tests if a binary is missing.
- **Sandboxing**: tracer-bullet runs in `/tmp/clone-wars-tracer-<ts>/` to avoid polluting the
  repo. State dirs go to `~/.clone-wars/state/...` (the canonical location).

## Conventional commits

This repo follows Conventional Commits loosely: `feat:`, `fix:`, `docs:`, `test:`, `chore:`,
`refactor:`. No CI enforcement, just consistency. Examples:

- `feat(tracer): add codex spawn + send + collect tracer-bullet`
- `feat(commands): scaffold clone-wars-spawn`
- `docs(design): clarify END_OF_INSTRUCTION sentinel semantics`
- `fix(tmux): use paste-buffer instead of send-keys for inbox nudge`

## Status

- [x] Design doc written
- [x] Repo created on GitHub (`WingsOfPanda/clone-wars`)
- [x] Local scaffolding (CLAUDE.md, docs/, commands/, lib/, config/, tracer/)
- [x] Marketplace shell (.claude-plugin/{plugin,marketplace}.json)
- [x] `lib/` helpers — log, state, deps, contracts (tmux/ipc/commanders pending Plan B)
- [x] `/clone-wars:medic` (live; spawn/send/collect/list/teardown stubbed)
- [x] User-facing README (v0.0.1-pre1 marketplace listing)
- [x] Marketplace publish (v0.0.1-pre1 tagged + pushed; install path live)
- [x] Tracer-bullet for codex
- [x] Real implementations of spawn/send/collect/list/teardown (v0.0.6+)
- [x] v0.1.x: dual-model consult command (cross-verified investigation)
- [x] v0.2.0: split-orchestrator consult — Master Yoda reachable between every step
- [x] v0.2.1: citation-overlap robustness + Master Yoda role rename
- [x] v0.3.0: trooper question protocol + skill routing (brainstorming/systematic-debugging)
- [ ] v0.3.0 strict-dogfood pass on a real machine (release gate)
- [x] v0.4.0: design-doc mode — opt-in brainstorming-style spec output (Step 8.5)
- [x] v0.4.1: design-doc mode — header-extraction polish (title, goal, arch-line)
- [x] v0.4.2: design-doc mode — codex adversarial-review fixes (atomic write, hash filename, teardown order, always-offer prompt, drill-both, token-flag parse)
- [x] v0.5.0: octogent-steals — prompt-template registry, stale state, cw_send --from, background-await pattern
- [x] v0.5.1: rename background-await `description=` strings to `master yoda await <rank-prefixed trooper> <phase>` form + identity-template now tells troopers to run their own tool-use foreground (only Yoda backgrounds; troopers stay foreground in their own pane)
- [x] v0.5.2: remove `$CLONE_WARS_HOME/identity-template.md` from `cw_identity_write` lookup chain — stale per-machine overrides silently shadowed v0.5.x prompt-template updates; lookup is now in-tree only (matches v0.5.0's "no overrides" decision); medic warns when an orphan state-root copy is detected
- [x] v0.5.3: extract Step 8.5 drill code into `bin/consult-drilldown.sh` (escapes the slash-command renderer's `$1/$2/$3` positional substitution that clobbered bash function args on multi-word topics) + identity-template gains "safe JSONL emission" guidance to prevent `printf '%2C'` format-string failures observed in dogfood
- [x] v0.6.0: execute-design — codex-implements + yoda-verifies pipeline
- [x] v0.6.1: drilldown scratch subdir + execute-design source-defaulting prefers design-doc + CW_EXECUTE_FIX_TIMEOUT env var + parameterized wait-script test
- [x] v0.7.0: rename `/clone-wars:execute-design` → `/clone-wars:deploy` + hide internal slash commands (`spawn`/`send`/`collect`); user-facing surface is now medic/consult/deploy/list/teardown
- [ ] v0.7.0 strict-dogfood pass on a real machine (release gate)
- [ ] v0.6: drop config/identity-template.md back-compat symlink + sweep tracer/*.sh + README.md legacy refs
- [ ] Submit to claude-plugins-official (post v0.5.x dogfood)
