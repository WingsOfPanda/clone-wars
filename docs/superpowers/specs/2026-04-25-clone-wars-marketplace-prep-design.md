# Clone Wars — Marketplace-Prep Design

**Date**: 2026-04-25
**Status**: Draft (post-brainstorm, pre-implementation)
**Author**: liupan
**Scope**: marketplace-publish surface for the `clone-wars` plugin (manifest, naming, permissions,
configurability, README, versioning). **Not** the IPC/tmux internals — those remain in
`docs/DESIGN.md` and will be re-locked after the tracer-bullet validates load-bearing assumptions.
**Supersedes**: nothing. Pairs with `docs/DESIGN.md` (the runtime design).

## Why this spec exists

`docs/DESIGN.md` answers *what Clone Wars does*. It does not answer *how it ships*. Before we write
the tracer-bullet and the five slash commands, we need to lock the publish surface: what the plugin
is named, where it lives, how it's installed, what permissions it asks for, how its trooper-mode
configurability works, and what users see in the marketplace listing.

These decisions block scaffolding (the names go into file paths and manifest fields) and they
should be locked *before* the tracer-bullet so the tracer can use the production identifiers from
day one — no rename pass later.

The runtime/IPC design questions (8 inconsistencies flagged on initial read of `DESIGN.md` plus 5
open questions in that doc itself) are explicitly *deferred*. They get answered with evidence from
the tracer, not more armchair argument.

## Decisions locked

### 1. Marketplace target

Single repo (`WingsOfPanda/clone-wars`) is both the plugin and the marketplace. The pattern matches
oh-my-claudecode: `.claude-plugin/marketplace.json` co-located with `.claude-plugin/plugin.json`,
`marketplace.json` lists exactly one plugin entry with `"source": "./"`. No separate
`WingsOfPanda/claude-plugins` umbrella repo.

Install path:

```
/plugin marketplace add WingsOfPanda/clone-wars
/plugin install clone-wars@clone-wars
```

Submission to `claude-plugins-official` is **deferred** until after dogfood (CLAUDE.md status
step 6) — earliest at v1.0.0. Verifying that marketplace's submission policy (community
submissions vs. Anthropic-internal-only) is a one-line check we'll do at submission time, not now.

### 2. Plugin identifier and command namespace

- `plugin.json` field: `"name": "clone-wars"`.
- `marketplace.json` field: `"name": "clone-wars"` (matches plugin name; no abbreviation).
- Slash commands use the colon-namespacing convention that the runtime auto-applies: command files
  live as bare verbs in `commands/<verb>.md`, exposed at runtime as `/clone-wars:<verb>`.

The five command files:

| File | Exposed as |
|---|---|
| `commands/spawn.md` | `/clone-wars:spawn` |
| `commands/send.md` | `/clone-wars:send` |
| `commands/collect.md` | `/clone-wars:collect` |
| `commands/list.md` | `/clone-wars:list` |
| `commands/teardown.md` | `/clone-wars:teardown` |
| `commands/medic.md` | `/clone-wars:medic` |

Six commands total — five from `DESIGN.md` plus `medic` (see §4). `DESIGN.md`'s "five commands"
count is updated to six in the next runtime-design revision.

### 3. Plugin → host permissions (Layer 1)

