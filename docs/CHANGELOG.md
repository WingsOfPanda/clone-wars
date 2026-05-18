# Changelog

All releases of the Clone Wars Claude Code plugin, newest first.
Per-version design specs live under `docs/superpowers/specs/` and plans
under `docs/superpowers/plans/`. This file is a release-note index, not
a design trail.

---

## v0.42.0 — 2026-05-17 — deploy git-repo discipline

**Rule.** `/clone-wars:deploy` now operates on the conductor's current
branch in every affected repo (single-repo and hub mode). The auto-branch
`feat/deploy-<topic>` becomes opt-in via `--branch [name]`. Pre-deploy
WIP is committed automatically; post-deploy leftovers are swept;
per-repo summary blocks land in chat at Step 4 before archive.

### New surface

- **`lib/deploy.sh`**: 4 new helpers — `cw_deploy_iter_targets`,
  `cw_deploy_pre_snapshot`, `cw_deploy_post_sweep`,
  `cw_deploy_format_summary_block`.
- **`bin/deploy-pre-snapshot.sh`**: walks `cw_deploy_iter_targets <topic>`,
  writes per-target baselines under `$ART_DIR/baselines/<slug>.tsv`.
- **`bin/deploy-summary.sh`**: walks targets, sweeps leftovers
  (`$ART_DIR/posts/<slug>.tsv`), prints one summary block per target.
- **BRANCH DISCIPLINE stanza** appended to all 3 deploy prompt builders
  (round1, fix, dag-unit) — instruction-level trooper enforcement.
- **`tests/test_deploy_branch_pin_lint.sh`**: permanent lint guarding
  stanza presence.

### Default behavior shift (migration)

- `/clone-wars:deploy <doc>` no longer creates `feat/deploy-<topic>` by
  default. Stays on current branch; commits pre-deploy WIP as
  `chore: WIP before deploy <topic>`; runs trooper turns; sweeps
  post-deploy leftovers as `chore: post-deploy leftovers for <topic>`;
  prints per-repo summary block.
- `/clone-wars:deploy --no-branch` becomes a no-op (kept for one
  release for back-compat; may be removed in v0.43.0).
- `/clone-wars:deploy --branch [name]` preserves the old sandbox-branch
  flow; the snapshot/sweep ceremony still applies.
- Old sub-step 5a (`Stash and continue` / `Commit first` /
  `Abort` AskUserQuestion) removed. `pre-deploy-stash.txt` artifact
  removed. Old `test_deploy_dirty_intercept_directive.sh` removed.
- `bin/deploy-init.sh` rc=7 only fires when `--branch` is present.

### Failure modes (warn + proceed, except not-a-repo)

| Condition | Behavior |
|---|---|
| Pre-snapshot commit hook blocks | Warn, baseline.state=hook-blocked, proceed |
| Pre-snapshot target not a git repo | Abort deploy (rc=2) |
| Pre-snapshot detached HEAD | Warn, branch=`(detached)`, proceed |
| Trooper switches branch | Detected; WARNING in summary; deploy completes |
| Post-sweep hook blocks | Warn, post.state=sweep-failed, deploy completes |

### Tests added

- 13 new unit/integration tests (iter_targets, pre_snapshot×6,
  post_sweep×3, format_summary_block, e2e single + hub).
- 1 permanent lint (`test_deploy_branch_pin_lint.sh`).
- 1 version-stamped static-wiring lock
  (`test_v0_42_0_static_wiring.sh`, 8 invariants).

### Dogfood gate (release-gate)

- [ ] Single-repo deploy on a dirty branch completes with snapshot
  + summary; no AskUserQuestion fires.
- [ ] Hub-mode deploy (≥2 sub-repos) produces N summary blocks
  back-to-back with correct per-repo branches and diffs.
- [ ] `/clone-wars:deploy --branch sandbox <doc>` still creates
  `sandbox` branch and applies snapshot/sweep.
- [ ] User with a pre-commit hook sees WARNING in summary; deploy
  still completes.

### Out of scope (explicit)

Stash mode; per-task summary granularity; atomic cross-repo rollback;
summary persistence to file; auto-recovery from branch-pin violations;
`--summary-file` flag.

---

## v0.41.0 — 2026-05-16 — simplification sweep

Six mechanical refactor lanes, ~30 LOC net removal, zero behavioral change
except one strict-monotonic tightening (Lane B).

### Lanes

- **A — deep-research topic helpers.** Add `cw_deep_research_normalize_topic`
  (auto-prefix variant) and `cw_deep_research_assert_topic` (hard-error
  variant) in `lib/deep-research.sh`. Migrate 7 callers (4 auto-prefix +
  3 hard-error).
- **B — meditate topic helper.** Add `cw_meditate_assert_topic` in
  `lib/meditate.sh`. Migrate 5 callers. **Behavioral note:** this lane
  adds a `cw_consult_topic_validate` call that the open-coded form
  omitted — strict-monotonic tightening (rejects fewer invalid topics,
  never the reverse).
- **C — atomic-write stragglers.** The last two `printf > .tmp && mv .tmp dst`
  sites (`bin/deep-research-refine.sh:45`, `lib/consult-wait.sh:140`)
  migrated to `cw_atomic_write`.
- **D — topic-state-dir stragglers.** The last two open-coded
  `$state_root/state/$repo_hash/$TOPIC` assemblies
  (`bin/deep-research-{teardown,finalize}.sh`) migrated to
  `cw_topic_state_dir`. Side effect: `teardown.sh` local var
  `state_dir` renamed to `TOPIC_DIR` for consistency with downstream
  references.
- **E — deploy commander helper.** Add `cw_deploy_assert_commander` in
  `lib/deploy.sh` (sibling to existing `cw_deploy_assert_topic`).
  Migrate one caller (`bin/deploy-wave-wait.sh:28`). The four other
  open-coded commander regexes (spawn.sh + 3 deep-research scripts)
  stay as-is — they're intentional layered hardening with distinct
  character classes; see the v0.41.0 spec for the per-site rationale.
  Spec originally said `cw_consult_assert_commander`; plan deviated
  because `lib/deploy.sh` does not source `lib/consult.sh`.
- **F — metric.md awk collapse.** `cw_deep_research_check_completion`
  previously spawned 6 awks to parse 7 fields from metric.md; collapsed
  to a single awk pass that emits shell-eval-ready KEY='value' lines
  (single-quote wrapping prevents op-words like `>=` from being parsed
  as redirection).

### Explicitly deferred

The simplifier surfaced these but they are NOT v0.41.0 material — listed
here so future sweeps don't re-propose them without reading the spec.

- **JSON event-extraction helper.** `bin/list.sh:66` and
  `bin/deploy-turn-send.sh:39` extract different JSON fields from
  different files; no shared shape worth abstracting.
- **`consult-walk-assemble.sh` duplicate pipeline.** 2 visible lines in
  adjacent case-branches; lifting hurts readability.
- **Test scaffold extraction.** ~80 of 232 test files share a 6-line
  bootstrap. Mechanical but high churn; needs its own dedicated PR if
  ever pursued.
- **`PLUGIN_ROOT` bootstrap × 46.** Each script then sources a different
  lib subset; sharing saves at most one line per file.

