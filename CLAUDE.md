# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Clone Wars — what this is

A Claude Code **plugin** that lets a Claude Code session orchestrate
multiple model TUIs (`codex`, `gemini`, `claude`, `opencode`) as **real tmux
panes** the user can attach to and watch live. File-based IPC (inbox / outbox /
status) replaces in-process `SendMessage`. Pane identity follows clone-trooper
naming: `<commander>-<model>-<topic>` (e.g. `rex-codex-auth-review`). The plugin
is deliberately the trimmed primitive — see `## What is explicitly out of scope`
below for the closed-set boundary.

## Canonical references

- **`docs/DESIGN.md`** — architecture, IPC protocol, contracts table, identity
  prompt. Read first when changing the runtime.
- **`docs/CHANGELOG.md`** — every shipped release, newest-first. Per-version
  release-gate dogfood status lives here.
- **`docs/superpowers/specs/`** — per-version design docs (frozen at design
  time; the design trail for every feature).
- **`docs/superpowers/plans/`** — implementation plans paired with specs.
- **`/home/liupan/ref/oh-my-claudecode`** — the source pattern (grep for
  `CONTRACTS`, `buildWorkerStartCommand`, `createTeamSession` if you need the
  reference implementation; line numbers drift — search by symbol).

## Current focus

- **Most recent merge:** v0.48.0 (deep-research halt + scoreboard
  rendering — closes 7 of 13 archive-triage findings via 2 helpers
  extracted helper-first, then migrated; halt.flag newlines now
  preserved, prose-format halts render correctly, scoreboard has
  multi-key sort + %.4f/%.2fs formatting + schema_version=2 marker).
- **Next priority:** v0.49 — state-file hygiene cleanup (#8 archive
  timestamp drift, #9 lane_abandon_reason fragility, #10 stale
  probe_sent_ts, #12 halt.flag field-name rename). Spec at
  `docs/superpowers/specs/2026-05-20-v0.48-v0.49-deep-research-archive-fixes-design.md`.
- **No code freeze.** Feature work in flight should still go through
  the brainstorm → spec → plan → PR loop per `docs/superpowers/`.

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
└── config/                    ← shipped defaults (copied to ~/.clone-wars/ on install)
    ├── commanders.yaml        ← curated commander pool
    ├── contracts.yaml         ← three default rows: claude, codex, gemini
    ├── config.yaml            ← split direction, layout, default timeouts
    └── identity-template.md   ← system prompt every trooper receives at spawn
```

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

## Execution discipline in this repo

This repo's release pattern (test suite green → version bump → static-wiring
lock → PR) runs many bash blocks in sequence. A few rules that aren't obvious
from the code:

- **Background bash is fire-and-notify.** When you run `bash tests/run.sh` with
  `run_in_background: true`, the harness sends one `<task-notification>` when it
  exits. Continue with other work in the meantime; do NOT poll, do NOT schedule
  a second background task to wait for the first. Your global
  `~/.claude/CLAUDE.md` has the canonical version — this is the repo-local
  restatement so you don't drift.
- **Version-stamped static-wiring locks have skip-guards.** Tests like
  `test_v0_38_0_static_wiring.sh` check `plugin.json` version and `exit 0` if
  the version doesn't match. A locked test that "passes via skip" is not a
  regression — bump the version when you intentionally add the next-version's
  invariants.
- **Read-before-Edit on plugin.json / marketplace.json / CLAUDE.md.** These get
  touched in late stages of a release PR; if the linter or a sibling task races,
  Re-Read then Edit (recovery is one step; do not stop or pivot).
- **Brainstorm before feature/UX changes** (per saved feedback memory).
  Documentation-only changes (`docs:` commits) skip the brainstorm gate;
  spec/plan pairs still go under `docs/superpowers/{specs,plans}/`.

## What is explicitly out of scope

Re-stating from `docs/DESIGN.md` so you don't drift:

- Worktree isolation per pane.
- Role routing / tier models (orchestrator/planner/executor abstractions).
- Tier-based model fallback chains.
- Multi-conductor coordination (>1 Claude Code session sharing crews).
- MCP server interface (we want CLI panes, not in-process subagents).
- Standalone CLI (`clone-wars team ...` from a bare terminal). Slash commands only for v1.
- Generic OpenAI-compat providers (LM Studio, ollama, vLLM, DeepSeek-via-other-clients).
  Closed set: claude / codex / gemini / opencode (pinned to DeepSeek V4 Pro).
  Justification for opencode (v0.13.0): model diversity beyond the Western houses;
  pinned to one model to preserve "smaller than OMC" thesis. Generic open-set still rejected.
- Auto-decompose / planning. The conductor decides decomposition; the plugin only dispatches.
- HUD / Telegram / mobile control / learning / pattern extraction. All rejected.

If you find yourself adding any of these, stop and write a separate design doc justifying it.
The whole point of Clone Wars is to be smaller than OMC.

## Local development

- **Working dir**: `/home/liupan/CC/clone-wars` (this repo).
- **Test environment**: any tmux session. Run `tmux` first if you're not already in one.
- **Required CLIs for full testing**: `tmux`, `codex`, `gemini`, `claude`, `opencode`. Use
  `command -v <name>` to detect; skip provider tests if a binary is missing.
- **State**: per-project state lives in `<repo>/.clone-wars/` (auto-`*`-gitignored);
  per-machine config + archive lives in `~/.clone-wars/`. See v0.38.0 in CHANGELOG.

## Conventional commits

This repo follows Conventional Commits loosely: `feat:`, `fix:`, `docs:`, `test:`, `chore:`,
`refactor:`. No CI enforcement, just consistency. Examples:

- `feat(consult): add 3-trooper adjudicate output`
- `feat(commands): scaffold clone-wars-spawn`
- `docs(design): clarify END_OF_INSTRUCTION sentinel semantics`
- `fix(tmux): use paste-buffer instead of send-keys for inbox nudge`
