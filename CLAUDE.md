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
- [x] v0.10.0: deploy sub-repo redirect — `**Target Sub-Project:** <name>` header in design doc redirects trooper pane / branch / state / provider auto-detect into `<conductor-cwd>/<name>/`; mirrors /executeorder66 git -C / tmux -c discipline; consult design-doc walk asks for the header in hub repos
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
- [x] v0.17.0: consult-spec merge — `/clone-wars:consult` is now the single command from topic to deploy-audit-passing design doc. `/clone-wars:spec` deleted entirely (commands/spec.md, bin/spec-{init,assemble}.sh, lib/spec.sh, all tests/test_spec_*.sh). New: lib/consult-walk.sh (4 helpers: audit_issue_to_section / emit_soft_dag / detect_multi_repo / walk_section_state); bin/consult-walk-assemble.sh (concat .draft/*.md → final design-doc, runs cw_deploy_audit_doc, exits 1 with ISSUE= lines on FAIL); bin/consult-init.sh `--targets a,b,c` flag; bin/consult-synthesize.sh refactored to emit per-section seed drafts under `.draft/`. commands/consult.md renumbered to clean integers 0–16; new Steps 10 (multi-repo auto-detect via cwd siblings + topic-prose grep), 11 (per-section Approve/Revise/Skip walk over 6 single-repo or 8 multi-repo sections), 12 (assemble + audit gate with retry mapping). Doc shape: Problem/Goal/Architecture/Components/Testing/Success Criteria (single) + Execution DAG / Cross-Repo Notes + per-repo subsections + `**Target Sub-Project(s):**` header (multi). Soft DAG format only; multi-repo docs route to /executeorder66 (out of plugin). `/clone-wars:deploy` stays single-repo. Partially reverses v0.14.0's hub-mode deletion: auto-detect + per-repo subsections + soft DAG restored; 282 LoC of validators stay deleted. Spec at `docs/superpowers/specs/2026-05-08-consult-spec-merge-design.md`.
- [ ] v0.17.0 strict-dogfood pass on a real machine (release gate — verify: (1) single-repo trivial fast-path produces 6-section deploy-audit-passing doc; (2) single-repo escalated path runs trooper roster + design walk; (3) multi-repo escalated path auto-detects sibling CLAUDE.md, asks AskUserQuestion to confirm targets, walks 8 sections with `**Target Sub-Project(s):**` header + soft DAG; (4) audit-fail recovery — Skip success-criteria → re-walk → audit PASS; (5) `--targets foo,bar <trivial topic>` forces escalation; (6) /clone-wars:deploy reads single-repo /consult output cleanly)
- [x] v0.18.0: medic trooper-select — `/clone-wars:medic` now runs interactive Steps A–G after the health table; user picks an active subset (preset N=2/3 menu or per-provider Customize walk for N=4); selection persists in `$state_root/providers-active.txt` and `bin/consult-init.sh` prefers it over `providers-available.txt`; new `cw_active_providers_path` resolver in `lib/state.sh` is the single source of truth for precedence; `bin/medic.sh` unchanged (interactivity is Claude-side only). Spec at `docs/superpowers/specs/2026-05-08-medic-trooper-select-design.md`.
- [ ] v0.18.0 strict-dogfood pass on a real machine (release gate — verify: (1) all-providers detected → preset menu offers all subsets; (2) Customize walk per-provider; (3) selection persists across medic re-runs; (4) /consult uses active subset; (5) stale provider entry filtered with note: line; (6) empty-selection guard refuses write)
- [x] v0.18.1: medic Step D AskUserQuestion 4-option cap fix — flat 5-option menu for N=3 (`All three` + 3 pairs + `Customize`) was unimplementable; rewritten as 2-step nested pattern (Step D.1 high-level: `All three` / `Pick a pair (drill in)` / `Customize…`; Step D.2 fires only when D.1 returns `Pick a pair`, drills with the 3 pair options). N=2 menu unchanged. Static-wiring test asserts D.1/D.2 structure + negative-asserts the legacy "5 options" prose.
- [x] v0.18.2: medic skill-reviewer polish — frontmatter `allowed-tools` adds `AskUserQuestion`, description expanded to mention trooper-roster picker, one-line preamble distinguishes bash-wrapper (Steps 1–6) from Claude-side flow (Steps A–G), stale "spawn.sh prints stub messages" parenthetical at Step 6 dropped (pre-v0.0.6 leftover), `lib/consult.sh:1157` line-number cite replaced with bare function name (drift-prone), trigger-phrase examples added so future-Claude can route natural-language requests ("switch consult roster", "use only rex and cody", etc.), FAIL-verdict carve-out documented (Steps A–G run on FAIL too if `providers-available.txt` has ≥1 entry). Static-wiring test extended with 6 new asserts + 2 negative-asserts. No behavioral changes.
- [x] v0.18.3: consult skill-reviewer polish — `commands/consult.md` (1045 lines) gets P0+P1+P2 review fixes. Frontmatter: add `allowed-tools` (was missing entirely) + `argument-hint` advertises `--use-force` and `--targets`. Intro: "When to use this command" trigger-phrases block + v0.17.0 spec added to citations. Task table: row 1 renamed "Phrasing trigger scan (skipped if --use-force)", row 2 renamed "4-signal complexity check + route (fast-path or escalate)". Step 0: `--design-doc` deprecation now surfaced via chat (not just `log_warn` stderr). Step 1: "skip Step 2" wording corrected to "skip the 4-signal sub-block within Step 2". Step 2: fast-path audit-fail explicitly says "re-invoke walk-assemble" + progress-signaling `log_info` recipe added. Step 9: explicit "intermediate artifact" labeling for `_consult/adjudicated.md` so fresh-Claude doesn't grep for `## Contested` in the design-doc. Step 11: critical-section skip rule extended from `goal/architecture` to all four required-by-audit sections (`goal/architecture/testing/success-criteria`) — closes walk↔audit retry-loop. Step 13: duplicate `5b.` numbering renumbered to `6/7`. Step 16: now points user to `/clone-wars:deploy <path>` (single-repo) or `/executeorder66 <path>` (multi-repo). Step 5: forward-ref to `CW_CONSULT_SKILL_OVERRIDE=none` kill switch. Stale "v0.14.0 default" stamp dropped. Static-wiring test extended with 13 new asserts + 2 negative-asserts. No behavioral changes.
- [x] v0.19.0: spawn preflight refactor — two-phase trooper allocation replaces the `.last_pane` chain race in `/clone-wars:consult`. New `bin/preflight-layout.sh` splits N panes off Yoda's pane in a single bash process, applies `tmux select-layout main-vertical`, writes ordered `_consult/preflight-panes.txt`. New `bin/spawn.sh --target-pane <id>` flag dispatches via `tmux respawn-pane` (no `.last_pane` reads/writes on this path; strict validation against preflight-panes.txt). `commands/consult.md` Step 3 split into 3a (preflight, foreground) + 3b (parallel spawn dispatch with Stage 1 retry-once + Stage 2 partial-success AskUserQuestion). `bin/consult-teardown.sh` extension cleans preflight orphan panes. Backwards-compat: spawn.sh without `--target-pane` is byte-equal to v0.18.3 (legacy split-window + `.last_pane` flow preserved for `/clone-wars:deploy`). Five new tests + 1 v0.17 test update.
- [ ] v0.19.0 strict-dogfood pass on a real machine (release gate — verify: (1) 3-trooper consult --use-force produces three evenly-sized panes that all appear within ~2s of preflight call, no "1 then 2 then 3" appearance; (2) Yoda pane stays at ~50% width throughout; (3) /clone-wars:deploy single-trooper spawn behavior is byte-equal to v0.18.3; (4) Stage 1 retry absorbs codex cold-start invisibly; (5) Stage 2 partial-success AskUserQuestion offers degrade-or-abort when retry fails)
- [ ] v0.6: drop config/identity-template.md back-compat symlink + sweep tracer/*.sh + README.md legacy refs
- [ ] Submit to claude-plugins-official (post v0.5.x dogfood)