See `docs/superpowers/specs/2026-05-16-v0.41.0-simplification-sweep-design.md`
for the full design and per-item rationale.

### Release-gate dogfood status

Same as v0.40.0 — strict-dogfood passes for v0.31.0–v0.40.0 still
pending; v0.41.0 dogfood is the suite-green check (227 ok; documented
timing-sensitive flakes `test_consult_targets_forces_escalation.sh` and
`test_deploy_archive.sh` pass standalone retry).

---

## v0.40.0 — 2026-05-16 — per-session isolation for same-repo parallel sessions

- Closes the two same-repo cross-session bleed gaps surfaced by the v0.39.0
  audit of "commands should run in parallel across sessions without conflicting".
- **Hook session-match.** `hooks/user-prompt-submit-active-session.sh` now reads
  `.session_id` from stdin JSON (jq with sed fallback), sanitizes via uuid-shape
  regex, and matches `active-<that-sid>.txt` under
  `.clone-wars/state/<repo-hash>/<topic>/_deep-research/`. Markers from other
  Claude Code sessions in the same repo become invisible to this session's hook
  fire. `bin/deep-research-init.sh` writes the stamped marker;
  `bin/deep-research-finalize.sh` removes both the stamped form and any legacy
  bare `active.txt` from pre-v0.40.0 state.
- **Owner-session disclosure on (topic, commander) collision.**
  `lib/ipc.sh::cw_state_init` stamps `.session_id` into every fresh trooper
  state dir. New helper `cw_format_collision_error` in `lib/commanders.sh`
  reads it on retry; `bin/spawn.sh` routes its rejection through the helper.
  Two parallel sessions colliding on the same `(topic, commander)` now see
  `(id=<owner-prefix>…, mine=<my-prefix>…)` so they can disambiguate stale
  state from a sibling terminal's live state.
- New permanent lint `tests/test_active_per_session_lint.sh` (no skip-guard,
  bans bare `active.txt` in `bin/`, `lib/`, `hooks/`) +
  `tests/test_v0_40_0_static_wiring.sh` (7-invariant version-locked).
- Strict-dogfood: [ ] v0.40.0 strict-dogfood pass on a real machine (open two
  terminals in the same clone-wars checkout; one runs
  `/clone-wars:deep-research`; the other submits prompts that must NOT get
  injected with resume-handler context).

## v0.39.0 — 2026-05-16 — directive `${CLAUDE_PLUGIN_ROOT}` brace migration

- Closes first v0.38.0 dogfood finding: 96 unbraced `$CLAUDE_PLUGIN_ROOT`
  references across consult/deploy/meditate/medic/list/teardown directives
  survived render-time substitution, breaking copy-paste into Bash subshells
  where the env var is unset.
- Pure mechanical sed: `$CLAUDE_PLUGIN_ROOT` → `${CLAUDE_PLUGIN_ROOT}`. Zero
  logic changes. `deep-research{,-resume}.md` unchanged (already 100% braced
  from v0.37.0).
- New permanent lint `tests/test_braced_plugin_root.sh` (no skip-guard) +
  5-invariant version-locked static-wiring lock prevent regression.
- Strict-dogfood: ride v0.38.0 dogfood (the failing /clone-wars:medic Step A
  bash block this fix closes IS the dogfood evidence).

## v0.38.0 — 2026-05-16 — state-root split (per-machine vs per-project)

- Closes medic→consult chain break on fresh installs: medic wrote per-project
  `providers-available.txt` but Step A roster picker read global path → silent
  "skipping trooper selection" warning.
- New `cw_global_state_root` helper (always `${CLONE_WARS_HOME:-$HOME/.clone-wars}`)
  alongside `cw_state_root` (per-project); 15+ sites migrated per data ownership.
- Archive dir converges on `~/.clone-wars/archive/` (matches meditate, matches
  pre-v0.31.0 default).
- Drops `commands/medic.md` `_args/` boilerplate (medic takes no args).
- New permanent lint `tests/test_state_root_discipline.sh` (no skip-guard);
  10-invariant static-wiring lock.
- Breaking: v0.31-v0.37 project-local copies become inert; users re-run `/medic` once.
- Strict-dogfood: [x] partial — 1 finding caught + fixed in v0.39.0 (unbraced `$CLAUDE_PLUGIN_ROOT` in 6 directives broke copy-paste into Bash subshells); remaining release-gate items pending.

## v0.37.0 — 2026-05-16 — portable paths

- Fixes 47 hardcoded `/home/liupan/CC/clone-wars/...` paths in
  `commands/deep-research.md` (42 sites) + `commands/deep-research-resume.md` (5
  sites) — plugin's two newest flagship features were non-functional on any
  non-author install.
- Mechanical conversion to `${CLAUDE_PLUGIN_ROOT}/<path>` (matches canonical
  pattern already used by consult/meditate/deploy/medic).
- New permanent lint `tests/test_no_hardcoded_paths.sh` (no skip-guard) —
  word-bounded `/home/<user>/` regex catches any future contributor.
- 7 version-locked invariants on top.
- Stacked off v0.36.0; landed as PR #102 after merge-order rebase.
- Strict-dogfood: [ ]

## v0.36.0 — 2026-05-16 — `_run/` pointer migration

- Closes cross-session pointer collision: `/tmp/cw-*` pointer files used by
  directive Bash blocks to bridge state across separate tool calls were
  session-global by name; two parallel `/clone-wars:*` invocations in different
  repos overwrote each other's pointers → walk-assemble wrote design doc to
  wrong path → drill trooper saw mtime change.
- New `cw_run_dir <command>` + `cw_run_dir_last` helpers in `lib/state.sh`;
  project-local mktemp dir at `$state_root/_run/<command>.XXXXXX/`.
- Cross-block discovery via `_run/.last` writeback (atomic via
  `cw_atomic_write`, project-local — different repos → no collision).
- 24h stale sweep on each `cw_run_dir` call (override via `CW_RUN_SWEEP_S`).
- Migrates ~44 sites across consult/meditate/deep-research/deploy directives.
- 4 unit tests + 8 static-wiring invariants.
- Strict-dogfood: [ ]

## v0.35.0 — 2026-05-16 — trooper liveness (per-provider timeout multiplier + mtime probe)

- Closes false-`FS=timeout` symptom hit during `/clone-wars:consult` when wolffe
  (opencode/DeepSeek V4 Pro) recorded timeout while findings.md was 18 KB.
- Layer A: new `cw_contract_timeout_multiplier` helper in `lib/contracts.sh`;
  opencode ships `2.5x` (effective research 1500s / verify 750s / adversary
  1500s / experiment 4500s); codex/claude/gemini implicit `1.0`.
- Layer B: `cw_consult_wait` checks outbox.jsonl mtime before declaring timeout;
  extends deadline by `LIVENESS_GRACE_S` (180s) if outbox touched within
  `LIVENESS_PROBE_S` (120s), capped at `MAX_DEADLINE_FACTOR × baseline` (2×).
- GNU `stat -c '%Y'` → BSD `stat -f '%m'` fallback chain (macOS support).
- EXP_ID stale-done guard from v0.27.2 BUG #6 preserved byte-equal.
- `CW_CONSULT_LIVENESS_PROBE_S=0` disables (v0.34 escape hatch).
- 3 new test files (5 unit + 3 functional + 8 static-wiring invariants).
- Strict-dogfood: [ ]

