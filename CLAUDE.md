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
- **ARS reference**: ARS multi-agent commands already orchestrate Claude teammates
  via `Agent + TeamCreate` (in-process). Clone Wars is **additive** — not replacing them.
  Future integration: an ARS DAG part with `provider: codex` could spawn a Clone Wars
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
- Generic OpenAI-compat providers (LM Studio, ollama, vLLM, DeepSeek-via-other-clients).
  Closed set: claude / codex / gemini / opencode (pinned to DeepSeek V4 Pro).
  Justification for opencode (v0.13.0): model diversity beyond the Western houses;
  pinned to one model to preserve "smaller than OMC" thesis. Generic open-set still rejected.
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
- [x] v0.7.0: rename `/clone-wars:execute-design` → `/clone-wars:deploy` + hide internal slash commands (`spawn`/`send`/`collect`); user-facing surface is now medic/consult/spec/deploy/list/teardown (v0.12 added /spec)
- [ ] v0.7.0 strict-dogfood pass on a real machine (release gate)
- [x] v0.8.0: deploy single-turn — plan+implement+verify run in one trooper turn per round; auto-retry-once; CW_DEPLOY_TURN_TIMEOUT=14400 default; 6 bin scripts and 4 lib helpers deleted
- [ ] v0.8.0 strict-dogfood pass on a real machine (release gate)
- [x] v0.9.0: deploy auto-detects trooper provider (codex default; claude with confirmation when .claude-plugin/plugin.json present); cw_deploy_detect_provider helper + auto_provider.txt/provider.txt state files; medic probe extended; static-wiring test for the directive
- [ ] v0.9.0 strict-dogfood pass on a real machine (release gate — see tests/test_deploy_v07_dogfood.sh scenarios 4-6)
- [x] v0.10.0: deploy sub-repo redirect — `**Target Sub-Project:** <name>` header in design doc redirects trooper pane / branch / state / provider auto-detect into `<conductor-cwd>/<name>/`; uses `git -C <sub-repo>` + `tmux split-window -c <sub-repo>` so the conductor never `cd`s; consult design-doc walk asks for the header in hub repos
- [ ] v0.10.0 strict-dogfood pass on a real machine (release gate — see tests/test_deploy_v07_dogfood.sh scenarios 7-9)
- [x] v0.11.0: consult hub-mode — Target Hub(s) + Target Sub-Project(s) headers, Execution DAG, Cross-Repo Dependencies table, Step-tagged Acceptance Tests; cw_consult_detect_hub returns MODE/HUBS/LEAVES; 3 new validators (dag/xrepo-deps/acceptance-tests); single-repo behavior byte-identical to v0.10
- [ ] v0.11.0 strict-dogfood pass on a real machine (release gate — see tests/test_consult_v011_dogfood.sh scenarios CW-DF-CONS-1..4)
- [x] v0.11.1: consult maintenance + hardening — lib/consult.sh 3-way split + thin sourcing shim, CW_SLUG_REGEX_BASE shared constant, cw_consult_extract_targets_from_topic + cw_consult_findings_active_subproject, drilldown collision counter, validator order doc + acceptance-tests log_warn, mode-toggle warn, findings-conformance metric
- [ ] v0.11.1 strict-dogfood pass on a real machine (release gate — see tests/test_consult_v011_dogfood.sh scenarios CW-DF-CONS-1..9)
- [x] v0.11.2: codex cold-start mitigation — consult Step 1 spawn-rollback runbook auto-retries-once before tearing down (fixes the race where spawn.sh's identity-read nudge arrived before codex finished cold-starting node-modules + auth handshake); codex bootstrap_sleep_s bumped 8 → 20 in config/contracts.yaml as belt-and-braces. Warm-start happy path unaffected.
- [x] v0.12.0: split /clone-wars:consult into /consult (research+synthesis+drill+teardown) + /spec (conductor-only design-doc walk that consumes a synthesis seed); --design-doc flag deprecated with log_warn; bin/consult-design-doc.sh renamed → bin/spec-assemble.sh; new Step 8.4 free-form drill-deeper before teardown (replaces old per-section drill in Step 8.5); per-sub-project drill axis intentionally dropped (free-form via $DRILL_TOPIC prose)
- [ ] v0.12.0 strict-dogfood pass on a real machine (release gate — verify /consult ends at synthesis, /spec re-runs from archived seed, --design-doc shows deprecation warn, Step 8.4 drill rounds write to _consult/drilldowns/_scratch/)
- [x] v0.13.0: opencode trooper (DeepSeek V4 Pro) — tracer-bullet + medic preflight (rc-capture bash bug fixed) + contracts.yaml row + /clone-wars:deploy --provider override; closed-set 3 → 4 with generic OpenAI-compat still rejected
- [x] v0.13.0 strict-dogfood pass on a real machine (2026-05-07): `bin/spawn.sh rex opencode dogfood-13` cold-started DeepSeek V4 Pro in ~5s after the 15s bootstrap floor; round-trip ready→done = ~1m49s for "summarize the v0.13.0 spec in 5 bullets" task; outbox emitted clean JSONL ready/ack/progress/done (zero ANSI escapes), findings.md written with 5 accurate bullets, status.json transitioned ready→idle on done; medic preflight detected `permission: allow` correctly. Archive: `~/.clone-wars/archive/<repo-hash>/dogfood-13/rex-opencode-20260507T023020Z`.
- [x] v0.14.0: hub-mode removal — `/consult` and `/spec` are single-context (invoked at the cwd to investigate); trooper inherits cwd via `tmux split-window -c` and reads `CLAUDE.md`/`AGENTS.md` from there. Deleted: `lib/consult-hub.sh`, `lib/consult-validators.sh`, 25 hub/validator test files (~530 LoC). Renamed: `cw_consult_design_doc_resume_state` → `cw_spec_resume_state` in new `lib/spec.sh`. `/clone-wars:deploy`'s `Target Sub-Project:` redirect preserved (separate mechanism). No back-compat: archived `_consult-<ts>/` dirs with `hub-mode.txt`/`targets.txt` are silently ignored on v0.14.0.
- [ ] v0.14.0 strict-dogfood pass on a real machine (release gate — verify `/consult` produces no `hub-mode.txt`/`targets.txt`, `/spec` produces flat 5-section spec, `cw_spec_resume_state` works on resume)
- [x] v0.15.0: 3-trooper /consult — opencode (DeepSeek V4 Pro) joins as `bly` (commander 327th); topology A symmetric verify (every claim 2 independent verifiers); medic-driven trooper enumeration via `$state_root/providers-available.txt`; N=1 plain-exits with redirect (use claude directly); N=2 unchanged (current 2-trooper mode preserved byte-equal); N=3 new mode with 5-tier adjudicate output (consensus / cross-verified / contested / refuted / pending); commander mapping locked: codex→rex, claude→cody, opencode→bly.
- [ ] v0.15.0 strict-dogfood pass on a real machine (release gate — verify rex+cody+bly all spawn, 3-way diff/adjudicate/synthesis, drill across 7 options including "all three (parallel)" K=2+K=1 fan-out)
- [x] v0.16.0: /consult unified smart-control — single entry point with `--use-force` flag, escalation phrasing triggers ("deeply", "verify", "compare carefully", "second opinion", "consult thoroughly"), and Yoda fast-path with 4-signal complexity check (conflicting evidence / significant assumptions / high-stakes / subjective tradeoffs; favor rigor — any borderline signal escalates). Output unified at `_consult/design-doc/<date>-<slug>-design.md` (rigid 6 sections: Summary / Findings / Tradeoffs / Recommendation / Open Questions / Sources). /spec source-defaulting collapses to single path. Drops `_consult/synthesis.md` (replaced by design-doc); breaking change for archived consult dirs without back-compat per v0.14 precedent.
- [ ] v0.16.0 strict-dogfood pass on a real machine (release gate — verify simple topic → fast-path solo design-doc; phrasing trigger → escalate; --use-force → escalate; signal-fire → escalate; /spec consumes the design-doc cleanly)
- [x] v0.17.0: consult-spec merge — `/clone-wars:consult` is now the single command from topic to deploy-audit-passing design doc. `/clone-wars:spec` deleted entirely (commands/spec.md, bin/spec-{init,assemble}.sh, lib/spec.sh, all tests/test_spec_*.sh). New: lib/consult-walk.sh (4 helpers: audit_issue_to_section / emit_soft_dag / detect_multi_repo / walk_section_state); bin/consult-walk-assemble.sh (concat .draft/*.md → final design-doc, runs cw_deploy_audit_doc, exits 1 with ISSUE= lines on FAIL); bin/consult-init.sh `--targets a,b,c` flag; bin/consult-synthesize.sh refactored to emit per-section seed drafts under `.draft/`. commands/consult.md renumbered to clean integers 0–16; new Steps 10 (multi-repo auto-detect via cwd siblings + topic-prose grep), 11 (per-section Approve/Revise/Skip walk over 6 single-repo or 8 multi-repo sections), 12 (assemble + audit gate with retry mapping). Doc shape: Problem/Goal/Architecture/Components/Testing/Success Criteria (single) + Execution DAG / Cross-Repo Notes + per-repo subsections + `**Target Sub-Project(s):**` header (multi). Soft DAG format only; multi-repo docs were initially out of /clone-wars:deploy scope (later restored in v0.20.0 multi-repo deploy). `/clone-wars:deploy` was single-repo at v0.17.0. Partially reverses v0.14.0's hub-mode deletion: auto-detect + per-repo subsections + soft DAG restored; 282 LoC of validators stay deleted. Spec at `docs/superpowers/specs/2026-05-08-consult-spec-merge-design.md`.
- [ ] v0.17.0 strict-dogfood pass on a real machine (release gate — verify: (1) single-repo trivial fast-path produces 6-section deploy-audit-passing doc; (2) single-repo escalated path runs trooper roster + design walk; (3) multi-repo escalated path auto-detects sibling CLAUDE.md, asks AskUserQuestion to confirm targets, walks 8 sections with `**Target Sub-Project(s):**` header + soft DAG; (4) audit-fail recovery — Skip success-criteria → re-walk → audit PASS; (5) `--targets foo,bar <trivial topic>` forces escalation; (6) /clone-wars:deploy reads single-repo /consult output cleanly)
- [x] v0.18.0: medic trooper-select — `/clone-wars:medic` now runs interactive Steps A–G after the health table; user picks an active subset (preset N=2/3 menu or per-provider Customize walk for N=4); selection persists in `$state_root/providers-active.txt` and `bin/consult-init.sh` prefers it over `providers-available.txt`; new `cw_active_providers_path` resolver in `lib/state.sh` is the single source of truth for precedence; `bin/medic.sh` unchanged (interactivity is Claude-side only). Spec at `docs/superpowers/specs/2026-05-08-medic-trooper-select-design.md`.
- [ ] v0.18.0 strict-dogfood pass on a real machine (release gate — verify: (1) all-providers detected → preset menu offers all subsets; (2) Customize walk per-provider; (3) selection persists across medic re-runs; (4) /consult uses active subset; (5) stale provider entry filtered with note: line; (6) empty-selection guard refuses write)
- [x] v0.18.1: medic Step D AskUserQuestion 4-option cap fix — flat 5-option menu for N=3 (`All three` + 3 pairs + `Customize`) was unimplementable; rewritten as 2-step nested pattern (Step D.1 high-level: `All three` / `Pick a pair (drill in)` / `Customize…`; Step D.2 fires only when D.1 returns `Pick a pair`, drills with the 3 pair options). N=2 menu unchanged. Static-wiring test asserts D.1/D.2 structure + negative-asserts the legacy "5 options" prose.
- [x] v0.18.2: medic skill-reviewer polish — frontmatter `allowed-tools` adds `AskUserQuestion`, description expanded to mention trooper-roster picker, one-line preamble distinguishes bash-wrapper (Steps 1–6) from Claude-side flow (Steps A–G), stale "spawn.sh prints stub messages" parenthetical at Step 6 dropped (pre-v0.0.6 leftover), `lib/consult.sh:1157` line-number cite replaced with bare function name (drift-prone), trigger-phrase examples added so future-Claude can route natural-language requests ("switch consult roster", "use only rex and cody", etc.), FAIL-verdict carve-out documented (Steps A–G run on FAIL too if `providers-available.txt` has ≥1 entry). Static-wiring test extended with 6 new asserts + 2 negative-asserts. No behavioral changes.
- [x] v0.18.3: consult skill-reviewer polish — `commands/consult.md` (1045 lines) gets P0+P1+P2 review fixes. Frontmatter: add `allowed-tools` (was missing entirely) + `argument-hint` advertises `--use-force` and `--targets`. Intro: "When to use this command" trigger-phrases block + v0.17.0 spec added to citations. Task table: row 1 renamed "Phrasing trigger scan (skipped if --use-force)", row 2 renamed "4-signal complexity check + route (fast-path or escalate)". Step 0: `--design-doc` deprecation now surfaced via chat (not just `log_warn` stderr). Step 1: "skip Step 2" wording corrected to "skip the 4-signal sub-block within Step 2". Step 2: fast-path audit-fail explicitly says "re-invoke walk-assemble" + progress-signaling `log_info` recipe added. Step 9: explicit "intermediate artifact" labeling for `_consult/adjudicated.md` so fresh-Claude doesn't grep for `## Contested` in the design-doc. Step 11: critical-section skip rule extended from `goal/architecture` to all four required-by-audit sections (`goal/architecture/testing/success-criteria`) — closes walk↔audit retry-loop. Step 13: duplicate `5b.` numbering renumbered to `6/7`. Step 16: now points user to `/clone-wars:deploy <path>` (single-repo or multi-repo per v0.20.0+ in-plugin DAG dispatch). Step 5: forward-ref to `CW_CONSULT_SKILL_OVERRIDE=none` kill switch. Stale "v0.14.0 default" stamp dropped. Static-wiring test extended with 13 new asserts + 2 negative-asserts. No behavioral changes.
- [x] v0.19.0: spawn preflight refactor — two-phase trooper allocation replaces the `.last_pane` chain race in `/clone-wars:consult`. New `bin/preflight-layout.sh` splits N panes off Yoda's pane in a single bash process, applies `tmux select-layout main-vertical`, writes ordered `_consult/preflight-panes.txt`. New `bin/spawn.sh --target-pane <id>` flag dispatches via `tmux respawn-pane` (no `.last_pane` reads/writes on this path; strict validation against preflight-panes.txt). `commands/consult.md` Step 3 split into 3a (preflight, foreground) + 3b (parallel spawn dispatch with Stage 1 retry-once + Stage 2 partial-success AskUserQuestion). `bin/consult-teardown.sh` extension cleans preflight orphan panes. Backwards-compat: spawn.sh without `--target-pane` is byte-equal to v0.18.3 (legacy split-window + `.last_pane` flow preserved for `/clone-wars:deploy`). Five new tests + 1 v0.17 test update.
- [ ] v0.19.0 strict-dogfood pass on a real machine (release gate — verify: (1) 3-trooper consult --use-force produces three evenly-sized panes that all appear within ~2s of preflight call, no "1 then 2 then 3" appearance; (2) Yoda pane stays at ~50% width throughout; (3) /clone-wars:deploy single-trooper spawn behavior is byte-equal to v0.18.3; (4) Stage 1 retry absorbs codex cold-start invisibly; (5) Stage 2 partial-success AskUserQuestion offers degrade-or-abort when retry fails)
- [x] v0.20.0: deploy multi-repo DAG path — auto-detect from design-doc header (`**Target Sub-Project(s):**` plural + `## Execution DAG` → multi-repo; else → single-repo byte-equal v0.19.0). Multi-repo path: `bin/deploy-dag-parse.sh` parses soft-DAG prose into waves (Kahn topological sort + cycle detection); `bin/deploy-multi-init.sh` assigns one commander per sub-repo from clone trooper pool (cody reserved for claude/plugin-dev); reused v0.19.0 `bin/preflight-layout.sh` (additive `--art-dir` flag) for pane allocation; `commands/deploy.md` NEW Steps 3a (preflight) + 3b (DAG wave dispatch with K parallel spawn calls per wave + Stage 1 retry-once + Stage 2 partial-success) + 3c (conductor's final verification — cross-repo invariants by default, escalate to full check on 3 "feels unsafe" triggers: wave count ≥3, fan-in repos, shared filesystem paths) + 3d (fix-loop with MAX_FIX_ROUNDS=3 cap + AskUserQuestion at cap: give up / continue / escalate to different commander). Codex trooper runs full superpowers ceremony per sub-repo (writing-plans → subagent-driven-development → verification-before-completion). `bin/deploy-teardown.sh` extension cleans preflight orphan panes (mirrors v0.19.0 consult-teardown). `cw_deploy_detect_provider` drops opencode (rejects `--provider opencode` with clear error; codex/claude only). Drops `--design-doc` + `synthesis.md` ACTIVE references entirely (deprecation prose remains intentionally to explain what's gone). Frontmatter polish (`allowed-tools`, trigger phrases, --provider in argument-hint). Fixes line-257 `description='...$ROUND...'` interpolation bug. 8 new tests + 2 v0.19.0 test stabilization fixes (tmux pane-resize SIGWINCH workaround). `/clone-wars:deploy` for single-repo design-doc is byte-equal to v0.19.0.
- [ ] v0.20.0 strict-dogfood pass on a real machine (release gate — verify: (1) 3-sub-repo multi-repo deploy walks DAG correctly with parallel waves; (2) each codex trooper invokes superpowers ceremony on its sub-repo's design-doc slice via `### <slug>` subsection focus; (3) cross-repo final-verify default doesn't false-positive on simple linear DAGs; (4) fix-loop cap surfaces AskUserQuestion at round 3; (5) `--provider opencode` rejected with clear error; (6) single-repo deploy unchanged from v0.19.0 — same trooper, same single-turn flow, same archive shape; (7) `_deploy/preflight-panes.txt` orphans cleaned up after Stage 2 partial-success abort)
- [x] v0.20.1: deploy multi-repo wiring fixes (PR #71 follow-up patch from skill-reviewer pass) — closes 6 P0 + 4 P1 + 3 P2 findings. NEW `bin/deploy-wave-wait.sh` (per-trooper outbox watcher mirroring consult-research-wait.sh). NEW `cw_deploy_build_dag_unit_prompt` lib helper (fully-resolved heredoc; eliminates Step 3b literal-placeholder bug). NEW `_deploy/multi-verify-bugs.txt` TSV (Step 3c writer → Step 3d reader). `bin/deploy-init.sh` now invokes `deploy-dag-parse.sh` + `deploy-multi-init.sh` when routing=multi-repo (without this wiring, the multi-repo path was unreachable in v0.20.0). `bin/deploy-multi-init.sh` accepts optional `<hub-cwd>` 2nd arg + captures per-cmdr `<cmdr>-branch-base.sha` (fixes Step 3c's silent-no-op SHARED_PATHS detection). `commands/deploy.md` Step 3b: explicit outer `for ((w=1; w<=WAVE_COUNT))` loop, helper-built prompt, wave-wait, "wave" definition, Stage 2 abort via `deploy-archive.sh` (not destructive `rm -rf "$TOPIC_DIR"`). Step 3c writes bugs file; Step 3d reads it. Step 4 multi-repo final-summary iterates troopers.txt for per-sub-repo commit counts. Frontmatter polish: `Skill` added to `allowed-tools`. Source-defaulting block sources `lib/log.sh` before `log_error`. `TOPIC_DIR=` manual string-construction → `cw_deploy_topic_dir` helper. 5 new tests + v0.20→v0.21 static-wiring rename. Single-repo deploy path is byte-equal to v0.20.0 (= v0.19.0).
- [x] v0.20.2: stale-string sweep — drill-deeper takes design-doc-path as new positional arg (synthesis.md was removed in v0.12 but bin/consult-drilldown.sh still tried to read it, breaking Step 13 on every consult); commands/consult.md Pattern numbering 1→2→3 (was 1→3→4 typo, with 6 in-prose cross-references updated); three /spec references in lib/consult.sh purged (replaced with "design-doc walk" / "the assemble step"); drill prompt template no longer says "synthesis"; helper-signature comment in lib/consult-prompts.sh corrected `<synthesis-path>` → `<design-doc-path>`. Pure-edit patch; no new files outside the static-wiring test; single-repo + multi-repo deploy + medic + rest of consult byte-equal v0.20.1.
- [ ] v0.20.2 strict-dogfood pass on a real machine (release gate — verify `/clone-wars:consult` Step 13 "Drill deeper" actually spawns a drill round with no `synthesis.md not found` abort)
- [x] v0.20.3: sub-repo trooper spawn cwd discipline — multi-repo /clone-wars:deploy preflight panes are now allocated already-rooted in each sub-repo cwd via `tmux split-window -c` (was: inherit Yoda's cwd then `cd` later). cw_pane_respawn switches from `cd '$cwd' && exec $launch` to native `tmux respawn-pane -c $cwd` (also fixes apostrophe-in-cwd shell-quoting bug). bin/deploy-multi-init.sh writes new cmdr-cwd-map.txt; bin/preflight-layout.sh gains --cwd-from flag; commands/deploy.md Step 3a threads the flag. Closes the latent schema mismatch where preflight read deploy's 3-col troopers.txt as if it were consult's 2-col format (multi-repo deploy preflight had never worked end-to-end). Single-repo deploy + all of /clone-wars:consult byte-equal v0.20.2.
- [ ] v0.20.3 strict-dogfood pass on a real machine (release gate — verify multi-repo /clone-wars:deploy spawns each trooper pane natively in its sub-repo cwd; `tmux display-message -p '#{pane_current_path}'` matches `<conductor-cwd>/<sub-repo>` immediately after Step 3a; no `cd` visible in any pane during Step 3b spawn)
- [x] v0.20.4: simplification + bug-fix sweep — 11 highest-value findings from v0.20.3 code-simplifier (4 bugs: spawn MODE fallthrough, drilldown collision regex, deploy.md unscoped source-defaulting, preflight silent-skip; ~120 LoC dead-code purge: cw_consult_design_doc_filename + cw_consult_design_doc_assemble + 6 stale doc-comments; ~100 LoC consult.md consolidation: --design-doc trim, N=2/N=3 example dedup, Steps 5+8 wait-block dedup). Spec at docs/superpowers/specs/2026-05-10-v0.20.4-simplification-design.md.
- [ ] v0.20.4 strict-dogfood pass on a real machine (release gate — verify spawn MODE fallthrough on a contract row missing default_mode; verify drilldown re-run preserves section name across collision; verify /clone-wars:consult Step 8 verify-wait still functions correctly with the new "see Step 5" reference shape)
- [x] v0.20.5: opencode commander rename (canonical-mapping-only) + parallel teardown + Read-before-Edit fixes — `lib/consult.sh` `cw_consult_provider_to_commander` maps `opencode → wolffe` (was `bly`); `bly` retained in commander pool + colors as legacy. NEW `bin/teardown.sh --pairs <topic> <cmdr1> [cmdr2] ...` mode batches the 9s graceful banner across N panes (was: per-cmdr loop hit one 9s banner each). `bin/consult-teardown.sh` switched to `--pairs`. `commands/consult.md` Step 9 promotes mandatory `Read("$TOPIC_DIR/_consult/adjudicated.md")` to top-level callout (Bash `cat` doesn't satisfy the Edit tool's per-path read tracker, so adjudication Edit calls were repeatedly emitting `File has not been read yet` errors). Step 11 per-section walk explicit `Read $DRAFT_DIR/$key.md` (NOT cat via Bash) before each `Approve`'s Write call (closes recurring `Error writing file` from seeded sections). `commands/deploy.md` Step 1 force-retry uses Bash atomic tmp+mv instead of Write tool (avoids the same Read-before-Edit trap).
- [ ] v0.20.5 strict-dogfood pass on a real machine (release gate — verify (a) /clone-wars:consult with N=3 spawns wolffe in opencode pane; (b) teardown shows ONE 9s graceful wait banner not N; (c) Step 9 adjudicate Edit loop no longer surfaces "File has not been read yet"; (d) Step 11 per-section walk Write succeeds without "Error writing file" on seeded sections)
- [x] v0.21.0: multi-repo deploy nested + heterogeneous fleet support — closes the two failure modes hit on `/home/liupan/ARS/docs/designs/2026-05-10-10t-checkpoint-deploy.md`. (1) `cw_deploy_dag_parse_line` regex relaxed `[a-z0-9-]+` → `[A-Za-z0-9_-]+` (CapWords/underscore slugs accepted) + optional `(/abspath)` capture group between slug and em-dash; emits 5-field TSV `step\trepo\tpath\tdesc\tdeps`. (2) `bin/deploy-multi-init.sh` honors the path field with flat-sibling fallback (`$HUB_CWD/$repo` when path == `none`) — supports nested fleets like `/home/liupan/ARS/{ars_fleet,ars_gateway}/ARS-{TaskServe,Perfusion,LVMGateway,Gateway}/`. (3) `commands/deploy.md` Step 0 NEW sub-step 5b — Yoda DAG-rescue intercept: when `bin/deploy-init.sh` exits non-zero on a doc whose `## Execution DAG` section is human prose (Unicode box diagrams, narrative wave descriptions), Yoda extracts the implicit DAG via judgment, AskUserQuestion confirms, Edit tool inserts `### DAG Lines` subsection into the local copy of the design doc, then deploy-dag-parse + deploy-multi-init re-run + init.sh's tail (target_cwd / branch / auto_provider) replays inline. Rescue is one-shot per deploy. /consult unchanged. Single-repo + flat-monorepo multi-repo deploy paths byte-equal v0.20.5. Spec at docs/superpowers/specs/2026-05-10-v0.21.0-deploy-nested-paths-design.md; plan at docs/superpowers/plans/2026-05-10-v0.21.0-deploy-nested-paths-plan.md.
- [ ] v0.21.0 strict-dogfood pass on a real machine (release gate — verify: (1) `/clone-wars:deploy /home/liupan/ARS/docs/designs/2026-05-10-10t-checkpoint-deploy.md` invoked from `/home/liupan/ARS/` triggers the rescue intercept, AskUserQuestion offers extracted DAG, accepting writes parser-conforming lines into the local design-doc copy, re-parse + multi-init succeed, troopers.txt resolves nested CapWords paths; (2) flat-monorepo multi-repo deploy still byte-equal v0.20.5; (3) single-repo deploy byte-equal v0.20.5; (4) per-trooper branch-create lands in each sub-repo's `feat/deploy-<topic>` branch)
- [x] v0.22.0: multi-repo deploy seam re-architecture — closes 5 layered bugs hit on the v0.21.0 dogfood of `/clone-wars:deploy /home/liupan/ARS/docs/designs/2026-05-10-10t-checkpoint-deploy.md`. (1) `bin/spawn.sh:91-104`'s `--target-pane` validation hardcoded `cw_consult_art_dir` so deploy panes were looked up under `_consult/`; v0.22.0 adds `--preflight-art-dir <abs-path>` flag (deploy passes; consult omits = byte-equal). (2) `bin/preflight-layout.sh:64,128` mis-parsed deploy's 3-col `troopers.txt` as consult's 2-col (filling `cmdr` with sub-repo paths); v0.22.0 adds `--troopers-from <abs-path>` flag pointing at NEW sidecar `bin/deploy-multi-init.sh` writes (`troopers-preflight.txt`, consult-shaped 2-col, DAG order). (3+4) Downstream of (2): preflight-panes.txt commander column contained absolute paths so the CMDR_TO_CWD lookup silently no-op'd → preflight panes allocated in Yoda's cwd (silently negated v0.20.3); both close via the (2) sidecar fix. (5) `commands/deploy.md` Step 3b dispatch + Step 3d fix-loop used bare `cw_inbox_write` without `cw_pane_send` nudge — troopers received inbox.md on disk but no tmux signal so they sat idle at "Ready event emitted"; v0.22.0 switches both sites to `bin/send.sh @file` (canonical write+nudge convention matching `bin/consult-research-send.sh` + `bin/deploy-turn-send.sh` + `bin/spawn.sh`'s initial-prompt path). NEW `tests/test_deploy_multi_repo_e2e.sh` tmux-dependent integration test seals the seam end-to-end (synthesizes 3-sub-repo hub, runs preflight + spawn + dispatch in a DETACHED test tmux session, asserts all 5 bugs closed) — would have caught all 5 in one run (closes implicit Bug 0). Spec at docs/superpowers/specs/2026-05-10-v0.22.0-deploy-multi-repo-seam-design.md; plan at docs/superpowers/plans/2026-05-10-v0.22.0-deploy-multi-repo-seam-plan.md. Single-repo + flat-monorepo + consult byte-equal v0.21.0; v0.21.0 in-flight multi-repo deploy state NOT preserved (acceptable — no v0.21.0 multi-repo deploy ever ran end-to-end).
- [ ] v0.22.0 strict-dogfood pass on a real machine (release gate — re-invoke `/clone-wars:deploy /home/liupan/ARS/docs/designs/2026-05-10-10t-checkpoint-deploy.md` from `/home/liupan/ARS/`: verify (1) preflight allocates 3 panes each in correct sub-repo cwd, `tmux display-message -p '#{pane_current_path}'` matches `<hub>/<sub-path>` for each pane; (2) Step 3b dispatch immediately yields trooper transition from "Ready" to "working" (no idle hang); (3) Step 3d fix-loop also nudges troopers correctly when bugs are surfaced; (4) e2e test passes in the user's regular tmux session without disturbing it; (5) all v0.21.0 dogfood gate items also pass through to completion this time)
- [x] v0.23.0: DAG auto-extract UX — closes user feedback during v0.22.0 dogfood ("the rescue intercept stops the auto-pipeline and feels like an error every time"). `commands/deploy.md` Step 5b reworded: "DAG rescue intercept" → "DAG auto-extract"; "Init failed" / "the failure may be a DAG-parse failure" alarming framing replaced with neutral "DAG section is prose; auto-extracting parser-conforming lines"; new sub-step 5b.3.5 verifies each extracted line (slug regex + path -d + CLAUDE.md/AGENTS.md presence); sub-step 5b.4 auto-proceeds silently when verification PASSES (one `log_ok` line summarizing extracted slugs; no AskUserQuestion); AskUserQuestion safety net fires only when verification FAILS (with specific failure messages cited inline) OR `CW_DEPLOY_FORCE_RESCUE_PROMPT=1` is set (opt back into v0.21.0/v0.22.0 always-confirm behavior). Audit log `dag-rescue.log` extended with `verification: <status>` field (`auto-passed` / `forced-prompt` / `verification-failed-N`). Pure directive-prose change; no new bash files. v0.21.0 static-wiring test loosened to accept either "DAG rescue intercept" or "DAG auto-extract" wording (still asserts Step 5b feature presence). Single-repo + flat-monorepo + consult byte-equal v0.22.0. Spec at docs/superpowers/specs/2026-05-10-v0.23.0-rescue-auto-proceed-design.md; plan at docs/superpowers/plans/2026-05-10-v0.23.0-rescue-auto-proceed-plan.md.
- [ ] v0.23.0 strict-dogfood pass on a real machine (release gate — re-run `/clone-wars:deploy` on a hand-authored multi-repo design doc; verify (1) auto-extract proceeds without AskUserQuestion when verification passes (single `log_ok` line, deploy continues); (2) `CW_DEPLOY_FORCE_RESCUE_PROMPT=1 /clone-wars:deploy <doc>` brings the prompt back; (3) verification failure (e.g., delete a sub-repo's CLAUDE.md before deploy, or rename a sub-repo so the extracted path no longer exists) surfaces the specific failure message in the AskUserQuestion body; (4) `dag-rescue.log` records the correct `verification:` status for each path)
- [x] v0.23.1: per-trooper sub-rows in deploy multi-repo Step 3b — closes user UX feedback during v0.23.0 dogfood ("we just shown ◼ 3b DAG wave dispatch (multi-repo) in conductor progress, it is too little, i want at least show each trooper's task"). Drops the single `3b DAG wave dispatch` row from `commands/deploy.md` upfront task table; at Step 3b entry, after `dag-waves.txt` is parsed and `WAVE_GROUPS` is computed, fires one `TaskCreate` per `(wave, repo)` tuple with subject `3b.<step> <Rank> <Cmdr> on <repo> [wave <w>]` (e.g. `3b.1 Captain Rex on auth-svc [wave 1]`) and activeForm `<Rank> <Cmdr> implementing <repo>`. Captures task IDs into `REPO_TO_TASK_ID["<repo>"]`; wave-loop notification handler flips each sub-row `in_progress` on dispatch rc=0 and `completed` on `TS=ok` wave-wait notification. Stage 1 retry-once preserves `in_progress` across the retry; Stage 2 partial-success "Proceed degraded" flips dropped repos to `completed` (with description note "skipped per user choice") so no orphan spinner remains. New `cw_cmdr_rank` helper in existing `lib/commanders.sh` (case-statement: rex/keeli/colt/trauma/blackout → Captain; cody/bly/wolffe/fox/gree/ponds/bacara/neyo/doom/faie → Commander; hunter → Sergeant; havoc/thorn/thire/stone → Lieutenant; default → Trooper). UX-only change; dispatch / wave-wait / fix-loop mechanics byte-equal v0.23.0; single-repo + consult byte-equal v0.23.0. Spec at docs/superpowers/specs/2026-05-11-v0.23.1-deploy-per-trooper-rows-design.md.
- [ ] v0.23.1 strict-dogfood pass on a real machine (release gate — re-run a multi-repo `/clone-wars:deploy` and verify (1) the upfront task list shows `0/3a/3c/3d/4` (no `3b` row); (2) once Step 3b begins, sub-rows appear with rank prefixes — `Captain Rex on <repo>`, `Commander Cody on <repo>`, etc.; (3) wave numbers in the `[wave <w>]` suffix match `dag-waves.txt`; (4) wave 1 sub-rows flip to ✓ before wave 2 sub-rows start; (5) Stage 2 partial-success "skipped per user choice" path doesn't leave an orphan spinner)
- [x] v0.24.0: simplification sweep — 15 findings closed across 10 clusters (~850 LoC net reduction): 3 dead-code purges in `lib/consult.sh` (`cw_consult_synthesize` + `cw_consult_design_doc_self_review` + `cw_consult_status_load`) plus 4 orphan test files (`test_consult_synthesis.sh`, `test_consult_3trooper_synthesize.sh`, `test_consult_design_doc_self_review.sh`, `test_consult_design_doc_flag_deprecated.sh`, `test_consult_flag_parse.sh`); `--design-doc` flag plumbing removed (lib helper + parser + dedicated test file), kept a 4-line deprecation stub in `commands/consult.md` to preserve `obsolete in v0.17.0` invariant that v0.20.4 + v0.17 static-wiring tests lock; new `lib/consult-wait.sh` shared by both wait shims (research + verify ~95 LoC each → ~18 LoC shims); `_cw_contract_field` private helper dedups 4 awk getters in `lib/contracts.sh` (binary indent guard preserved); `cw_preflight_kill_orphans` in `lib/tmux.sh` shared by consult + deploy teardown orphan-cleanup loops; `bin/teardown.sh` `--pairs`/2-arg branch dedup via `_teardown_collect_pairs`; `cw_consult_strip_block` + sentinel-block templates obsolete since v0.14/v0.17 hub-mode + /spec removal — dropped from lib + 3 prompt templates (research/verify/drilldown); `bin/deploy-multi-init.sh` 3-pipeline projection collapse to single while-loop; `bin/spawn.sh` `--flag`/`--flag=X` parse dedup via `_kv_parse` nameref helper; `commands/deploy.md` 4× `tmp+mv` → `cw_atomic_write` + Step 5b inline DAG regex → `cw_deploy_dag_parse_line` lib call (single source of truth for slug regex); `commands/consult.md` Step 9 intermediate-artifact warning compressed (21 → 10 lines) + Patterns 1/2/3 block stripped to terse stubs matching `commands/deploy.md` style + 5 cross-references rewritten to point at "Intervention patterns" section. `/clone-wars:consult` + `/clone-wars:deploy` + `/clone-wars:medic` + `/clone-wars:list` + `/clone-wars:teardown` byte-equal v0.23.1 on every user-visible path. The only intentional behavior change: passing `--design-doc <topic>` now produces a usage error from `bin/consult-init.sh` instead of a deprecation warning + silent ignore (deprecated v0.12, silent since v0.17). NEW `tests/test_v0_24_0_static_wiring.sh` locks 11 invariants. Spec at `docs/superpowers/specs/2026-05-11-v0.24.0-simplification-design.md`; plan at `docs/superpowers/plans/2026-05-11-v0.24.0-simplification-plan.md`.
- [ ] v0.24.0 strict-dogfood pass on a real machine (release gate — verify: (1) `/clone-wars:consult` fast-path + escalated-path produce design-doc byte-equal v0.23.1; (2) `/clone-wars:deploy` single-repo + multi-repo paths complete unchanged including per-trooper sub-rows from v0.23.1; (3) `/clone-wars:medic` interactive Steps A–G unaffected; (4) `--design-doc` flag now errors with `consult-init.sh` usage instead of silent ignore; (5) `/clone-wars:teardown`'s 9s graceful banner still fires once per teardown not N×; (6) `bash tests/run.sh` green modulo the 4 pre-existing flakes unrelated to v0.24.0)
- [x] v0.25.0: `/clone-wars:meditate` — new user-facing command for deep multi-aspect exploration of hard topics (SOTA surveys, multi-angle thinking, reference research). Reuses v0.24.0 spawn/dispatch/wait infrastructure for the research phase; drops verify round; adds literature-review parallel track that auto-detects on ML/SOTA keywords (24-token list, override with `--lit`/`--no-lit`); runs preliminary synthesis on Yoda; gates a 5-signal confidence check (top-approach convergence + dual citations + zero CONTESTED + matrix backing + uncertainty acknowledged); fires `AskUserQuestion` if all 5 hold (default option = run-adversary, user must actively opt out); runs adversarial-review round across all N troopers in parallel against the preliminary synthesis if user doesn't skip; writes final landscape doc with tradeoff matrix + adversary critiques + directional Conclusion intended as a hand-off seed for `/clone-wars:consult` (the meditate → consult → deploy workflow). No `--use-force` (no fast-path — meditate is for hard topics by construction). No `--no-adversary` flag (user opts out via confidence gate only). NEW `lib/meditate.sh` (lit-keyword classifier + `--lit`/`--no-lit` token-aware parser + art-dir helper) + 7 new `bin/meditate-*.sh` scripts (init, research-send, synth-preliminary, adversary-send, adversary-wait shim, synth-final, teardown) + 3 new prompt templates under `config/prompt-templates/meditate/` (research, adversary, landscape-skeleton). Modified: `lib/contracts.sh` `cw_consult_timeout` case extended with `adversary` (600s default); `lib/consult-wait.sh` `cw_consult_wait` case extended with `adversary` kind (state_key=AS, env var `CW_MEDITATE_ADVERSARY_TIMEOUT_OVERRIDE`); `lib/consult.sh` `cw_consult_art_dir` is now prefix-aware (`meditate-*` → `_meditate/`, everything else → `_consult/`). 5 new tests (test_meditate_lit_keywords, test_meditate_parse_lit_flag, test_meditate_init, test_meditate_confidence_gate, test_meditate_e2e) + 1 static-wiring lock (test_v0_25_0_static_wiring locks 11 invariants). `/clone-wars:consult` + `/clone-wars:deploy` + `/clone-wars:medic` + `/clone-wars:list` + `/clone-wars:teardown` byte-equal v0.24.0 on every user-visible path. Spec at `docs/superpowers/specs/2026-05-11-v0.25.0-meditate-command-design.md`; plan at `docs/superpowers/plans/2026-05-11-v0.25.0-meditate-command-plan.md`.
- [ ] v0.25.0 strict-dogfood pass on a real machine (release gate — verify: (1) `/clone-wars:meditate "explore SOTA continuous-batching schedulers"` auto-detects literature track ON, spawns 2 or 3 troopers, produces `landscape-<date>-<slug>.md` with Conclusion that feeds a valid `/clone-wars:consult` invocation; (2) confidence gate fires `AskUserQuestion` when all 5 signals hold; (3) user-skip path produces final doc with "Adversary phase skipped" note; (4) user-continue path runs adversary and produces "## Adversary critiques" section populated; (5) `--no-lit` on an ML topic disables literature track correctly; (6) `/clone-wars:teardown` 9s graceful banner fires once not N times)
- [x] v0.25.1: 4-bug fix bundle from v0.25.0 dogfood — (1) `commands/meditate.md` Step 2 preflight call corrected to `$MEDITATE_TOPIC $N` form (prefix-aware art-dir routes meditate-* automatically); (2) Step 2 spawn arg order corrected (positionals before flags per `bin/spawn.sh` declared signature); (3) `lib/consult.sh:cw_consult_topic_validate` extended to accept `meditate-*` prefix (mirrors v0.25.0 `cw_consult_art_dir` change); (4) conductor-side `Skill(literature-review, ...)` call dropped — Yoda's keyword classifier is preserved (Step 1 still runs and writes `_meditate/lit-track.txt`) and its ON/OFF result is now passed to each trooper via a new `{{LIT_GUIDANCE}}` placeholder in `config/prompt-templates/meditate/research.md` rendered by `bin/meditate-research-send.sh`. Deleted: `cw_meditate_parse_lit_flag` + `tests/test_meditate_parse_lit_flag.sh` (--lit/--no-lit overrides removed; classifier is sole decider). Modified: `bin/meditate-synth-preliminary.sh` (drop literature-review.md warning), `tests/test_meditate_e2e.sh` (add lit-track schema assertion), `tests/test_v0_25_0_static_wiring.sh` invariant 3 (2 required functions, was 3). NEW: `tests/test_meditate_research_send_lit_guidance.sh` (3-case unit test for prompt rendering). 12-task list shape preserved. Spec at `docs/superpowers/specs/2026-05-12-v0.25.1-meditate-fix-bundle-design.md`.
- [ ] v0.25.1 strict-dogfood pass on a real machine (release gate — re-run `/clone-wars:meditate "explore SOTA autoresearch pipeline like in https://github.com/karpathy/autoresearch"`; verify: (1) end-to-end completion with no manual outbox-polling; (2) no `--art-dir _meditate` in any directive bash block; (3) spawn calls have positionals first; (4) `cw_consult_wait` accepts `meditate-*` without error; (5) no `_meditate/literature-review.md` written; no `Skill(literature-review)` in conductor message; (6) `_meditate/lit-track.txt` SHOULD exist with ON or OFF; (7) `argument-hint` does NOT mention `--lit`; (8) trooper findings retain `## SOTA evidence` + `## Independent Discovery`; (9) rendered trooper prompts contain `LIT_GUIDANCE` block matching lit-track.txt)
- [x] v0.26.0: `/clone-wars:deep-research` — new user-facing command for AIDE-pattern executable autoresearch. Conductor (Yoda/claude) plans (hypothesize + score + select + synth); codex troopers execute (one branch per trooper, single-turn, implement + run + result.json). K branches per round × N rounds tree search; convergence early-exit (delta < 1% × 2 rounds); honor-system sandboxing (v1) with `--allow-net` opt-in; `--seed-from <meditate-landscape>` bootstraps round 1 from meditate's Approaches section. Final doc emits Suggested next: `/clone-wars:deploy <winner-code-path>` when winner converges. Codex required (init refuses if absent; medic active-set ignored). 5 new bin scripts (`deep-research-{init,experiment-send,experiment-wait,score,teardown}.sh`), `lib/deep-research.sh` (6 helpers), `config/prompt-templates/deep-research/experiment.md`, ~500 LoC directive. Lib extensions (one-line cases): `cw_consult_art_dir` routes `deep-research-*` → `_deep-research/`; `cw_consult_topic_validate` accepts `deep-research-*`; `cw_consult_wait` recognizes `experiment` kind (state_key=EX, `CW_DEEP_RESEARCH_EXPERIMENT_TIMEOUT_OVERRIDE`); `cw_consult_timeout experiment` default 1800s. 7 new tests + v0.26.0 static-wiring lock. `/clone-wars:meditate` + `/clone-wars:consult` + `/clone-wars:deploy` + `/clone-wars:medic` + `/clone-wars:list` + `/clone-wars:teardown` byte-equal v0.25.1. Spec at `docs/superpowers/specs/2026-05-12-v0.26.0-deep-research-design.md`; plan at `docs/superpowers/plans/2026-05-12-v0.26.0-deep-research-plan.md`.
- [ ] v0.26.0 strict-dogfood pass on a real machine (release gate — verify: (1) `/clone-wars:deep-research "optimize MNIST classifier accuracy under 100k params"` runs end-to-end with default budget; final landscape doc lands; winner branch's `code/` runnable; (2) per-branch `tmux display-message -p '#{pane_current_path}'` matches branch sandbox dir; (3) round-2 hypotheses cite round-1 winners; (4) per-branch `timeout` enforces wall-clock cap; (5) failed branch reports `status: fail` with `metric_value: null`; (6) `--seed-from` bootstraps round 1 from meditate landscape; (7) `--allow-net=false` default → trooper instructed not to fetch; (8) `--allow-net=true` flips guidance; (9) convergence early-exit fires when 2 consecutive rounds improve < 1%; (10) teardown via batched `--pairs` (one 9s banner, not K×); (11) cost-warning surfaced verbatim in trooper prompt; (12) README + final landscape doc both contain DANGER block)
- [x] v0.27.0: deep-research advisor rewrite — drop K×N round structure for advisor-with-PhD-students model (2-3 long-lived codex troopers spawned once); metric-discussion preflight (free-form dialogue → structured metric.md); time-limit AskUserQuestion before spawn (`none` / `4h` / `12h` / custom) governs stop-check; stagnation safety net fires after 5 consecutive <1% experiments when no time budget; flat `_deep-research/experiments/exp-NNN-<cmdr>/` state shape replaces `round-N/`; rolling `scoreboard.md` (no per-round files); single batched teardown at end (one 9s banner); folds in 7 v0.26.0 dogfood fixes (slug cap 18 for BLOCKER #1; `experiment)` case in `lib/consult-wait.sh` for BUG #2; drop "cd'd" line + add `## Research goal` section in prompt template for BUG #3; `--allow-net` flag removed (UX #5: default flipped to true via template); directive Bash blocks use absolute paths verbatim for UX #4; budget-flag UX #6 moot; convergence/divergence UX #7 moot under advisor model). Spec at docs/superpowers/specs/2026-05-12-v0.27.0-deep-research-advisor-rewrite-design.md; plan at docs/superpowers/plans/2026-05-12-v0.27.0-deep-research-advisor-rewrite-plan.md. Inter-trooper messaging deferred to v0.28+.
- [ ] v0.27.0 strict-dogfood pass on a real machine (release gate — verify: (1) metric discussion produces metric.md cleanly for a clear topic in 1-2 prompts and a vague topic in 3+; (2) preflight time-limit AskUserQuestion fires before spawn; (3) 2-3 troopers spawned once and persist across all experiments (no per-experiment respawn); (4) stagnation safety net fires after 5 consecutive <1% experiments in no-time-budget mode; (5) time-budget mode fires at limit + offers continue/stop/extend; (6) follow-up dispatch to same trooper builds on prior context (codex session memory works); (7) `experiment)` wait-case eliminates the unbound-variable stderr noise; (8) flat `experiments/exp-NNN-<cmdr>/` dirs preserved in archive; (9) `/clone-wars:deploy <winner-code-path>` line emitted correctly in landscape doc; (10) batched --pairs teardown shows single 9s banner for N=2 and N=3; (11) `/clone-wars:meditate --seed-from` path still bootstraps Phase 1 cleanly; (12) topic name `deep-research-<slug>` stays ≤32 chars across the v0.26.0 BLOCKER-#1 reproduction case ("optimize MNIST classifier accuracy under 100k params"))
- [x] v0.27.1: `/clone-wars:consult` single-sub Target Sub-Project header — closes user feedback after v0.27.0 dogfood on `/home/liupan/ARS/ars_fleet`'s halftime-preselect deploy ("`/clone-wars:deploy` in a hub spawned the trooper inside the hub even though the design doc only modified one sub-repo"). Root cause: `bin/consult-walk-assemble.sh` only emitted `**Target Sub-Project(s):**` (plural) for multi-repo mode; the single-sub-repo case had nowhere to declare its target slug, so `cw_deploy_extract_target` (v0.10.0 mechanism, still functional) couldn't redirect `target_cwd` into the sub-repo. NEW mode `multi-repo.txt = single-sub`: `bin/consult-init.sh` writes it for 1-slug `--targets`; `bin/consult-walk-assemble.sh` emits singular `**Target Sub-Project:** <slug>` header + 6-section list (no DAG / Cross-Repo Notes); `commands/consult.md` Step 10 splits the auto-detect branch — 1 hit → `Use <slug>` vs `Treat as hub-level` AskUserQuestion (writes `single-sub`), 2+ hits → existing multi-repo flow; `Edit list` collapses to `single-sub` if user edits down to 1 slug. `/clone-wars:deploy` reads the singular header via existing audit + extract path; trooper spawns inside the sub-repo with branch + state + provider-detect all rooted there. 2 new tests; single-repo (no header) and multi-repo (plural header + DAG) paths byte-equal v0.27.0.
- [ ] v0.27.1 strict-dogfood pass on a real machine (release gate — re-run the `halftime-preselect`-style deploy from `/home/liupan/ARS/ars_fleet`: verify (1) `/clone-wars:consult --targets arsperfusion ...` writes `multi-repo.txt = single-sub`; (2) assembled design doc contains `**Target Sub-Project:** arsperfusion` (singular, no parens); (3) `/clone-wars:deploy <doc>` invoked from `ars_fleet/` redirects target_cwd to `ars_fleet/arsperfusion/`, branch lands in the sub-repo, trooper pane cwd matches `arsperfusion/` via `tmux display-message -p '#{pane_current_path}'`; (4) hub-level consult (no --targets, no sibling hit on topic match) byte-equal v0.27.0 — no Target Sub-Project header, trooper in hub cwd; (5) multi-repo path (2+ --targets or 2+ auto-detect hits) still produces plural header + DAG section)
- [x] v0.27.2: `/clone-wars:deep-research` bug bundle — closes 3 bugs + 1 enhancement from the v0.27.0 strict-dogfood run on `optimize MNIST classifier accuracy under 100k params`. **BUG #4 (P0)** — `bin/deep-research-experiment-send.sh:102` sed substitution corrupted multi-line `APPROACH_BRIEF` to a 0-byte `prompt.md` (sed's `s` command terminates at first newline in replacement); the line-110 sanity check silently passed because grep finds no placeholders in an empty file. Fix: single awk pass handles all 10 template tokens via `-v` variables with double-escape `_awk_esc` helper for `&` + `\` (survives both awk's -v parsing and gsub's replacement-string interpretation); sanity check adds `-s` non-empty gate before the placeholder grep. **BUG #5 (P0)** — troopers paused 3-4min post-training before emitting `{event:"done"}` in 2 of 4 dispatches (rex exp-001 + exp-004); template step 5 wording was procedural. Fix: rewrite step 5 with "**THIS IS THE TERMINAL STEP**" framing + explicit "do not explore/summarize/verify"; new `{{OUTBOX_PATH}}` placeholder so trooper doesn't string-concat the outbox path. **BUG #6 (P1)** — `lib/consult-wait.sh::cw_consult_wait`'s done-event handler matched on `{event:"done"}` without verifying summary contains expected `$EXP_ID`; phantom done from BUG-#4 empty inbox tripped a stale rc=0 for exp-003. Fix: wrap one-shot match logic in stale-event-skipping loop (gated on `kind==experiment` only); skip + log_warn + advance OFFSET (atomic tmp+mv to state file) on EXP_ID mismatch; other kinds (research/verify/adversary) byte-equal v0.27.1. **P2 (enhancement)** — hardware probe both-mode: init-time baseline + per-experiment current + diff alert (>50% memory.free drop). NEW `cw_deep_research_hardware_probe` + `cw_deep_research_hardware_diff_alert` in `lib/deep-research.sh`; new `{{HARDWARE_BLOCK}}` placeholder rendered between `{{METRIC_BLOCK}}` and "Your experiment:"; `bin/deep-research-init.sh` writes `_deep-research/hardware.txt`, `bin/deep-research-experiment-send.sh` writes `hardware-current.txt` per dispatch + computes ALERT line. **P3 (doc only)** — clarify `lib/contracts.sh::cw_consult_timeout experiment)` default 1800s is a wall-clock SAFETY CAP, not a target. 5 new tests; static-wiring lock extended (invariants 4 + 6) with 3 new asserts. All other commands byte-equal v0.27.1; no breaking schema changes. Spec at `docs/superpowers/specs/2026-05-12-v0.27.2-deep-research-bug-bundle-design.md`; plan at `docs/superpowers/plans/2026-05-12-v0.27.2-deep-research-bug-bundle-plan.md`.
- [ ] v0.27.2 strict-dogfood pass on a real machine (release gate — re-run `/clone-wars:deep-research "optimize MNIST classifier accuracy under 100k params"`: verify (1) multi-line APPROACH_BRIEF dispatches cleanly (BUG #4 fixed — no 0-byte prompt.md, no sed errors in stderr); (2) trooper emits `done` event within seconds of `result.json` write (BUG #5 fixed — no 3-4min stall); (3) wait shim emits "stale done event ignored" warning if a phantom done arrives (BUG #6 fixed); (4) per-experiment hardware probe surfaces in `prompt.md` Hardware section with current GPU info from `nvidia-smi`; (5) hardware diff alert fires when GPU memory.free drops >50% mid-session; (6) `_deep-research/hardware.txt` + `hardware-current.txt` preserved in archive after teardown)
- [x] v0.27.3: code-simplifier sweep — closes 2 of the 11 findings from the post-v0.27.2 sweep at low risk. **P0-1** — extract the 8-site `wc -c < outbox | tr -d <ws>` byte-offset idiom into new `cw_outbox_offset <outbox-path>` helper in `lib/ipc.sh` (placed alongside `cw_outbox_wait_since`); folds in `bin/consult-drilldown.sh`'s missing-file `|| echo 0` fallback so the helper handles non-existent paths cleanly. Swaps 7 bin scripts (deploy-turn-send, consult-research-send, consult-verify-send, meditate-research-send, meditate-adversary-send, deep-research-experiment-send, consult-drilldown) + 1 internal `lib/ipc.sh:222` call site to the helper. **P2-11** — drop redundant `[[ "$TOPIC" =~ ^[a-z0-9-]+$ ]]` format regex from `bin/meditate-research-send.sh` + `bin/meditate-adversary-send.sh` (`cw_consult_topic_validate` already accepts `meditate-*` since v0.25.1 and its `^[A-Za-z0-9_.-]+$` regex is a superset); `[[ "$TOPIC" == meditate-* ]]` prefix-enforcement stays (meditate-specific cross-prefix guard). NEW `tests/test_outbox_offset.sh` (5 cases: non-empty file, empty file, missing file, missing arg rc=2, numeric-compare safety). `tests/test_deploy_turn_send.sh` static-wiring grep updated from `wc -c` → `cw_outbox_offset` to match new convention. Skipped from the sweep: wait-shim consolidation (deploy-wave-wait + deploy-turn-wait → `cw_consult_wait`, P0-2) — biggest LoC win (~100) but biggest blast radius into the deploy state contract; deserves its own design pass. Skipped from the sweep: `bin/deep-research-experiment-send.sh:181-192` dead pane-id block (P0-5) — agent flagged conflict with "don't touch v0.27.2 just-merged" guidance.
- [ ] v0.27.3 strict-dogfood (no separate dogfood needed — pure refactor with unit test coverage; ride the v0.27.2 dogfood)
- [x] v0.28.0: `/clone-wars:deep-research` per-trooper turn loop — replace Phase 4's intra-turn loop with per-trooper independent turn cycles driven by `Monitor` + `<task-notification>`. Yoda is idle between events; user can chat freely about the research or anything else. Custom completion-check (floor + target + K-corroboration + plateau) replaces v0.27.x stagnation/time-budget AskUserQuestions; inspired by `/goal`'s pattern but not dependent on it. Liveness escalation (mtime → `status?` probe → stuck) replaces foreground experiment-wait blocking. Plugin-portable re-entry via `hooks/user-prompt-submit-active-session.sh` (registered in plugin.json) + `commands/deep-research-resume.md` (handler 3.b directive) — no CLAUDE.md or per-machine config. **New helpers** in `lib/deep-research.sh`: `cw_deep_research_trooper_state_read/write` (atomic per-trooper KV I/O), `_check_completion` (TSV signal block from scoreboard.md + metric.md), `_render_summary` (rolling session-summary.md sections 1/2/4/5), `_check_plateau` (renamed from `_check_stagnation`). **New `bin/` scripts**: `deep-research-monitor.sh` (Monitor's watcher; tails outbox + checks mtime), `deep-research-finalize.sh` (Phase 4→5 cleanup, idempotent). **Deleted**: `bin/deep-research-experiment-wait.sh` (Monitor replaces foreground waits). **State schema** rebuilt: `troopers/<cmdr>/state.txt` (KV: exp_counter, phase, current_exp_id, last_event_ts, last_event, probe_sent_ts), `troopers/<cmdr>/experiments/<exp-id>/` (per-trooper branch dirs), `session-summary.md` (rolling continuity), `monitor-tasks.txt` (Monitor task IDs), `active.txt` (hook detection). `metric.md` gains `min_acceptable`, `K_corroboration`, `plateau_window`, `plateau_threshold` fields. **Architectural principle**: Yoda gives 1-2 sentence directions, not detailed plans — keeps per-turn token cost low and preserves trooper autonomy. Spec at `docs/superpowers/specs/2026-05-13-v0.28.0-deep-research-turn-loop-design.md`; plan at `docs/superpowers/plans/2026-05-13-v0.28.0-deep-research-turn-loop-plan.md`.
- [x] v0.28.0 partial strict-dogfood pass on a real machine (2026-05-13): re-ran `/clone-wars:deep-research "optimize MNIST classifier accuracy under 100k params"` — release-gate items 1, 2, 6, 7, 9, 10 verified green (Phase 4.a clean entry + Monitor task arming, `<task-notification>` fires Yoda turn within seconds of result.json write, rolling session-summary.md updated correctly with final `## Halt` section appended by finalize.sh, UserPromptSubmit hook injects handler 3.b context, completion-check fires stop with Yoda override on floor+target+K satisfied, dispatches are 1-2 sentence directions); items 3/4/5/8 not exercised (no liveness probes triggered since both troopers completed before stale threshold; user-initiated halt not tested since Yoda-judgment halt fired first; post-teardown hook silence pending next chat turn). Two P0+P1 bugs surfaced + fixed in v0.28.1 (see v0.28.1 row). Winning approach: compact ResNet + group conv + label smoothing landed 0.9971 accuracy at 86,522 params on round 1.
- [x] v0.28.1: deep-research dogfood bug-bundle — (1) BUG #1 (P1): `bin/deep-research-experiment-send.sh:73` called `cw_outbox_offset` without sourcing `lib/ipc.sh`; non-fatal but emitted `command not found` on stderr at every dispatch (peer scripts `consult-research-send`, `meditate-research-send`, `deploy-turn-send`, `consult-drilldown`, `consult-verify-send`, `meditate-adversary-send` all source it correctly). Fix: add `source "$PLUGIN_ROOT/lib/ipc.sh"` after the contracts.sh source. (2) BUG #2 (P0): `bin/deep-research-score.sh:106-118` used `ls "$cmdr_dir/experiments"/*/result.json >/dev/null 2>&1` to gate state-clear; under `shopt -s nullglob` (set at L105) an empty glob expands to nothing → `ls` is called with no args → lists cwd → exits 0 unconditionally. Race effect: when trooper-A emits done first, score.sh flipped trooper-B (still-working, no result.json) to `phase=idle, current_exp_id=""`, corrupting the next dispatch. Fix: switch gate from "any result.json exists" to "trooper's CURRENT `current_exp_id` has a result.json on disk" — read `current_exp_id` from state.txt, skip if empty, flip only when `experiments/$current_exp_id/result.json` exists. Closes the race; idle troopers with empty `current_exp_id` are skipped on subsequent score calls (no spurious touch). Two new tests (`test_deep_research_experiment_send_sources_ipc` 2 asserts, `test_deep_research_score_state_race` 9 asserts). No directive or schema changes; v0.28.0 PR #89 byte-equal on every user-visible path except the two bug behaviors.
- [ ] v0.28.1 strict-dogfood pass on a real machine (release gate — re-run `/clone-wars:deep-research "optimize MNIST classifier accuracy under 100k params"`: verify (1) no `cw_outbox_offset: command not found` on dispatch stderr; (2) when trooper-A emits done first and trooper-B is still working, trooper-B's state.txt is preserved (`phase=working, current_exp_id=exp-NNN`); (3) trooper-B is correctly flipped to idle when its OWN result.json appears; (4) re-run the v0.28.0 unexercised release-gate items 3/4/5/8 if circumstances allow (liveness probe + user-halt + post-teardown hook silence))
- [ ] v0.6: drop config/identity-template.md back-compat symlink + sweep tracer/*.sh + README.md legacy refs
- [ ] Submit to claude-plugins-official (post v0.5.x dogfood)
