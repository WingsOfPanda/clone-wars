# Clone Wars — Multi-Model Tmux Pane Plugin

**Date**: 2026-04-25
**Status**: Draft
**Author**: liupan
**Plugin name**: `/clone-wars`
**Plugin scope**: standalone Claude Code plugin (separate repo, not part of ARS)
**ARS relation**: design parented in ARS for now; plugin will move to its own repo when scaffolded

## Problem

Today, ARS multi-agent commands spawn teammates via Claude Code's
`Agent + TeamCreate` primitive. This works well — Claude Code auto-renders teammates as tmux panes
the Admiral can attach to and watch live. But every teammate is a `claude` instance. When a teammate
needs to invoke a different model (Codex for heavy implementation, Gemini for long-context reasoning),
it shells out via `codex-companion task --prompt-file` as a hidden subprocess. That subprocess:

- Cannot be attached to or interrupted live
- Runs in fresh-context mode, losing conversation across rounds
- Adds a third invisible layer (Lead Claude → Teammate Claude → Codex subprocess)
- Burns Claude tokens on the orchestrator-of-Codex layer

The Admiral pays for visibility everywhere except the layer doing the actual work.

## Goal

A standalone Claude Code plugin that lets a Claude Code conductor spawn and orchestrate **real
interactive model TUIs** (`codex`, `gemini`, `claude`) as tmux panes — same visibility the
existing teammates have, but for non-Claude models. File-based IPC (inbox/outbox/status) replaces
`SendMessage`. The Admiral can `tmux attach` to any pane and watch the model think.

## Non-goals