**Posture: broad allow.** Clone Wars runs on a user-controlled machine where the user has already
consented to Claude Code itself; bundling tight allowlists adds friction without meaningful safety
(the user can disable the plugin entirely if they don't trust it).

**Mechanism: documented in README, not shipped as a settings file.** Plugin manifest format does not
support shipping a `settings.json` that auto-merges into user config (verified against superpowers,
claude-mem, oh-my-claudecode, claude-hud, hookify — none ship one). README's Configuration section
includes a copy-pasteable snippet for `~/.claude/settings.local.json` that allows:

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

Users who skip this step still get a working plugin — they just see permission prompts on first
use and can approve persistently. Power users on sandbox-only machines can broaden to `Bash(*)`
if they prefer one-line config over verb-level granularity.

### 4. Trooper → workspace permissions (Layer 2): mode flag

`contracts.yaml` grows from a single `args:` per provider to a `modes:` map plus a `default_mode:`
field. Two modes are defined: `full` and `read-only`. Each provider's contract row maps these to
its native flags.

```yaml
codex:
  binary: codex
  modes:
    full:      [--dangerously-bypass-approvals-and-sandbox]
    read-only: [--sandbox, read-only]    # codex's --sandbox accepts read-only|workspace-write|danger-full-access
  default_mode: full
  ready_timeout_s: 30
  identity_injection: send-keys-paste

gemini:
  binary: gemini
  modes:
    full:      [--approval-mode, yolo]
    read-only: [--approval-mode, default]
  default_mode: full
  ready_timeout_s: 30
  identity_injection: send-keys-paste

claude:
  binary: claude
  modes:
    full:      [--dangerously-skip-permissions]
    read-only: []                        # claude has no native read-only; falls through to prompts
  default_mode: full
  ready_timeout_s: 60
  identity_injection: send-keys-paste
```

`/clone-wars:spawn` accepts `--mode <full|read-only>`; if omitted, the provider row's `default_mode`
applies. Where a provider has no true read-only mode (claude today, gemini approximately), the
mapping is documented as "best-effort" in the contracts.yaml comments.

The mode taxonomy is **closed for v0.0.1** — only `full` and `read-only`. A future `standard`
mid-tier can be added without breaking compat (existing rows just don't define it).

### 5. State directory location

`$CLONE_WARS_HOME` env var, defaulting to `~/.clone-wars/`. Single bucket — config, state, archive,
and cache all live under this one root. No XDG split for v0.0.1.

```
$CLONE_WARS_HOME/                          # default ~/.clone-wars
├── config.yaml
├── commanders.yaml
├── contracts.yaml
├── identity-template.md
├── repo-hash-map.json
├── state/<repo-hash>/<topic>/<commander>-<model>/...
└── archive/<repo-hash>/<topic>-<timestamp>/...
```

`/clone-wars:medic` always prints the resolved root at the top of its output so users with the
override set don't get confused about where to look for outbox files.

### 6. The medic command

`/clone-wars:medic` is a binary-and-environment health check. Verifies, in order:

1. `tmux` present on PATH and version ≥ 3.0 (older versions miss `-P -F '#{pane_id}'` which the
   spawn flow depends on).
2. The current shell is inside a tmux session (`$TMUX` set) — warn if not, since `split-window`
   from outside a session won't behave as users expect.
3. `$CLONE_WARS_HOME` resolves to a path that exists (or can be created) and is writable.
4. `$CLONE_WARS_HOME/contracts.yaml`, `commanders.yaml`, and `identity-template.md` exist and
   (where applicable) parse as YAML. These three files are all required for spawn; missing any
   one of them is a FAIL.
5. For each provider in `contracts.yaml`: binary present on PATH and `<binary> --version` exits 0.
   Missing providers are reported as **WARN**, not FAIL — Clone Wars is usable as long as **at
   least one** provider is healthy. Medic FAILs only when zero providers resolve.

Output: a status table with one line per check, OK/WARN/FAIL glyph, and a one-line `install:`
hint per failed-or-warned check. Ends with a binary verdict — `OK — ready to spawn (N/M providers
available)` or `FAIL — fix the items above`. Exit code mirrors the verdict (0/1) so it's
scriptable.

Explicitly *not* in scope:

- Auth verification per provider (`codex`/`gemini` don't have a uniform "am I authed" signal; a
  half-working check is worse than none).
- Self-test spawn (couples medic's quality to the rest of the plugin and turns a 5-second check
  into a 30-second one).

### 7. Versioning policy

Conventional 0.x → 1.0 trajectory:

- `0.0.1` — first marketplace publish; tracer-bullet works, six commands functional, medic green.
- `0.0.x` — bug fixes, doc tweaks, contracts.yaml additions that don't break existing crews.
- `0.1.0`, `0.2.0`, … — new commands, new providers, schema changes. Rolling forward without
  commitment to API stability.
- `1.0.0` — dogfooded on at least one real task (CLAUDE.md status step 6); IPC protocol stable;
  ready for `claude-plugins-official` submission.

Versions live in two files (`plugin.json` + `marketplace.json` plugins[0].version) and must stay
in sync. Either reuse `claude-mem:version-bump` skill or write a five-line `bin/bump.sh` —
decision deferred to scaffolding time.

Each release tagged on git as `vX.Y.Z` for marketplace consumption.

### 8. README structure

Quickstart-first, deep-dive after. The marketplace listing is a first-impression surface, not
documentation. Above-the-fold goal: a user is spawning a real trooper within 60 seconds of arrival.

Section order:

1. **Tagline** — one line: "Multi-model tmux pane orchestration for Claude Code."
2. **Install** — two-line block: `/plugin marketplace add WingsOfPanda/clone-wars` then
   `/plugin install clone-wars@clone-wars`.
3. **Quickstart** — six-line worked example: `/clone-wars:medic`, then `/clone-wars:spawn rex codex
   auth-review "review src/auth/oauth.py for token-refresh edge cases"`, then
   `/clone-wars:collect rex auth-review`, then `/clone-wars:teardown auth-review`.
4. **Why** — the visibility-gap argument from `DESIGN.md` §Problem, condensed to ~150 words.
5. **Commands** — table with signature + one-line description + one example for each of the six
   commands. Links into `docs/COMMANDS.md` (when it exists) for full reference.
6. **Configuration** — `$CLONE_WARS_HOME`, the `contracts.yaml` structure (modes, default_mode),
   the `commanders.yaml` pool, and the permission-allowlist snippet for
   `~/.claude/settings.local.json`.
7. **Troubleshooting** — link to `/clone-wars:medic` first, then a short list of common failures
   (no tmux session, permission denied on state dir, provider not authed) with one-line fixes.
8. **License** — MIT.

A screencast/asciinema recording of two panes spawning live is queued for v0.1.0 — *not* a v0.0.1
blocker. Record after dogfood when there's a real session worth showing.

### 9. plugin.json shape

Following the conventions verified against superpowers and oh-my-claudecode:

```json
{
  "name": "clone-wars",
  "version": "0.0.1",
  "description": "Multi-model tmux pane orchestration for Claude Code — spawn codex/gemini/claude TUIs as attachable clone troopers",
  "author": {
    "name": "liupan",
    "email": "dragonrider.liupan@gmail.com"
  },
  "homepage": "https://github.com/WingsOfPanda/clone-wars",
  "repository": "https://github.com/WingsOfPanda/clone-wars",
  "license": "MIT",
  "keywords": [
    "claude-code",
    "plugin",
    "multi-agent",
    "orchestration",
    "tmux",
    "codex",
    "gemini"
  ]
}
```

Email is taken from the user's recorded Git/Claude identity. No `skills`, `mcpServers`, or
`hooks` keys — Clone Wars ships only slash commands.

### 10. marketplace.json shape

```json
{
  "$schema": "https://anthropic.com/claude-code/marketplace.schema.json",
  "name": "clone-wars",
  "description": "Multi-model tmux pane orchestration for Claude Code",
  "owner": {
    "name": "liupan",
    "email": "dragonrider.liupan@gmail.com"
  },
  "plugins": [
    {
      "name": "clone-wars",
      "description": "Spawn codex/gemini/claude TUIs as attachable tmux panes; orchestrate them via file-based IPC",
      "version": "0.0.1",
      "source": "./",
      "category": "orchestration",
      "homepage": "https://github.com/WingsOfPanda/clone-wars",
      "tags": [
        "multi-agent",
        "orchestration",
        "tmux",
        "delegation"
      ],
      "author": {
        "name": "liupan",
        "email": "dragonrider.liupan@gmail.com"
      }
    }
  ],
  "version": "0.0.1"
}
```

Marketplace `name` matches plugin `name` (`clone-wars`) — install path is therefore
`/plugin install clone-wars@clone-wars`. Marketplace `version` and plugin entry's `version` track
the plugin version.

## Concrete file deltas (vs. current repo state)

When scaffolding moves to implementation, this spec produces the following changes:

```
.claude-plugin/
├── plugin.json                  ← NEW (§9)
└── marketplace.json             ← NEW (§10)
commands/
├── spawn.md                     ← NEW (per §2)
├── send.md                      ← NEW
├── collect.md                   ← NEW
├── list.md                      ← NEW
├── teardown.md                  ← NEW
└── medic.md                     ← NEW (§6)
config/
├── contracts.yaml               ← NEW (per §4 — modes structure)
├── commanders.yaml              ← NEW
├── config.yaml                  ← NEW
└── identity-template.md         ← NEW
README.md                        ← REWRITE (per §8)
docs/DESIGN.md                   ← MINOR EDIT — update "five commands" → "six commands";
                                              note medic; note --mode flag on spawn;
                                              note $CLONE_WARS_HOME override
CLAUDE.md                        ← MINOR EDIT — update file-tree under "Repository layout"
                                              to reflect six commands and contracts.yaml shape
```

`tracer/tracer-bullet.sh` is unchanged by this spec — the tracer's responsibility is the IPC/tmux
mechanics, which this spec doesn't touch.

## Out of scope (explicit)

These are deferred to future spec rounds:

- IPC protocol details (`END_OF_INSTRUCTION` sentinel mechanics, outbox event schema,
  status.json field set) — `docs/DESIGN.md` §File-IPC protocol stays canonical until the tracer
  validates it.
- The eight inconsistencies flagged on initial read of `DESIGN.md` (contracts/identity-injection
  ambiguity, ready-event source, `--wait` on send, repo-hash collision rule, topic sanitization
  enforcement, archive path conflict, `current_task_summary` lifecycle, conductor-exit cleanup,
  `repo-hash-map.json` lifecycle). Resolved in the post-tracer design revision.
- A standalone `package.json` — Clone Wars has no Node runtime per CLAUDE.md. If marketplace
  tooling later requires `package.json`, add it then with `"private": true`.
- `claude-plugins-official` submission — gated on v1.0.0 per §7.
- Asciinema/screencast recording for the README — gated on v0.1.0 per §8.
- A `clone-wars:permissive` opt-in command (Q5 option D) — YAGNI for v1.
- Per-directory `$CLONE_WARS_*` overrides (Q7 option D) — YAGNI for v1.
- `standard` mid-tier mode (Q6 option B) — additive; can ship in 0.x without breaking compat.

## Acceptance criteria — split across two phases

Per Q1=C ("marketplace-prep first, runtime after tracer"), the publish-readiness work splits
into two phases. Each phase produces working, testable software on its own.

### Phase 1 — marketplace shell (this spec, separate plan: Plan A)

Tag `v0.0.1-pre1`. Plugin is installable from the marketplace; medic works; runtime commands
are documented stubs that print a "pending tracer validation" message and exit cleanly.

1. `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` exist with the shapes in §§9–10.
2. All six command files exist as bare verbs in `commands/<verb>.md` and respond to invocation.
   `medic` is fully implemented; `spawn`/`send`/`collect`/`list`/`teardown` are stubs that print
   the parsed args + a "v0.0.1: runtime pending tracer-bullet validation" message and exit 0.
3. `config/contracts.yaml`, `commanders.yaml`, `config.yaml`, `identity-template.md` ship with
   defaults from §4 (modes-aware contracts.yaml).
4. `/clone-wars:medic` runs end-to-end and emits the §6 output (binaries + env + state dir +
   config files + provider sanity, with WARN-on-missing-provider).
5. README follows the §8 structure. The quickstart's first command (`/clone-wars:medic`) is
   live; subsequent commands (`spawn`/`collect`/`teardown`) are present but documented as
   "pre-runtime" with a roadmap pointer. Status banner at top: "v0.0.1-pre1 — marketplace
   shell; runtime commands ship in v0.0.1 after tracer-bullet."
6. `$CLONE_WARS_HOME` resolves correctly (default + override both work) and is exercised by medic.
7. Tagged `v0.0.1-pre1` on git; `WingsOfPanda/clone-wars` is installable via the §1 install
   path from a fresh Claude Code session and a user can read the docs + run medic.

### Phase 2 — runtime commands (separate spec + plan: Plan B, post-tracer)

Tag `v0.0.1`. Triggered after the tracer-bullet validates tmux/send-keys mechanics + the eight
inconsistencies in `docs/DESIGN.md` are resolved with empirical evidence. Plan B is its own spec
that resolves the deferred design questions and implements working runtime commands.

8. `--mode read-only` on `/clone-wars:spawn` produces a trooper invoked with the provider's
   read-only flag mapping (codex `--sandbox read-only`; gemini `--approval-mode default`;
   claude documented as best-effort with no native read-only). `--mode full` produces the
   `--dangerously-*` / `yolo` mapping; omitting `--mode` falls through to the row's
   `default_mode`.
9. The runtime commands (`spawn`/`send`/`collect`/`list`/`teardown`) replace their stubs with
   tracer-validated implementations that satisfy `docs/DESIGN.md` §Acceptance criteria 1–10.
10. Tagged `v0.0.1` on git; the README's status banner is removed; the quickstart works
    end-to-end including spawn/collect/teardown.

The runtime correctness gates (`docs/DESIGN.md` §Acceptance criteria 1–10) are tracked in that
file and become Plan B's acceptance gates verbatim.

## Open questions explicitly deferred

- Do plugin commands receive their args as positional `$1 $2 $3` shell-style, or as a parsed
  argv structure? Affects how `--mode full` is parsed in `commands/spawn.md`. **Resolved at
  scaffolding time** — verify against an existing plugin's command frontmatter before
  writing the spawn command.
- How does Claude Code surface plugin updates? (Auto-detect new tag in marketplace? Manual
  `/plugin update`?) Affects the README's "how to update" line. **Resolved at scaffolding time** —
  verify by upgrading an existing installed plugin and observing the flow.
- Whether `contracts.yaml` should be parsed in pure shell (one-pass `awk`/`sed`) or via `yq`.
  `yq` is a hard dependency we'd have to add to medic. Pure shell works for the simple
  structure but is fragile if a user hand-edits with weird indentation. **Resolved at
  `lib/contracts.sh` write time.**

These are scaffolding-level details, not spec-level decisions. The spec is locked above.