## v0.34.0 — 2026-05-15 — deep-research long-session tooling

- D1 — `bin/deep-research-fresh-trooper.sh <topic> <commander>`: graceful pane
  reset; tears down + respawns; preserves `exp_counter` + experiments history;
  refuses when `phase=working`.
- D2 — `bin/deep-research-refine.sh <topic> <commander> <exp-id> <text>`: writes
  numbered `refine-N.md` into experiment branch dir + nudges pane (mid-experiment).
- D3 — `--inputs=<path1>,...` flag on experiment-send: pre-flight `[[ -r $p ]]`
  per path; rc=2 with offending path on stderr (closes silent-empty-output bug).
- D4 — `--context-file=<path>` flag interpolates content into `{{TASK_CONTEXT}}`
  placeholder; lets Yoda deliver ~200-300 token briefs without polluting inbox.
- `--slug=<name>` flag on init: strict `^[a-z][a-z0-9-]{0,17}$` regex (keeps
  full topic ≤32 chars per v0.27.0 BLOCKER #1 invariant).
- Directive prose: Phase 4 brief relaxed (1-2 sentences OR 1-2 paragraphs);
  Phase 2 adds approach-diversity guidance; Phase 4 adds asymmetric-framing
  convergence pattern.
- Pure additive bundle; all flags optional.
- Strict-dogfood: [ ]

## v0.33.0 — 2026-05-15 — deep-research schema rework + consensus primitive

- D1 — mandatory `metric_name` match: new `cw_deep_research_validate_result_json_v033`
  enforces `result.json.metric_name == metric.md primary_metric`; scoreboard
  gains 8th column (`metric_name`); rows with mismatched name skipped from
  convergence check. Eliminates v0.32.0 false-convergence bug.
- D2 — per-experiment validation feedback: writes `result-validation.txt` on
  failure with specific reason; stale audit files cleaned when result.json fixed.
- D3 — schema expansion: optional `self_reported_count` / `self_reported_ratio`
  / `self_reported_notes` fields (advisory only; `metric_value` canonical).
- D4 — `bin/deep-research-consensus.sh <topic> [--epsilon=<float>]` writes
  `consensus.md` with `## Agreed` / `## Contested` / `## All-missing` sections;
  epsilon-aware numeric equality; jq when present, grep fallback otherwise.
- D5 — `bin/send.sh` adds non-blocking warning when target's `state.txt
  phase=working` (doesn't refuse; preserves abort-script call path).
- 5 new test files + 10-invariant static-wiring lock; soft-breaking migration.
- Strict-dogfood: [ ]

## v0.32.0 — 2026-05-15 — deep-research Monitor surface + dispatch UX bundle

- Bug #1: `bin/deep-research-monitor.sh` reads `state.txt` and emits stale/stuck
  only when `phase=working` — idle/stale/blocked/failed produce zero noise.
- Bug #3: `liveness-cursor.txt` persists across Monitor restarts.
- Bug #2: periodic line-count rescan every `CW_DEEP_RESEARCH_RESCAN_EVERY_S=30s`
  re-reads outbox; `liveness-rescan-emitted.txt` dedups across rescans.
- Bug #7: `bin/deep-research-experiment-send.sh` auto-prefixes bare topics.
- #8: `PROBE_S` 300→900s, `STUCK_S` 600→1800s.
- #16: NEW `bin/deep-research-abort.sh <topic> [<reason>]` one-shot graceful teardown.
- #23: NEW `--time-budget=<value>` + `--metric=<k1=v1,...>` flags on init
  pre-write state files; skip Phase 1/2 AskUserQuestions when state files exist.
- 6 new test files + 10-invariant static-wiring lock. Net ~700 LoC.
- Strict-dogfood: [ ]

## v0.31.0 — 2026-05-14 — project-local state relocation

- Item 1: `cw_state_root` default returns `$PWD/.clone-wars`; auto-writes
  `<root>/.gitignore` with `*` (self-ignoring). `CLONE_WARS_HOME` env var
  kept as test/debug seam.
- Item 2: `hooks/user-prompt-submit-active-session.sh` scans
  `$PWD/.clone-wars/state` directly (cross-session bleed fixed at scope layer).
- Item 3: 8 directives use `mktemp -p "$(cw_state_root)/_args"` for unique
  per-invocation paths; new `cw_args_file_consume` helper cleans up.
- Item 4: `CW_TOPIC_REPO_CWD` removal — `bin/deploy-init.sh` drops the export;
  3 directive re-exports dropped; 6 tests updated.
- Breaking: existing `~/.clone-wars/state/` content invisible to v0.31.0+ tooling.
- 12-invariant static-wiring lock.
- Strict-dogfood: [ ]

## v0.30.0 — 2026-05-14 — deploy correctness 4-item bundle

- Item 1: consult Step 10 corpus swap (`topic.txt` → `adjudicated.md` with
  fallback) — catches sub-repos that emerged during trooper research.
- Item 3: deploy dirty-tree Yoda intercept — `cw_deploy_branch_create` returns
  rc=7 on dirty tree; AskUserQuestion (Stash/Commit-WIP/Abort); stash captured
  by SHA via `stash list -1 --format=%H` (race-safe).
- Item 2: deploy adjacent-tree commit guard — new `lib/deploy-sibling.sh` with
  4 helpers; `_deploy/sibling-baseline.txt` + `sibling-rogue.txt` 3-col TSV;
  AskUserQuestion (Revert+replay/Keep/Send back); two-phase `revert_and_replay`.
- Item 4: deploy scope conformance check — new `lib/deploy-scope.sh` with
  awk-based markdown table parser scoped to `## Components`; directory-prefix
  match; AskUserQuestion (Accept+amend/Send back/Force-keep).
- New `cw_deploy_resolve_hub` helper pins contract for v0.31.0+ relocation.
- 12-invariant static-wiring lock.
- Strict-dogfood: [ ]

## v0.29.0 — 2026-05-13 — simplification sweep

- Cluster A (1,365 LoC deleted): `rm -rf tracer/` (5 pre-v0.0.6 scripts, zero
  runtime callers) + `rm config/identity-template.md` symlink + drop dead
  defensive fallback in `lib/ipc.sh:cw_identity_write`.
- Cluster C (30 LoC prose): README v0.4 design-doc subsection deleted;
  docs/DESIGN.md tracer-bullet section re-framed historical.
- Cluster B1 (206 LoC): dropped `cw_deep_research_check_plateau` (subsumed by
  v0.28.0's check_completion); 2 dedicated test files deleted.
- Cluster B2: added `cw_deep_research_trooper_state_field` helper; swapped 10
  single-field state.txt call sites.
- Cluster B3: migrated 6 hand-rolled `tmp+mv` blocks to `cw_atomic_write`.
- Cluster D1: added `cw_state_archive_dir` to `lib/state.sh`; consult/deploy
  archive scripts shrunk to thin wrappers.
- Cluster D2: added `cw_teardown_with_preflight_orphans` to `lib/tmux.sh`;
  consult/meditate/deep-research teardowns shrunk to single helper call.
- Cluster E: dead pre-Phase-0 cache block deleted in deep-research directive.
- New `test_v0_29_0_static_wiring.sh` locks 8 invariants. Net ~2,080 LoC removed.
- Strict-dogfood: [ ]

## v0.28.3 — 2026-05-13 — deep-research preflight pane allocation

- Ports v0.19.0 consult preflight pattern (already used by meditate v0.25.0+).
- Closes v0.28.2 dogfood bugs: sequential spawn (rex→keeli 52s gap from
  `.last_pane` race) + uneven pane heights.
- Phase 3 split into 3a (foreground preflight via
  `bin/preflight-layout.sh --art-dir _deep-research --troopers-from
  troopers-preflight.txt`) + 3b (N parallel `bin/spawn.sh --target-pane` dispatches).
- Bridges schema gap via `cw_deep_research_write_preflight_sidecar` (writes
  consult-shaped 2-col TSV); native 1-col `troopers.txt` preserved.
- `bin/deep-research-teardown.sh` calls `cw_preflight_kill_orphans`.
- Stage 1 retry-once + Stage 2 partial-success AskUserQuestion from meditate.
- 3 new tests + 5-invariant static-wiring lock.
- Strict-dogfood: [ ]

## v0.28.2 — undated — deep-research UX bundle

- (1) Always-ask time-budget: Phase 2 step 2 stamped `UNCONDITIONAL — v0.28.2`;
  fires on every invocation regardless of autonomous-mode hints or `/loop`
  reminders.
- (2) Per-experiment status form: new `cw_deep_research_render_status_brief`
  helper emits compact chat-shaped status block (per-trooper table + scoreboard
  top 3 + completion-check signals); resume handler Step 3 done/error route
  surfaces it after each landed experiment.
- (3) v0.28.0 BUG #3 fold-in: Phase 4.a step 1 now writes `troopers.txt` from
  `${ROSTER[@]}` (was read-but-never-written; left `## Status` table empty).
- Pre-merge polish closed 10 self-review findings (working-trooper approach
  parsed from prompt.md, unconditional stamps on Phase 1 too, troopers.txt
  atomic write, etc.).
- 2 new test files + 9-invariant static-wiring lock.
- Strict-dogfood: [ ]

## v0.28.1 — undated — deep-research dogfood bug-bundle

- BUG #1 (P1): `bin/deep-research-experiment-send.sh:73` called `cw_outbox_offset`
  without sourcing `lib/ipc.sh`; non-fatal but emitted `command not found`.
- BUG #2 (P0): `bin/deep-research-score.sh:106-118` used `ls "$cmdr_dir/experiments"/*/result.json`
  under `shopt -s nullglob` — empty glob → `ls` with no args → exits 0
  unconditionally → race flipped working trooper-B to idle when trooper-A
  finished first. Fix: gate on trooper's CURRENT `current_exp_id` having a
  result.json.
- 2 new tests (2 + 9 asserts); no directive or schema changes.
- Strict-dogfood: [ ]

## v0.28.0 — 2026-05-13 — deep-research per-trooper turn loop

- Replaces Phase 4's intra-turn loop with per-trooper independent turn cycles
  driven by `Monitor` + `<task-notification>`. Yoda idle between events; user
  can chat freely.
- Custom completion-check (floor + target + K-corroboration + plateau)
  replaces v0.27.x stagnation/time-budget AskUserQuestions.
- Liveness escalation (mtime → `status?` probe → stuck) replaces foreground
  experiment-wait blocking.
- Plugin-portable re-entry via `hooks/user-prompt-submit-active-session.sh` +
  `commands/deep-research-resume.md` (handler 3.b directive).
- New helpers: `cw_deep_research_trooper_state_read/write`, `_check_completion`,
  `_render_summary`, `_check_plateau`.
- New bin scripts: `deep-research-monitor.sh`, `deep-research-finalize.sh`.
- Deleted: `bin/deep-research-experiment-wait.sh` (Monitor replaces foreground waits).
- State schema rebuilt: `troopers/<cmdr>/state.txt` (KV), per-trooper experiments
  dirs, `session-summary.md`, `monitor-tasks.txt`, `active.txt`.
- `metric.md` gains `min_acceptable`, `K_corroboration`, `plateau_window`,
  `plateau_threshold` fields.
- Strict-dogfood: [x] partial 2026-05-13: items 1, 2, 6, 7, 9, 10 verified green
  (Monitor task arming, task-notification → Yoda turn, rolling session-summary,
  hook injection, completion-check Yoda override, 1-2 sentence dispatches);
  items 3/4/5/8 not exercised; 2 P0+P1 bugs surfaced + fixed in v0.28.1.
  Winning approach: compact ResNet + group conv + label smoothing → 0.9971
  accuracy at 86,522 params on round 1.

## v0.27.3 — undated — code-simplifier sweep (outbox-offset helper)

- P0-1: extract 8-site `wc -c < outbox | tr -d <ws>` byte-offset idiom into
  new `cw_outbox_offset <outbox-path>` helper in `lib/ipc.sh`; folds in
  `bin/consult-drilldown.sh`'s missing-file `|| echo 0` fallback.
- Swaps 7 bin scripts + 1 internal call site.
- P2-11: drop redundant `[[ "$TOPIC" =~ ^[a-z0-9-]+$ ]]` from meditate
  research/adversary sends (`cw_consult_topic_validate` superset already accepts).
- New `tests/test_outbox_offset.sh` (5 cases).
- Skipped: wait-shim consolidation + deep-research dead pane-id block (separate passes).
- Strict-dogfood: ride v0.27.2 dogfood (pure refactor with unit coverage).

## v0.27.2 — 2026-05-12 — deep-research bug bundle (3 P0/P1 + 1 enhancement)

- BUG #4 (P0): `experiment-send.sh:102` sed substitution corrupted multi-line
  `APPROACH_BRIEF` to 0-byte `prompt.md`; line-110 sanity check silently passed.
  Fix: single awk pass for all 10 template tokens; sanity check adds `-s` gate.
- BUG #5 (P0): troopers paused 3-4min post-training before `{event:"done"}`;
  template step 5 procedural wording. Fix: "**THIS IS THE TERMINAL STEP**"
  framing + new `{{OUTBOX_PATH}}` placeholder.
- BUG #6 (P1): `cw_consult_wait` done-event handler matched without verifying
  `$EXP_ID`; phantom done from empty inbox tripped stale rc=0. Fix: stale-event
  skipping loop with atomic OFFSET advance.
- P2 enhancement: hardware probe (init baseline + per-experiment current + diff
  alert >50% memory.free drop); new `{{HARDWARE_BLOCK}}` placeholder.
- P3 doc: clarify `cw_consult_timeout experiment)` default 1800s is wall-clock cap.
- 5 new tests; static-wiring lock extended.
- Strict-dogfood: [ ]

## v0.27.1 — undated — consult single-sub Target Sub-Project header

- Closes user feedback after v0.27.0 dogfood on `ars_fleet`'s halftime-preselect
  deploy: `/clone-wars:deploy` in a hub spawned trooper inside the hub even
  though design doc only modified one sub-repo.
- Root cause: `bin/consult-walk-assemble.sh` only emitted plural
  `**Target Sub-Project(s):**` header; single-sub case had nowhere to declare.
- NEW mode `multi-repo.txt = single-sub`: `consult-init.sh` writes for 1-slug
  `--targets`; assemble emits singular `**Target Sub-Project:** <slug>` header
  + 6-section list (no DAG / Cross-Repo Notes).
- `commands/consult.md` Step 10 splits auto-detect branch: 1 hit →
  `Use <slug>` vs `Treat as hub-level` AskUserQuestion.
- 2 new tests; single-repo + multi-repo paths byte-equal v0.27.0.
- Strict-dogfood: [ ]

## v0.27.0 — 2026-05-12 — deep-research advisor rewrite

- Drops K×N round structure for advisor-with-PhD-students model (2-3 long-lived
  codex troopers spawned once).
- Metric-discussion preflight (free-form dialogue → structured `metric.md`).
- Time-limit AskUserQuestion before spawn (`none` / `4h` / `12h` / custom).
- Stagnation safety net: 5 consecutive <1% experiments when no time budget.
- Flat `_deep-research/experiments/exp-NNN-<cmdr>/` state shape replaces `round-N/`.
- Rolling `scoreboard.md`; single batched teardown (one 9s banner).
- Folds 7 v0.26.0 dogfood fixes: slug cap 18 (BLOCKER #1), `experiment)` case
  in wait-shim (BUG #2), prompt-template fixes (BUG #3), `--allow-net` flag
  removed (default true via template), absolute paths in directive Bash blocks.
- Inter-trooper messaging deferred to v0.28+.
- Strict-dogfood: [ ]

## v0.26.0 — 2026-05-12 — `/clone-wars:deep-research` AIDE-pattern executable autoresearch

- New user-facing command: conductor (Yoda/claude) plans (hypothesize + score +
  select + synth); codex troopers execute (one branch per trooper, single-turn,
  implement + run + result.json).
- K branches per round × N rounds tree search; convergence early-exit
  (delta < 1% × 2 rounds).
- Honor-system sandboxing (v1) with `--allow-net` opt-in.
- `--seed-from <meditate-landscape>` bootstraps round 1 from meditate's
  Approaches section.
- Final doc emits `Suggested next: /clone-wars:deploy <winner-code-path>`.
- 5 new bin scripts + `lib/deep-research.sh` + `config/prompt-templates/deep-research/experiment.md`.
- Lib extensions: art-dir routing, topic validation, `experiment` wait kind
  (default 1800s).
- 7 new tests + static-wiring lock.
- Strict-dogfood: [ ]

## v0.25.1 — 2026-05-12 — meditate 4-bug fix bundle

- (1) `commands/meditate.md` Step 2 preflight call corrected to `$MEDITATE_TOPIC
  $N` form (prefix-aware art-dir routes meditate-* automatically).
- (2) Step 2 spawn arg order corrected (positionals before flags).
- (3) `cw_consult_topic_validate` extended to accept `meditate-*` prefix.
- (4) Conductor-side `Skill(literature-review, ...)` call dropped; Yoda's
  keyword classifier preserved + its ON/OFF passed to each trooper via new
  `{{LIT_GUIDANCE}}` placeholder.
- Deleted: `cw_meditate_parse_lit_flag` + dedicated test (--lit/--no-lit removed).
- New `test_meditate_research_send_lit_guidance.sh` (3 cases).
- Strict-dogfood: [ ]

## v0.25.0 — 2026-05-11 — `/clone-wars:meditate`

- New user-facing command for deep multi-aspect exploration of hard topics
  (SOTA surveys, multi-angle thinking, reference research).
- Reuses v0.24.0 spawn/dispatch/wait infrastructure for research phase.
- Literature-review parallel track auto-detects on ML/SOTA keywords (24-token
  list, override with `--lit`/`--no-lit`).
- Preliminary synthesis on Yoda; 5-signal confidence gate (top-approach
  convergence + dual citations + zero CONTESTED + matrix backing + uncertainty
  acknowledged) → AskUserQuestion default `run-adversary`.
- Adversarial-review round across all N troopers in parallel against
  preliminary synthesis if user doesn't skip.
- Final landscape doc with tradeoff matrix + adversary critiques + directional
  Conclusion intended as hand-off seed for `/clone-wars:consult`.
- New `lib/meditate.sh` + 7 bin scripts + 3 prompt templates.
- 5 new tests + static-wiring lock (11 invariants).
- Strict-dogfood: [ ]

## v0.24.0 — 2026-05-11 — simplification sweep (~850 LoC reduction)

- 15 findings closed across 10 clusters: 3 dead-code purges in `lib/consult.sh`
  (`cw_consult_synthesize`, `_design_doc_self_review`, `_status_load`) + 4
  orphan test files.
- `--design-doc` flag plumbing removed (lib helper + parser + dedicated test);
  4-line deprecation stub kept in `commands/consult.md`.
- New `lib/consult-wait.sh` shared by both wait shims (research + verify
  ~95 LoC each → ~18 LoC shims).
- `_cw_contract_field` private helper dedups 4 awk getters in `lib/contracts.sh`.
- `cw_preflight_kill_orphans` in `lib/tmux.sh` shared by consult + deploy teardown.
- `cw_consult_strip_block` + sentinel-block templates obsolete; dropped.
- `bin/spawn.sh --flag`/`--flag=X` parse dedup via `_kv_parse` nameref helper.
- Only intentional behavior change: `--design-doc <topic>` now errors instead
  of deprecation-warn + silent ignore (deprecated v0.12).
- Strict-dogfood: [ ]

## v0.23.1 — 2026-05-11 — deploy per-trooper sub-rows

- Closes user UX feedback during v0.23.0 dogfood ("we just shown ◼ 3b DAG wave
  dispatch (multi-repo) in conductor progress, it is too little").
- Drops single `3b DAG wave dispatch` row from upfront task table; fires one
  `TaskCreate` per `(wave, repo)` tuple with subject `3b.<step> <Rank> <Cmdr>
  on <repo> [wave <w>]`.
- Wave-loop handler flips sub-rows in_progress on rc=0, completed on `TS=ok`.
- Stage 1 retry-once preserves in_progress; Stage 2 partial-success "Proceed
  degraded" flips dropped repos to completed.
- New `cw_cmdr_rank` helper in `lib/commanders.sh` (Captain / Commander /
  Sergeant / Lieutenant / Trooper).
- UX-only change; dispatch/wave-wait/fix-loop byte-equal v0.23.0.
- Strict-dogfood: [ ]

## v0.23.0 — 2026-05-10 — DAG auto-extract UX

- Closes user feedback during v0.22.0 dogfood ("the rescue intercept stops the
  auto-pipeline and feels like an error every time").
- Step 5b reworded: "DAG rescue intercept" → "DAG auto-extract"; alarming
  framing replaced with neutral "DAG section is prose; auto-extracting
  parser-conforming lines".
- New sub-step 5b.3.5 verifies each extracted line (slug regex + path -d +
  CLAUDE.md/AGENTS.md presence).
- Sub-step 5b.4 auto-proceeds silently on verification PASS (one `log_ok`
  line summarizing extracted slugs; no AskUserQuestion).
- AskUserQuestion safety net fires only on FAIL OR
  `CW_DEPLOY_FORCE_RESCUE_PROMPT=1`.
- Audit log `dag-rescue.log` extended with `verification:` field.
- Strict-dogfood: [ ]

## v0.22.0 — 2026-05-10 — multi-repo deploy seam re-architecture

- Closes 5 layered bugs from v0.21.0 dogfood.
- (1) `bin/spawn.sh --target-pane` validation hardcoded `cw_consult_art_dir`;
  added `--preflight-art-dir <abs-path>` flag (deploy passes; consult omits).
- (2) `bin/preflight-layout.sh` mis-parsed deploy's 3-col `troopers.txt` as
  consult's 2-col; added `--troopers-from <abs-path>` pointing at NEW sidecar
  `troopers-preflight.txt` (consult-shaped 2-col, DAG order).
- (3+4) Closed via the (2) sidecar fix.
- (5) Step 3b dispatch + Step 3d fix-loop used bare `cw_inbox_write` without
  `cw_pane_send` nudge; switched both to `bin/send.sh @file` canonical convention.
- NEW `tests/test_deploy_multi_repo_e2e.sh` (tmux-dependent integration test)
  seals seam end-to-end; would have caught all 5 in one run.
- v0.21.0 in-flight multi-repo state NOT preserved.
- Strict-dogfood: [ ]

## v0.21.0 — 2026-05-10 — multi-repo deploy nested + heterogeneous fleet support

- Closes two failure modes hit on `/home/liupan/ARS/docs/designs/2026-05-10-10t-checkpoint-deploy.md`.
- (1) `cw_deploy_dag_parse_line` regex relaxed `[a-z0-9-]+` → `[A-Za-z0-9_-]+`
  (CapWords/underscore slugs accepted) + optional `(/abspath)` capture group;
  emits 5-field TSV.
- (2) `bin/deploy-multi-init.sh` honors path field with flat-sibling fallback —
  supports nested fleets like `ars_fleet/ARS-{TaskServe,Perfusion,LVMGateway}/`.
- (3) `commands/deploy.md` Step 0 NEW sub-step 5b — Yoda DAG-rescue intercept:
  when init fails on prose DAG, Yoda extracts implicit DAG via judgment,
  AskUserQuestion confirms, Edit inserts `### DAG Lines` subsection into local
  doc copy, then parse + multi-init re-run.
- Rescue is one-shot per deploy.
- Strict-dogfood: [ ]

## v0.20.5 — undated — opencode commander rename + parallel teardown + Read-before-Edit fixes

- `lib/consult.sh` `cw_consult_provider_to_commander` maps `opencode → wolffe`
  (was `bly`); `bly` retained in pool as legacy.
- NEW `bin/teardown.sh --pairs <topic> <cmdr1> [cmdr2] ...` mode batches 9s
  graceful banner across N panes (was per-cmdr loop hit one 9s each).
- `bin/consult-teardown.sh` switched to `--pairs`.
- `commands/consult.md` Step 9 promotes mandatory `Read("$TOPIC_DIR/_consult/adjudicated.md")`
  to top-level callout (Bash `cat` doesn't satisfy Edit tool's per-path read tracker).
- Step 11 per-section walk explicit `Read $DRAFT_DIR/$key.md` before each
  Approve's Write call.
- `commands/deploy.md` Step 1 force-retry uses Bash atomic `tmp+mv` instead of
  Write tool.
- Strict-dogfood: [ ]

## v0.20.4 — 2026-05-10 — simplification + bug-fix sweep

- 11 highest-value findings from v0.20.3 code-simplifier.
- 4 bugs: spawn MODE fallthrough, drilldown collision regex, deploy.md
  unscoped source-defaulting, preflight silent-skip.
- ~120 LoC dead-code purge: `cw_consult_design_doc_filename` +
  `cw_consult_design_doc_assemble` + 6 stale doc-comments.
- ~100 LoC consult.md consolidation: `--design-doc` trim, N=2/N=3 example dedup,
  Steps 5+8 wait-block dedup.
- Strict-dogfood: [ ]

## v0.20.3 — undated — sub-repo trooper spawn cwd discipline

- Multi-repo `/clone-wars:deploy` preflight panes now allocated already-rooted
  in each sub-repo cwd via `tmux split-window -c` (was inherit Yoda's cwd then
  `cd` later).
- `cw_pane_respawn` switches from `cd '$cwd' && exec $launch` to native
  `tmux respawn-pane -c $cwd` (also fixes apostrophe-in-cwd quoting bug).
- `bin/deploy-multi-init.sh` writes new `cmdr-cwd-map.txt`;
  `bin/preflight-layout.sh` gains `--cwd-from` flag.
- Closes latent schema mismatch where preflight read deploy's 3-col troopers.txt
  as if it were consult's 2-col format.
- Strict-dogfood: [ ]

## v0.20.2 — undated — stale-string sweep

- drill-deeper takes design-doc-path as new positional arg (`synthesis.md`
  removed in v0.12 but `bin/consult-drilldown.sh` still tried to read it,
  breaking Step 13 on every consult).
- `commands/consult.md` Pattern numbering 1→2→3 (was 1→3→4 typo); 6 in-prose
  cross-references updated.
- Three `/spec` references in `lib/consult.sh` purged.
- Drill prompt template no longer says "synthesis".
- Strict-dogfood: [ ]

## v0.20.1 — undated — deploy multi-repo wiring fixes (PR #71 follow-up)

- Closes 6 P0 + 4 P1 + 3 P2 findings.
- NEW `bin/deploy-wave-wait.sh` (per-trooper outbox watcher mirroring
  `consult-research-wait.sh`).
- NEW `cw_deploy_build_dag_unit_prompt` lib helper (fully-resolved heredoc;
  eliminates Step 3b literal-placeholder bug).
- NEW `_deploy/multi-verify-bugs.txt` TSV (Step 3c writer → Step 3d reader).
- `bin/deploy-init.sh` now invokes `deploy-dag-parse.sh` + `deploy-multi-init.sh`
  when routing=multi-repo (multi-repo path was unreachable in v0.20.0).
- `bin/deploy-multi-init.sh` accepts optional `<hub-cwd>` 2nd arg + captures
  per-cmdr `<cmdr>-branch-base.sha`.
- Step 3b explicit outer `for ((w=1; w<=WAVE_COUNT))` loop.
- Strict-dogfood: [ ]

## v0.20.0 — 2026-05-10 — deploy multi-repo DAG path

- Auto-detect from design-doc header (`**Target Sub-Project(s):**` plural +
  `## Execution DAG` → multi-repo; else → single-repo byte-equal v0.19.0).
- Multi-repo path: `bin/deploy-dag-parse.sh` parses soft-DAG prose into waves
  (Kahn topological sort + cycle detection).
- `bin/deploy-multi-init.sh` assigns one commander per sub-repo from clone
  trooper pool (cody reserved for claude/plugin-dev).
- Reused v0.19.0 `bin/preflight-layout.sh` (additive `--art-dir` flag).
- NEW Steps 3a (preflight) + 3b (DAG wave dispatch with K parallel spawn calls
  per wave) + 3c (conductor's final verification) + 3d (fix-loop with
  `MAX_FIX_ROUNDS=3` cap + AskUserQuestion at cap).
- Codex trooper runs full superpowers ceremony per sub-repo.
- `cw_deploy_detect_provider` drops opencode.
- Drops `--design-doc` + `synthesis.md` ACTIVE references entirely.
- 8 new tests + 2 v0.19.0 test stabilization fixes.
- Strict-dogfood: [ ]

## v0.19.0 — undated — spawn preflight refactor

- Two-phase trooper allocation replaces `.last_pane` chain race in
  `/clone-wars:consult`.
- New `bin/preflight-layout.sh` splits N panes off Yoda's pane in a single bash
  process, applies `tmux select-layout main-vertical`, writes ordered
  `_consult/preflight-panes.txt`.
- New `bin/spawn.sh --target-pane <id>` flag dispatches via `tmux respawn-pane`
  (no `.last_pane` reads/writes; strict validation against preflight-panes.txt).
- `commands/consult.md` Step 3 split into 3a (preflight, foreground) + 3b
  (parallel spawn dispatch with Stage 1 retry-once + Stage 2 partial-success).
- `bin/consult-teardown.sh` extension cleans preflight orphan panes.
- Backwards-compat: `spawn.sh` without `--target-pane` byte-equal v0.18.3.
- 5 new tests + 1 v0.17 test update.
- Strict-dogfood: [ ]

## v0.18.3 — undated — consult skill-reviewer polish

- `commands/consult.md` (1045 lines) gets P0+P1+P2 review fixes.
- Frontmatter: add `allowed-tools` + `argument-hint` advertises `--use-force` /
  `--targets`.
- Intro: trigger-phrases block + v0.17.0 spec added to citations.
- Task table row renames; Step 0 `--design-doc` deprecation surfaced via chat;
  Step 1 wording corrected; Step 2 fast-path audit-fail explicit retry recipe.
- Step 9 explicit "intermediate artifact" labeling for `_consult/adjudicated.md`.
- Step 11 critical-section skip rule extended from `goal/architecture` to all
  four required-by-audit sections.
- Step 13 duplicate `5b.` numbering renumbered.
- Static-wiring test extended with 13 new asserts + 2 negative-asserts.
- Strict-dogfood: [ ]

## v0.18.2 — undated — medic skill-reviewer polish

- Frontmatter `allowed-tools` adds `AskUserQuestion`.
- One-line preamble distinguishes bash-wrapper (Steps 1–6) from Claude-side
  flow (Steps A–G).
- Stale "spawn.sh prints stub messages" parenthetical dropped (pre-v0.0.6).
- `lib/consult.sh:1157` line-number cite replaced with bare function name.
- Trigger-phrase examples added ("switch consult roster", "use only rex and cody").
- FAIL-verdict carve-out documented.
- Static-wiring test extended with 6 new asserts + 2 negative-asserts.
- Strict-dogfood: [ ]

## v0.18.1 — undated — medic Step D AskUserQuestion 4-option cap fix

- Flat 5-option menu for N=3 (`All three` + 3 pairs + `Customize`) was
  unimplementable.
- Rewritten as 2-step nested pattern (Step D.1 high-level: `All three` / `Pick
  a pair (drill in)` / `Customize…`; Step D.2 fires only when D.1 returns
  `Pick a pair`, drills with 3 pair options).
- N=2 menu unchanged.
- Static-wiring test asserts D.1/D.2 structure + negative-asserts legacy "5 options" prose.
- Strict-dogfood: [ ]

## v0.18.0 — 2026-05-08 — medic trooper-select

- `/clone-wars:medic` runs interactive Steps A–G after the health table.
- User picks active subset (preset N=2/3 menu or per-provider Customize walk for N=4).
- Selection persists in `$state_root/providers-active.txt`.
- `bin/consult-init.sh` prefers selection over `providers-available.txt`.
- New `cw_active_providers_path` resolver in `lib/state.sh` is single source
  of truth for precedence.
- `bin/medic.sh` unchanged (interactivity is Claude-side only).
- Strict-dogfood: [ ]

## v0.17.0 — 2026-05-08 — consult-spec merge

- `/clone-wars:consult` becomes single command from topic to deploy-audit-passing
  design doc.
- `/clone-wars:spec` deleted entirely (commands/spec.md, bin/spec-{init,assemble}.sh,
  lib/spec.sh, all tests/test_spec_*.sh).
- New `lib/consult-walk.sh` (4 helpers); `bin/consult-walk-assemble.sh`
  (concat `.draft/*.md` → final doc, runs `cw_deploy_audit_doc`, exits 1 with
  ISSUE= lines on FAIL).
- `bin/consult-init.sh` `--targets a,b,c` flag.
- `bin/consult-synthesize.sh` refactored to emit per-section seed drafts under `.draft/`.
- `commands/consult.md` renumbered to clean integers 0–16; new Steps 10
  (multi-repo auto-detect) + 11 (per-section Approve/Revise/Skip walk over
  6 single-repo or 8 multi-repo sections) + 12 (assemble + audit gate).
- Doc shape: Problem/Goal/Architecture/Components/Testing/Success Criteria
  (single) + Execution DAG / Cross-Repo Notes + per-repo subsections (multi).
- Partially reverses v0.14.0's hub-mode deletion (auto-detect + per-repo
  subsections + soft DAG restored; 282 LoC of validators stay deleted).
- Strict-dogfood: [ ]

## v0.16.0 — undated — consult unified smart-control

- Single entry point with `--use-force` flag.
- Escalation phrasing triggers ("deeply", "verify", "compare carefully", "second
  opinion", "consult thoroughly").
- Yoda fast-path with 4-signal complexity check (conflicting evidence /
  significant assumptions / high-stakes / subjective tradeoffs; any borderline
  signal escalates).
- Output unified at `_consult/design-doc/<date>-<slug>-design.md` (rigid 6
  sections: Summary / Findings / Tradeoffs / Recommendation / Open Questions /
  Sources).
- `/spec` source-defaulting collapses to single path.
- Drops `_consult/synthesis.md` (replaced by design-doc); breaking change for
  archived consult dirs without back-compat per v0.14 precedent.
- Strict-dogfood: [ ]

## v0.15.0 — undated — 3-trooper /consult

- opencode (DeepSeek V4 Pro) joins as `bly` (commander 327th).
- Topology A symmetric verify (every claim 2 independent verifiers).
- Medic-driven trooper enumeration via `$state_root/providers-available.txt`.
- Commander mapping locked: codex→rex, claude→cody, opencode→bly.
- N=1 plain-exits with redirect (use claude directly).
- N=2 unchanged (current 2-trooper mode preserved byte-equal).
- N=3 new mode with 5-tier adjudicate output (consensus / cross-verified /
  contested / refuted / pending); drill across 7 options including "all three
  (parallel)" K=2+K=1 fan-out.
- Strict-dogfood: [ ]

## v0.14.0 — undated — hub-mode removal

- `/consult` and `/spec` are single-context (invoked at the cwd to investigate);
  trooper inherits cwd via `tmux split-window -c` and reads CLAUDE.md/AGENTS.md.
- Deleted: `lib/consult-hub.sh`, `lib/consult-validators.sh`, 25 hub/validator
  test files (~530 LoC).
- Renamed: `cw_consult_design_doc_resume_state` → `cw_spec_resume_state` in
  new `lib/spec.sh`.
- `/clone-wars:deploy`'s `Target Sub-Project:` redirect preserved (separate mechanism).
- No back-compat: archived `_consult-<ts>/` dirs with `hub-mode.txt`/`targets.txt`
  silently ignored on v0.14.0.
- Strict-dogfood: [ ]

## v0.13.0 — 2026-05-07 — opencode trooper (DeepSeek V4 Pro)

- Tracer-bullet + medic preflight (rc-capture bash bug fixed).
- New row in `contracts.yaml`.
- `/clone-wars:deploy --provider` override.
- Closed-set 3 → 4 with generic OpenAI-compat still rejected.
- Strict-dogfood: [x] 2026-05-07 — `bin/spawn.sh rex opencode dogfood-13`
  cold-started DeepSeek V4 Pro in ~5s after 15s bootstrap floor; round-trip
  ready→done = ~1m49s; clean JSONL emission; medic preflight detected
  `permission: allow` correctly. Archive: `~/.clone-wars/archive/<repo-hash>/dogfood-13/rex-opencode-20260507T023020Z`.

## v0.12.0 — undated — `/consult` and `/spec` split

- `/consult` (research+synthesis+drill+teardown) + `/spec` (conductor-only
  design-doc walk that consumes a synthesis seed).
- `--design-doc` flag deprecated with `log_warn`.
- `bin/consult-design-doc.sh` renamed → `bin/spec-assemble.sh`.
- New Step 8.4 free-form drill-deeper before teardown (replaces old per-section
  drill in Step 8.5).
- Per-sub-project drill axis intentionally dropped (free-form via $DRILL_TOPIC).
- Strict-dogfood: [ ]

## v0.11.2 — undated — codex cold-start mitigation

- Consult Step 1 spawn-rollback runbook auto-retries-once before tearing down
  (fixes race where spawn.sh's identity-read nudge arrived before codex finished
  cold-starting node-modules + auth handshake).
- codex `bootstrap_sleep_s` bumped 8 → 20 in `config/contracts.yaml` as belt-and-braces.
- Warm-start happy path unaffected.

## v0.11.1 — undated — consult maintenance + hardening

- `lib/consult.sh` 3-way split + thin sourcing shim.
- `CW_SLUG_REGEX_BASE` shared constant.
- `cw_consult_extract_targets_from_topic` + `cw_consult_findings_active_subproject`.
- Drilldown collision counter.
- Validator order doc + acceptance-tests `log_warn`.
- Mode-toggle warn.
- Findings-conformance metric.
- Strict-dogfood: [ ]

## v0.11.0 — undated — consult hub-mode

- Target Hub(s) + Target Sub-Project(s) headers.
- Execution DAG, Cross-Repo Dependencies table, Step-tagged Acceptance Tests.
- `cw_consult_detect_hub` returns MODE/HUBS/LEAVES.
- 3 new validators (dag/xrepo-deps/acceptance-tests).
- Single-repo behavior byte-identical to v0.10.
- Strict-dogfood: [ ]

## v0.10.0 — undated — deploy sub-repo redirect

- `**Target Sub-Project:** <name>` header in design doc redirects trooper pane
  / branch / state / provider auto-detect into `<conductor-cwd>/<name>/`.
- Uses `git -C <sub-repo>` + `tmux split-window -c <sub-repo>` so conductor
  never `cd`s.
- Consult design-doc walk asks for the header in hub repos.
- Strict-dogfood: [ ]

## v0.9.0 — undated — deploy auto-detects trooper provider

- codex default; claude with confirmation when `.claude-plugin/plugin.json` present.
- `cw_deploy_detect_provider` helper + `auto_provider.txt`/`provider.txt` state files.
- Medic probe extended.
- Static-wiring test for the directive.
- Strict-dogfood: [ ]

## v0.8.0 — undated — deploy single-turn

- Plan + implement + verify run in one trooper turn per round.
- Auto-retry-once.
- `CW_DEPLOY_TURN_TIMEOUT=14400` default.
- 6 bin scripts and 4 lib helpers deleted.
- Strict-dogfood: [ ]

## v0.7.0 — undated — `/clone-wars:execute-design` → `/clone-wars:deploy`

- Rename `/clone-wars:execute-design` → `/clone-wars:deploy`.
- Hide internal slash commands (`spawn`/`send`/`collect`).
- User-facing surface: medic/consult/spec/deploy/list/teardown.
- Strict-dogfood: [ ]

## v0.6.1 — undated — drilldown scratch + execute-design polish

- Drilldown scratch subdir.
- Execute-design source-defaulting prefers design-doc.
- `CW_EXECUTE_FIX_TIMEOUT` env var.
- Parameterized wait-script test.

## v0.6.0 — undated — execute-design (codex-implements + yoda-verifies pipeline)

- New pipeline: codex implements; yoda verifies.

## v0.5.3 — undated — consult drill extract + JSONL safety

- Extract Step 8.5 drill code into `bin/consult-drilldown.sh` (escapes the
  slash-command renderer's `$1/$2/$3` positional substitution that clobbered
  bash function args on multi-word topics).
- Identity-template gains "safe JSONL emission" guidance (prevent `printf '%2C'`
  format-string failures observed in dogfood).

## v0.5.2 — undated — identity-template lookup tightening

- Remove `$CLONE_WARS_HOME/identity-template.md` from `cw_identity_write` lookup
  chain (stale per-machine overrides silently shadowed v0.5.x prompt-template updates).
- Lookup is now in-tree only (matches v0.5.0's "no overrides" decision).
- Medic warns when an orphan state-root copy is detected.

## v0.5.1 — undated — background-await string rename + identity-template foreground guidance

- Rename background-await `description=` strings to `master yoda await
  <rank-prefixed trooper> <phase>` form.
- Identity-template now tells troopers to run their own tool-use foreground
  (only Yoda backgrounds; troopers stay foreground in their own pane).

## v0.5.0 — undated — octogent-steals (prompt-template registry + stale state)

- Prompt-template registry.
- Stale-state detection.
- `cw_send --from` flag.
- Background-await pattern.

## v0.4.2 — undated — design-doc mode codex adversarial-review fixes

- Atomic write.
- Hash filename.
- Teardown order.
- Always-offer prompt.
- Drill-both.
- Token-flag parse.

## v0.4.1 — undated — design-doc mode header-extraction polish

- Title, goal, arch-line.

## v0.4.0 — undated — design-doc mode

- Opt-in brainstorming-style spec output (Step 8.5).

## v0.3.0 — undated — trooper question protocol + skill routing

- Trooper question protocol.
- Skill routing (brainstorming/systematic-debugging).

## v0.2.1 — undated — citation-overlap robustness + Master Yoda role rename

- Citation-overlap robustness.
- Master Yoda role rename.

## v0.2.0 — undated — split-orchestrator consult

- Master Yoda reachable between every step.

## v0.1.x — undated — dual-model consult command

- Cross-verified investigation.

## v0.0.x — early scaffolding and tracer validation

Pre-versioned development that predates the `v0.1.x` release line: design doc,
repo creation, marketplace shell, lib/ helpers, /clone-wars:medic, README,
tracer-bullet for codex, real implementations of spawn/send/collect/list/teardown
(landed in v0.0.6+). Full row-by-row history available in `git log`.