- Worktree isolation per pane (defer; OMC's `TEAM-WORKTREE-MODE.md` is a future option)
- Role routing / tier models (orchestrator/planner/executor abstraction — out of scope)
- MCP server integration (we want CLI panes, not in-process subagents)
- Multi-conductor coordination (one Claude Code session = one set of crews)
- Standalone CLI surface (no `clone-wars team ...` from a bare terminal — slash-commands only)
- Generic OpenAI-compat providers — LM Studio, ollama, vLLM, DeepSeek-via-other-clients (closed set: claude / codex / gemini / opencode → DeepSeek V4 Pro, pinned)
- Replacing the existing ARS multi-agent commands (they keep working; clone-wars is additive)
- Learning / pattern extraction / HUD / Telegram (OMC sprawl we explicitly reject)

## Why a separate plugin (not folded into ARS multi-agent commands)

The existing ARS multi-agent commands already work. Folding multi-model dispatch into them up-front
risks regressing flows that ship today. Clone-wars is the **primitive**: spawn-pane, send-inbox,
collect-outbox, teardown. After dogfooding it on real tasks, those commands can be extended so a DAG
part has a `provider:` field that routes to a clone-wars trooper instead of a Claude teammate.
Order: build primitive → use it → harvest into the bigger commands.

## Architecture

```
Conductor (Claude Code, your terminal — runs /clone-wars-* commands)
    │
    ├── tmux split-window per clone trooper ───► visible panes you can attach
    │       ├── rex-codex          — interactive `codex` TUI
    │       ├── cody-gemini        — interactive `gemini` TUI
    │       └── wolffe-claudecode  — interactive `claude` TUI
    │
    └── State plane: ~/.clone-wars/state/<repo-hash>/<topic>/<commander>-<model>/
            ├── identity.md       ← system prompt injected at spawn
            ├── inbox.md          ← conductor writes; trooper reads on nudge
            ├── outbox.jsonl      ← trooper appends; conductor tails
            ├── status.json       ← {state: idle|working|done|error, updated: <iso>}
            └── pane.json         ← {pane_id, pid, spawned_at}  (registry)
```

### Pane identity scheme

Every pane is identified by `<commander>-<model>-<topic>`:

- **`commander`** — clone-trooper proper name from a curated pool (Rex, Cody, Wolffe, Bly, Fox, Gree, Ponds, Bacara, Neyo, Doom, Faie, Hunter, Wrecker, Tech, Crosshair, Echo, Fives, Jesse, Kix, Tup, Dogma, Hardcase, Thorn, Thire, Stone, Bow, Keeli, Trauma, Blackout, Colt, Havoc, Vill, Deviss). User-editable list at `~/.clone-wars/commanders.yaml`.
- **`model`** — one of `codex`, `gemini`, `claudecode`. Closed set (extensible by editing `~/.clone-wars/contracts.yaml`).
- **`topic`** — short slug describing the operation this pane serves on (`auth-review`, `ui-redesign`, `migration`). Sanitized to `[a-z0-9-]`, ≤32 chars.

Examples:
- `rex-codex-auth-review` — Rex (codex pane) reviewing auth
- `cody-gemini-ui-redesign` — Cody (gemini pane) on UI redesign
- `wolffe-claudecode-migration` — Wolffe (claude-code pane) running a migration

The **topic doubles as the implicit crew name**. Listing or teardown can scope by topic:
`/clone-wars:list auth-review` shows every trooper on that operation; `/clone-wars:teardown auth-review`
kills all of them.

### Commander uniqueness rules

- **Within a topic**: commander name MUST be unique. Two Rexes on `auth-review` is an error at spawn.
- **Across topics**: commander name MAY repeat (Rex on `auth-review` + Rex on `ui-redesign` simultaneously is allowed) — but the spawn command emits a soft warning and suggests unused alternatives. Discouraged, not forbidden.
- **`random` keyword**: `/clone-wars:spawn random codex <topic> "..."` picks an unused commander, biased toward globally-unused first, then topic-unused, then any from the pool.

## Slash commands

Six commands. Five orchestration verbs (spawn/send/collect/list/teardown) plus medic
(health check). No more until proven necessary.

### `/clone-wars:spawn <commander> <model> <topic> [--mode <full|read-only>] [initial-prompt]`

Spawns a new tmux pane running the given model's CLI binary, registers state, injects identity prompt.

- Validates commander/model/topic; rejects duplicates within a topic.
- Resolves contract from `~/.clone-wars/contracts.yaml` (`binary`, `args`, `env`).
- `tmux split-window -P -F '#{pane_id}' -h -t <conductor-pane> -c <cwd>` — captures pane ID atomically.
  - First clone in topic: split right (`-h`).
  - Second+: split down (`-v`) of previous clone.
  - After 3+ panes: re-apply `select-layout main-vertical` for legibility.
  - All directions configurable via `~/.clone-wars/config.yaml`.
- `tmux send-keys` builds the launch line: `env <env> <binary> <args>` then Enter.
- Polls `outbox.jsonl` for `{event: "ready"}` (timeout 30s default; 60s for `claudecode`). On timeout: kill pane, error.
- Writes `pane.json` with the captured pane ID and PID for the registry.
- If `initial-prompt` is given, immediately follows up with the equivalent of `/clone-wars:send`.
- Returns: pane ID + state directory path.

`--mode` selects which arg set the contract row maps to (`full` = yolo / bypass;
`read-only` = sandboxed). Omitting it falls through to the row's `default_mode`.
See the marketplace-prep design spec (`docs/superpowers/specs/2026-04-25-clone-wars-marketplace-prep-design.md` §4)
for the contracts.yaml shape and per-provider mappings.

### `/clone-wars:send <commander> <topic> <message-or-@file>`

Writes a message to the trooper's inbox and nudges the pane to read it.

- Resolves the trooper from `<commander>-<topic>` (model is implicit by registry lookup).
- `<message-or-@file>`: literal string OR `@<path>` for a file (read+inline). Supports multi-line via heredoc-like quoting in shell.
- Writes `inbox.md` (overwrite or append? **overwrite** — single-message-at-a-time semantics, simpler. Each send replaces the previous. If you want a queue, use `/clone-wars:send` repeatedly with `--wait` flag that blocks until previous is done.)
- Appends `END_OF_INSTRUCTION\n` sentinel.
- `tmux send-keys -t <pane_id>` types the path: `Read .clone-wars/...inbox.md and execute.` then Enter.
  - `send-keys -l` (literal) for the path text to avoid keymap interpretation.
  - Followed by `Enter` to commit.
- Default behavior: **fire-and-forget** (returns immediately). Pair with `/clone-wars:collect` if you want sync.
- Updates `status.json` to `{state: "queued"}` after writing.

### `/clone-wars:collect <commander> <topic> [--timeout <sec>]`

Blocks until the trooper's outbox has a `{event: "done"}` or `{event: "error"}` event, then prints
the most recent assistant output (the `summary` field of `done` or `message` field of `error`).

- Reads `outbox.jsonl` line-by-line; tails new lines via Monitor-equivalent loop.
- Default timeout: 600s (10 min). Configurable per-call.
- On timeout: returns the last `{event: "progress"}` note + warning.
- Stays clean (no piping ANSI escapes); the trooper is responsible for plain-text outbox writes.

### `/clone-wars:list [<topic>]`

Shows the active troopers (panes + state).

- No arg: every active trooper across every topic, grouped by topic.
- With `<topic>` arg: scoped to that topic only.
- Per row: commander, model, topic, status (from status.json), pane alive (`tmux list-panes` cross-check), pane ID (so user can `tmux select-pane -t <id>` to attach).
- Detects orphans: state dir exists but pane is dead (`kill -0 <pid>` fails OR `tmux list-panes` doesn't include the pane ID). Emits `[ORPHAN]` flag and recommends `/clone-wars:teardown <commander> <topic>`.

### `/clone-wars:teardown [<commander>] [<topic>]`

Kills panes and archives state.

- `/clone-wars:teardown` — refuses without scope (safety: don't accidentally nuke everything). Suggests `--all` flag for the explicit version.
- `/clone-wars:teardown <topic>` — kills all troopers on that topic, archives state to `~/.clone-wars/archive/<repo-hash>/<topic>-<timestamp>/`.
- `/clone-wars:teardown <commander> <topic>` — kills just that trooper, archives only its state dir.
- `--all` flag — kills every trooper in every topic. Requires confirmation.
- Sends `tmux kill-pane -t <pane_id>`, then `mv` state dir to archive. Archive is forensic — if a deploy was driven by clone-wars and a bug surfaces a week later, the state dir tells you exactly what each trooper was told and what it reported.

### `/clone-wars:medic`

Health check — verifies the host can run Clone Wars. Checks tmux presence + version
(>= 3.0), `$CLONE_WARS_HOME` writability, presence of `contracts.yaml` + `commanders.yaml`
+ `identity-template.md` in the state root, and per-provider binary availability.

Missing providers are WARN, not FAIL — the plugin is usable as long as at least one
provider in `contracts.yaml` is healthy. Verdict is `OK — ready to spawn (N/M providers
available)` or `FAIL — fix items above`. Exit code mirrors the verdict (0/1).

Spec: `docs/superpowers/specs/2026-04-25-clone-wars-marketplace-prep-design.md` §6.

## File-IPC protocol

### `inbox.md`

Plain markdown. Conductor overwrites this file completely on each `/clone-wars:send`. Last line MUST be `END_OF_INSTRUCTION` so the trooper knows it has the full message and isn't reading mid-write.

```markdown
# Task: review auth flow

Read `src/auth/oauth.py` and report:
- Token-refresh edge cases
- Whether session expiry handling is correct
- Specific lines that are concerning

Reply with a JSON outbox event when done.

END_OF_INSTRUCTION
```

### `outbox.jsonl`

JSONL, append-only. One event per line. Required event types:

```jsonl
{"event": "ready", "ts": "2026-04-25T20:30:00Z"}
{"event": "ack", "ts": "...", "task_summary": "Review auth flow"}
{"event": "progress", "ts": "...", "note": "Reading src/auth/oauth.py..."}
{"event": "progress", "ts": "...", "note": "Found 3 concerning patterns..."}
{"event": "done", "ts": "...", "summary": "Auth review complete. See findings.md.", "artifacts": ["findings.md"]}
```

Or on failure:

```jsonl
{"event": "error", "ts": "...", "message": "Cannot read file: permission denied", "fatal": false}
```

`fatal: true` means the trooper is unrecoverable and recommends teardown. `fatal: false` means
the trooper is still alive and the conductor can retry with a new inbox.

### `status.json`

Single JSON object, overwritten atomically (write to `.tmp` + rename):

```json
{
  "state": "idle",
  "updated": "2026-04-25T20:30:00Z",
  "current_task_summary": null,
  "last_event": "done"
}
```

States: `bootstrapping` → `idle` → `queued` → `working` → `idle|done|error`.

The trooper updates this after every outbox event. The conductor reads it for `/clone-wars:list`.

## Provider contracts

`~/.clone-wars/contracts.yaml` ships with four rows. User-editable.

```yaml
claude:
  binary: claude
  args:
    - --dangerously-skip-permissions
  model_flag: --model
  ready_timeout_s: 60
  identity_injection: send-keys-paste
codex:
  binary: codex
  args:
    - --dangerously-bypass-approvals-and-sandbox
  model_flag: --model
  ready_timeout_s: 30
  identity_injection: send-keys-paste
gemini:
  binary: gemini
  args:
    - --approval-mode
    - yolo
  model_flag: --model
  ready_timeout_s: 30
  identity_injection: send-keys-paste
opencode:                                # v0.13.0
  binary: opencode
  args:
    - -m
    - deepseek/deepseek-v4-pro           # pinned to DeepSeek V4 Pro
  ready_timeout_s: 60
  bootstrap_sleep_s: 15
  identity_injection: send-keys-paste
  # opencode has no CLI flag for auto-approve; bypass is config-file driven.
  # medic.sh runs a preflight that warns when opencode.json lacks
  # top-level `"permission": "allow"`. Spawn does NOT refuse in v0.13.0
  # (warn-only); user attaches via `tmux select-pane` to dismiss prompts.
```

`identity_injection: send-keys-paste` means: write `identity.md` to disk, then
`tmux load-buffer` + `tmux paste-buffer -t <pane>` the path, then send `Enter`. This avoids the
keymap-interpretation issues of typing every character via `send-keys`.

## Identity prompt template

Located at `~/.clone-wars/identity-template.md`. Variables substituted at spawn time:

```markdown
You are **{{commander}}**, a {{model}}-class clone trooper assigned to operation **{{topic}}**.

Your inbox: `{{state_dir}}/inbox.md`
Your outbox: `{{state_dir}}/outbox.jsonl`
Your status: `{{state_dir}}/status.json`

The conductor (your commanding officer in Claude Code) will write inbox.md and nudge you with
its path. **Do not begin until the inbox ends with `END_OF_INSTRUCTION`** — that sentinel
guarantees the message is complete and you're not reading mid-write.

Report progress via JSONL events appended to outbox.jsonl. Required event types:
- `{"event": "ack", "task_summary": "...", "ts": "<iso>"}` — acknowledge new inbox
- `{"event": "progress", "note": "...", "ts": "<iso>"}` — periodic updates
- `{"event": "done", "summary": "...", "artifacts": [...], "ts": "<iso>"}` — task complete
- `{"event": "error", "message": "...", "fatal": <bool>, "ts": "<iso>"}` — failure

After every event, update status.json with `{"state": "<state>", "updated": "<iso>", "last_event": "<event>"}`.

Stay in your pane between assignments — do **not** exit. After `done` or `error`, set status to
`idle` and wait for the next inbox.

When you receive your first inbox, output `{"event": "ack", ...}` first to confirm receipt before
beginning work.

*Roger that, Commander.*
```

The last line is flavor but anecdotally helps models stay in role.

## State directory layout

```
$CLONE_WARS_HOME/   # default ~/.clone-wars; override via env var
├── config.yaml              ← split direction, layout policy, default timeouts
├── commanders.yaml          ← curated commander pool, user-editable
├── contracts.yaml           ← per-provider launch contract, user-editable
├── identity-template.md     ← system prompt template
├── repo-hash-map.json       ← {<sha256-of-cwd>: <readable-cwd>} for /clone-wars:list
├── state/
│   └── <repo-hash>/         ← sha256(cwd) — multi-repo isolation
│       └── <topic>/         ← e.g. auth-review
│           └── <commander>-<model>/   ← e.g. rex-codex
│               ├── identity.md
│               ├── inbox.md
│               ├── outbox.jsonl
│               ├── status.json
│               └── pane.json
└── archive/
    └── <repo-hash>/
        └── <topic>-<timestamp>/    ← teardown moves state here
```

## Pane layout

Default sequence (configurable in `~/.clone-wars/config.yaml`):

- 1st clone in a topic → split **right** (`-h`) of conductor pane
- 2nd → split **down** (`-v`) of 1st clone
- 3rd → split **down** of 2nd clone
- 4th+ → continue down, then re-apply `select-layout main-vertical` to even out

```yaml
# ~/.clone-wars/config.yaml
split:
  primary: right       # right | left | up | down
  secondary: down      # right | left | up | down
  layout: main-vertical  # main-vertical | even-horizontal | even-vertical | tiled
ready_timeout_default_s: 30
collect_timeout_default_s: 600
```

## Failure modes + recovery

| Failure | Detection | Recovery |
|---|---|---|
| Pane dies silently (model crash, segfault) | `tmux list-panes` doesn't include pane ID; OR `kill -0 <pid>` fails | `/clone-wars:list` flags `[ORPHAN]`; user runs teardown |
| Conductor (Claude Code) crashes mid-task | Panes keep running; state dirs persist | New conductor session: `/clone-wars:list` shows still-alive panes; resume via `/clone-wars:send` |
| ANSI bleed into outbox.jsonl (model writes terminal escape codes) | First broken JSONL line | Identity prompt explicitly forbids terminal-escape output in outbox; verify in tracer |
| Inbox written mid-read by trooper | Race possible if trooper polls aggressively | `END_OF_INSTRUCTION` sentinel: trooper reads only when sentinel is the last line |
| `tmux send-keys` interleaves with TUI rendering | Garbled launch | Use `tmux load-buffer` + `paste-buffer` instead of streaming `send-keys`; followed by single Enter |
| Two conductors race on same trooper | Both write inbox.md | First conductor wins; sentinel guarantees atomicity. Second conductor's write overwrites — out of scope, single-conductor model |
| Stale state from previous deploy | State dir exists but no pane | `/clone-wars:list` flags orphan; `/clone-wars:teardown` archives even orphans cleanly |
| Commander name reused on same topic | Spawn-time check | Hard error: "Rex is already deployed on auth-review. Pick another commander or `/clone-wars:teardown rex auth-review` first." |
| Commander reused across topics | Spawn-time check | Soft warning: "Rex is on auth-review (codex). Spawning second Rex on ui-redesign. Consider: Cody, Wolffe, Bly..." |
| Provider binary not on PATH | Pre-spawn check (`command -v <binary>`) | Hard error with install hint from contract |

## Acceptance criteria — tracer-bullet validation (HISTORICAL — v0.0.x)

The tracer-bullet validation scripts under `tracer/` were used during v0.0.x
to prove tmux/IPC mechanics before slash-command surface was authored. They
were deleted in v0.29.0 (see `docs/superpowers/specs/2026-05-13-v0.29.0-simplification-sweep-design.md`).
The IPC mechanics they validated are now exercised continuously by
`tests/test_*.sh` (~170 files) and the slash commands themselves
(`/clone-wars:medic`, `/clone-wars:consult`, `/clone-wars:meditate`,
`/clone-wars:deep-research`, `/clone-wars:deploy`).

## Out-of-scope (explicitly)

The following are deferred or rejected to keep scope honest:

- **Worktree isolation** — every clone shares the conductor's cwd. If two clones edit the same file, last writer wins. Future: opt-in via OMC's `TEAM-WORKTREE-MODE.md` pattern.
- **Role routing** — clones are dumb workers, not roles like "planner" or "executor." If you want role behavior, write it into the inbox.
- **Tier models / model fallback** — clones use the model the contract specifies; no automatic upgrade/downgrade.
- **Multi-conductor** — assumes one Claude Code session orchestrates. Two conductors writing the same inbox is a race the plugin won't protect against.
- **Worker-side learning / pattern extraction** — out.
- **HUD / Telegram / mobile control** — out.
- **MCP server** — out. Clones are CLI panes, not MCP services.
- **CLI surface** — `clone-wars team ...` from a bare terminal is rejected for v1. Slash commands only.
- **Auto-decompose** — the conductor (Claude Code) decides task decomposition; the plugin just dispatches.

## Workflow after this change

```
liupan: I want to review the auth flow with multiple models.

claude: /clone-wars:spawn rex codex auth-review "Review src/auth/oauth.py for token-refresh edge cases"
[pane appears, splits right; Codex TUI starts]
[outbox: ready, ack, progress: 'Reading oauth.py...', progress: 'Found 3 patterns', done]

claude: /clone-wars:spawn cody gemini auth-review "Review src/auth/oauth.py for long-context cross-references with src/session/manager.py"
[pane splits down of rex; Gemini TUI starts]

claude: /clone-wars:collect rex auth-review
[returns Codex's summary]

claude: /clone-wars:collect cody auth-review
[returns Gemini's summary]

claude: [synthesizes both findings, shows liupan]

liupan: looks good, teardown

claude: /clone-wars:teardown auth-review
[both panes killed, state archived]
```

The conductor is doing what conductors do: orchestrate. The plugin is doing what it does:
spawn panes, route messages, collect results.

## Order of operations to build

1. **This design doc** — frozen reference (now).
2. **Tracer-bullet** (HISTORICAL — deleted v0.29.0) — was a standalone script under
   `tracer/` that proved end-to-end spawn → send → collect → teardown on one codex
   pane. Validated IPC and `send-keys` mechanics before plugin packaging. Now
   superseded by the v0.x test suite and the slash commands themselves.
3. **Repo creation** — once tracer works and design feels right, `gh repo create clone-wars --public`
   and commit the design doc + tracer as initial commit.
4. **Plugin scaffold** — turn tracer into the 5 slash commands + lib/ helpers. ~400 lines total.
5. **Dogfood** — use clone-wars on one real task (e.g. dual-model code review of an ARS PR).
6. **Iterate** — fix what hurts based on dogfooding.
7. **Marketplace publish** — once stable, publish to claude-plugins-official or a personal marketplace.
8. **Strike-team integration (future)** — add `provider:` field to DAG parts so strike-team can
   spawn clone-wars troopers instead of Claude teammates.

## Open questions (pre-tracer)

1. **`tmux send-keys` vs `paste-buffer`** for typing the launch command and inbox-path nudges —
   test both in tracer; pick whichever survives ANSI/keymap edge cases.
2. **Default ready timeout** — Codex starts in ~5s, Gemini ~3s, Claude ~10s. 30s default sounds
   safe but verify in tracer.
3. **Inbox semantics** — overwrite vs queue. Spec'd as overwrite for v1; revisit if dogfooding
   reveals queue is needed (probably is, for multi-step tasks).
4. **Cleanup on Claude Code session exit** — should clones survive the conductor exit, or auto-teardown?
   Spec'd as survive (resume with new conductor); revisit if orphans accumulate.
5. **Pane size on small terminals** — main-vertical layout collapses badly under ~100 columns.
   Document, don't auto-fix.

## Execution Report

(empty — to be filled when the plugin scaffolds and ships)
