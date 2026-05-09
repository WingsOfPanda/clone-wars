# Deploy Multi-Repo DAG — Design Doc (v0.20.0)

**Status:** approved 2026-05-09. Implementation pending.

## Problem

`/clone-wars:deploy` is single-trooper and single-repo. When `/clone-wars:consult`
produces a multi-repo design doc (with `**Target Sub-Project(s):**` header
+ `## Execution DAG` section), the user is currently routed to
`/executeorder66` (an ARS plugin command, not part of clone-wars) because
deploy can't dispatch across multiple repos.

This forces the user to context-switch to a different plugin for the
multi-repo case. It also leaves clone-wars without a first-class story
for the most common consult output shape (multi-repo specs are increasingly
the norm as users design across siblings).

Three additional issues, surfaced by the v0.19.1 review:

1. Deploy's "source defaulting" prose still references `--design-doc`
   (deprecated v0.12.0) and `_consult/synthesis.md` (removed v0.12.0).
   The `find` glob pattern only matches the modern `*-design.md` shape;
   the synthesis fallback is dead code that misleads fresh-Claude readers.
2. `cw_deploy_detect_provider` still considers opencode as a possible
   provider via the `--provider opencode` override. The user's policy is
   codex-only (with claude-on-plugin-dev as the sole exception). Opencode
   should be removed from the deploy provider surface entirely.
3. Multiple smaller polish items (frontmatter `allowed-tools` missing,
   trigger phrases absent, `description='...$ROUND...'` interpolation bug
   at line 257) — addressed inline as part of the same release.

## Goal

Add multi-repo DAG-aware deploy to `/clone-wars:deploy` while keeping the
single-repo path byte-equal to v0.19.0.

After v0.20.0 ships:

- A multi-repo consult design doc routes cleanly through deploy: spawn
  one codex trooper per sub-repo (deterministic commander assignment),
  walk the DAG by waves dispatching parallel troopers where the DAG
  allows, each trooper runs the full superpowers ceremony for its
  sub-repo, conductor does final cross-repo verification, fix-loops
  on a per-sub-repo basis with a hard cap.
- A single-repo design doc continues to work exactly as v0.19.0: one
  codex trooper, plan + implement + self-verify in one turn, no DAG
  ceremony.
- Deploy's prose drops all references to deprecated `--design-doc` flag
  and removed `_consult/synthesis.md` file.
- `--provider opencode` is rejected explicitly; `cw_deploy_detect_provider`
  returns codex or claude only.
- `/executeorder66` continues to work (separate plugin, separate repo);
  this spec does not deprecate it. Future v0.21+ may revisit.

## Architecture

```
[deploy entry point: bin/deploy-init.sh]
       │
       ▼
   parse args + audit design doc (cw_deploy_audit_doc)
       │
       ▼
   detect routing:
     - **Target Sub-Project(s):** plural + ## Execution DAG  → MULTI-REPO PATH
     - **Target Sub-Project:** singular OR no header         → SINGLE-REPO PATH (byte-equal v0.19.0)
       │                                                       │
       │ (multi-repo)                                          │ (single-repo)
       ▼                                                       ▼
  bin/deploy-dag-parse.sh                              [v0.19.0 flow unchanged]
   - parse soft-DAG prose into TSV
   - topological sort (Kahn) + wave grouping
   - write _deploy/dag-waves.txt
       │
       ▼
  bin/deploy-multi-init.sh
   - assign one commander per sub-repo from pool
   - write _deploy/troopers.txt (<commander>\t<cwd>\t<provider>)
       │
       ▼
  bin/preflight-layout.sh (reused from v0.19.0)
   - splits N panes off Yoda's pane
   - tmux select-layout main-vertical
   - writes _deploy/preflight-panes.txt
       │
       ▼
  DAG WAVE LOOP — for each wave in dag-waves.txt:
   - issue K parallel bin/spawn.sh --target-pane calls (K = wave size)
   - each spawn passes --cwd <sub-repo-path>
   - send DAG-unit prompt via inbox:
       "Read <design-doc>. Your sub-repo is <slug>. Run
        superpowers:writing-plans → subagent-driven-development →
        verification-before-completion. Report done via outbox."
   - wait for K done events (background-await pattern, mirrors consult)
   - if any FAIL: enter Stage 1 retry-once + Stage 2 partial-success
     (mirrors v0.19.0 consult Step 3b)
       │
       ▼
  CONDUCTOR FINAL VERIFICATION (Yoda)
   - default: cross-repo invariants only (interface contracts, schema compat)
   - escalate to full (tests + Success Criteria diff review) if any of:
       * cross-repo interface change detected (grep diffs for shared types)
       * multiple troopers touched same shared module path
       * DAG had 3+ wave levels (non-trivial dependencies)
       │
       ▼
  ON BUG → FIX-LOOP
   - send fix-prompt to trooper that owns the offending sub-repo
   - trooper still alive in its preflight pane; reuse same commander
   - MAX_FIX_ROUNDS=3 per DAG unit
   - at cap: AskUserQuestion → give up / continue / escalate to new commander
       │
       ▼
  TEARDOWN + ARCHIVE (mirrors consult-teardown.sh)
```

The single-repo path is unchanged from v0.19.0. The auto-detect branch
in `bin/deploy-init.sh` is the only modification to existing code on
that path.

## Components

### NEW `bin/deploy-dag-parse.sh`

Signature: `deploy-dag-parse.sh <design-doc-path> <out-dir>` (rc=0 on
success, rc≠0 on failure).

Behavior:

1. Read the design doc; extract the `## Execution DAG` section
   (everything between `## Execution DAG` and the next `^## ` heading).
2. Parse the soft-DAG prose lines. The format is the output of
   `cw_consult_emit_soft_dag` (in `lib/consult-walk.sh`):

   ```
   1. <repo-slug> — <description>
   2. <repo-slug> — <description> (depends on 1)
   3. <repo-slug> — <description> (depends on 1, 2)
   ```

   Regex: `^([0-9]+)\.\s+([a-z0-9-]+)\s+—\s+(.+?)(?:\s+\(depends on ([0-9, ]+)\))?\s*$`

3. Build the dependency graph; run Kahn's topological sort to detect
   cycles (rc=1 on cycle: `log_error "DAG has cycle: <cycle-hint>"`).
4. Group nodes into "waves" by topological level: wave 1 = all nodes
   with no incoming dependencies; wave 2 = all nodes whose dependencies
   are in wave 1; etc.
5. Write `<out-dir>/dag-waves.txt` (TSV `<wave-num>\t<step-num>\t<repo-slug>\t<description>` per line).
6. Write `<out-dir>/dag-edges.txt` (TSV `<from-step>\t<to-step>` per line)
   for downstream tools (final-verification's "shared module" check).

### NEW `lib/deploy-dag.sh`

Sourcing-only file. Helpers used by `bin/deploy-dag-parse.sh` and the
final-verification logic in `commands/deploy.md`:

- `cw_deploy_dag_parse_line <line>` — accepts one prose line, echoes
  TSV `<step>\t<repo>\t<desc>\t<deps-csv|none>` or rc=1 + log_error on
  malformed line.
- `cw_deploy_dag_topological <edges-tsv>` — runs Kahn; echoes
  `<wave-num>\t<step-num>` per line; rc=1 on cycle.
- `cw_deploy_dag_unique_repos <waves-tsv>` — echoes the unique sorted
  list of repo slugs across all waves (one per line).
- `cw_deploy_dag_fan_in_repos <edges-tsv>` — DAG-topology heuristic
  for the final-verification "feels unsafe" signal; echoes the list
  of repo slugs that have 2+ incoming dependencies (fan-in nodes). A
  repo with multiple upstream dependencies is more likely to be
  affected by interactions between earlier waves; signals "needs
  closer review."

The conductor's "feels unsafe" judgment in the directive layers three
checks on top of these helpers (each one a distinct trigger):

1. **Topology**: any wave count ≥ 3 OR any repo with `fan_in ≥ 2`
2. **Shared filesystem path**: grep across sub-repo diffs for any
   path that appears in 2+ troopers' commits (using `git -C <cwd>
   diff --name-only $BRANCH_BASE..HEAD` per sub-repo, then comparing)
3. **Cross-repo interface change**: heuristic grep for shared types
   / function signatures (e.g., a struct definition added in repo A
   and referenced in repo B's diff)

Any one trigger → escalate from cross-repo-invariants-only to full
verification (run all sub-repo tests + Success Criteria diff review).

### NEW `bin/deploy-multi-init.sh`

Signature: `deploy-multi-init.sh <design-doc-path> <topic>`.

Behavior:

1. Read `_deploy/dag-waves.txt`, derive unique repo list.
2. For each repo (in DAG order — wave 1 first, then wave 2, etc.),
   resolve sub-repo path: `${CONDUCTOR_CWD}/<repo-slug>` (mirrors
   `cw_consult_detect_multi_repo` semantics). Verify path exists +
   has a `CLAUDE.md` or `AGENTS.md` (treat absence as fatal — design
   doc references a sibling that doesn't exist).
3. Assign one commander per repo from the clone trooper pool
   (`config/commanders.yaml`). Assignment is deterministic: pool
   order × repo DAG order. First repo gets pool[0] (rex), second
   gets pool[1] (cody — but wait, cody is reserved for claude-on-plugin
   case; skip cody for codex assignments). Skip-list: `cody` (reserved
   for claude trooper). Final commander pool for codex troopers:
   rex, wolffe, bly, fox, gree, ponds, bacara, neyo, doom, faie,
   hunter, wrecker, tech, crosshair, echo, fives, jesse, kix, tup,
   dogma, hardcase, thorn, thire, stone, bow.
4. Write `_deploy/troopers.txt` TSV (`<commander>\t<sub-repo-cwd>\t<provider>`)
   one line per repo. Provider is `codex` for all entries (deploy v0.20.0
   is codex-only for multi-repo; the claude-on-plugin-dev exception
   only applies when the sub-repo IS itself a Claude plugin — call
   `cw_deploy_detect_provider <sub-repo-cwd>` per repo and use its
   return value).
5. Print the assignment table to stdout for the conductor to log.

### MODIFIED `bin/deploy-init.sh`

Two changes:

1. **Drop `--design-doc` and `synthesis.md` references entirely.**
   The find-glob block becomes:

   ```bash
   # v0.20.0: only consult's modern audit-passing design-doc shape.
   # Drops pre-v0.12 --design-doc + synthesis.md fallback (gone since v0.12).
   find "$STATE_ROOT" -path '*/_consult/design-doc/*-design.md' -print0 2>/dev/null \
     | sort -rz | head -z -n 1
   ```

2. **Auto-detect routing.** After audit passes, branch:

   ```bash
   # Auto-detect single vs multi-repo from header form.
   if grep -qE '^\*\*Target Sub-Project\(s\):\*\*' "$DESIGN_DOC" \
      && grep -qE '^## Execution DAG\b' "$DESIGN_DOC"; then
     ROUTING=multi-repo
     "$PLUGIN_ROOT/bin/deploy-dag-parse.sh" "$DESIGN_DOC" "$ART_DIR" || exit 1
     "$PLUGIN_ROOT/bin/deploy-multi-init.sh" "$DESIGN_DOC" "$TOPIC"  || exit 1
   else
     ROUTING=single-repo
     # (existing single-repo init flow continues unchanged from v0.19.0)
   fi
   echo "$ROUTING" > "$ART_DIR/routing.txt"
   ```

   The `routing.txt` file is the conductor's read-only signal for which
   path the rest of the directive should follow.

### MODIFIED `lib/deploy.sh`

`cw_deploy_detect_provider` drops the opencode case entirely:

```bash
cw_deploy_detect_provider() {
  local cwd="${1:-$PWD}" override="${2:-}"
  if [[ -n "$override" ]]; then
    case "$override" in
      codex|claude) printf '%s\n' "$override"; return 0 ;;
      opencode) log_error "deploy: opencode is not a supported provider in v0.20.0+; use codex (default) or claude (plugin-dev)"; return 1 ;;
      *) log_error "deploy: unknown provider override '$override'"; return 1 ;;
    esac
  fi
  # Auto-detect: claude on plugin repos, codex everywhere else.
  if [[ -f "$cwd/.claude-plugin/plugin.json" ]]; then
    printf 'claude\n'
  else
    printf 'codex\n'
  fi
}
```

### MODIFIED `commands/deploy.md`

Substantial rewrite of the directive prose. Key changes:

1. **Frontmatter additions:** `allowed-tools: Bash, Write, Read, Edit, AskUserQuestion`. `argument-hint` advertises all flags including `--provider codex|claude`.
2. **Trigger phrases section** at top: "deploy this design", "implement the spec at <path>", "ship <design-path>", "execute the design-doc", "spawn troopers for <design>".
3. **Source-defaulting section rewritten** to drop `--design-doc` and `synthesis.md`. New shape: "Find the most recent `state/<repo-hash>/<topic>/_consult/design-doc/<YYYY-MM-DD>-<slug>-design.md` (consult's audit-passing output as of v0.17.0). If none found, refuse with a usage hint."
4. **Routing branch.** After deploy-init.sh runs, conductor reads `_deploy/routing.txt`; if `single-repo`, runs today's flow (v0.19.0 byte-equal); if `multi-repo`, runs the new flow described below.
5. **NEW Step 3a (multi-repo)**: Preflight via `bin/preflight-layout.sh` (reused from v0.19.0; same `_deploy/preflight-panes.txt` shape). Read `_deploy/troopers.txt` to populate the `PREFLIGHT_PANES` associative array.
6. **NEW Step 3b (multi-repo)**: DAG wave loop. For each line in `dag-waves.txt`, group by `<wave-num>`; for each wave, issue K parallel `bin/spawn.sh --target-pane "${PREFLIGHT_PANES[$cmdr]}" --cwd "<sub-repo-cwd>"` calls. Send DAG-unit prompt via inbox.

   **DAG-unit prompt shape** (verbatim text the conductor writes to each trooper's inbox.md):

   ```
   Read <abs-path-to-design-doc>. Your sub-repo is "<slug>".

   Multi-repo design docs use `### <slug>` subsection headings inside
   the Architecture and Components sections — focus on the subsections
   matching your slug. The DAG context (Step <N> of <total>) is in the
   "## Execution DAG" section; you depend on: <upstream-slug-list>.

   Run the full superpowers ceremony for your sub-repo:
   1. superpowers:writing-plans — produce an implementation plan from
      the design doc's slice for "<slug>", saved to
      docs/superpowers/plans/YYYY-MM-DD-<topic>-<slug>-plan.md
   2. superpowers:subagent-driven-development — execute the plan
      task-by-task, two-stage review per task
   3. superpowers:verification-before-completion — confirm tests pass,
      diff matches the plan, no half-finished work, before reporting done

   Report status via outbox: emit {"event":"done"} when all tasks are
   complete and verified. Emit {"event":"error", "reason":"..."} on
   any unrecoverable failure.
   END_OF_INSTRUCTION
   ```

   Background-await for K done events.
7. **NEW Step 4 (multi-repo)**: Conductor's final verification. Run `cw_deploy_dag_shared_modules` to detect "feels unsafe" signal. Default → cross-repo invariants only. Escalate → run `bash tests/run.sh` (or equivalent per-repo) + diff-review against Success Criteria.
8. **NEW Step 5 (multi-repo)**: Fix-loop. On bug, send fix-prompt to the offending sub-repo's trooper. MAX_FIX_ROUNDS=3 per DAG unit. AskUserQuestion at cap.
9. **`description='...$ROUND...'` interpolation bug at v0.19.0 line 257**: fix to double quotes (`description="..."`) — already pre-existing bug surfaced in v0.19.1 review.

### MODIFIED `bin/deploy-teardown.sh` + `bin/deploy-archive.sh`

Extend to handle multi-repo case (multiple troopers, multiple panes,
preflight-orphan cleanup mirroring `bin/consult-teardown.sh` v0.19.0
extension). Single-repo path unchanged.

## Data flow

| File | Writer | Readers | Lifetime |
|---|---|---|---|
| `_deploy/routing.txt` | `bin/deploy-init.sh` | conductor (deploy.md routing branch) | full deploy |
| `_deploy/dag-waves.txt` | `bin/deploy-dag-parse.sh` | conductor (Step 3b wave loop), final-verification | multi-repo only |
| `_deploy/dag-edges.txt` | `bin/deploy-dag-parse.sh` | `cw_deploy_dag_shared_modules` | multi-repo only |
| `_deploy/troopers.txt` | `bin/deploy-multi-init.sh` | preflight-layout, conductor, deploy-teardown | multi-repo only |
| `_deploy/preflight-panes.txt` | `bin/preflight-layout.sh` (reused) | conductor Step 3b dispatch, deploy-teardown orphan cleanup | multi-repo only |
| `<topic>/.last_pane` | `bin/spawn.sh` legacy path | unchanged from v0.19.0 | single-repo only |

## Backwards compatibility

- **Single-repo deploy**: byte-equal to v0.19.0. Auto-detect routing
  branch falls through to the existing code path when no `**Target
  Sub-Project(s):**` header is present.
- **`bin/spawn.sh`**: unchanged from v0.19.0. The new multi-repo path
  uses `--target-pane` (added v0.19.0 for consult, additive); the
  single-repo deploy path doesn't use `--target-pane`.
- **`bin/preflight-layout.sh`**: reused as-is from v0.19.0. Reads
  `_deploy/troopers.txt` instead of `_consult/troopers.txt` — the
  script accepts the path-prefix as part of its `<topic>` argument,
  so this is a caller-side change only (no preflight-layout.sh edit).
  Wait — preflight-layout.sh today uses `cw_consult_art_dir` to resolve
  the troopers path. **Refactor**: extract a path-prefix into a small
  helper or pass an explicit `<art-dir>` arg. See "Implementation
  outline" Task 4.
- **`/clone-wars:deploy <single-repo-design-doc>`**: behavior unchanged.
  Existing tests (`test_deploy_*.sh`, `test_spawn_validation.sh`,
  `test_spawn_rollback.sh`) continue to pass without modification.
- **opencode in deploy**: REMOVED. `--provider opencode` is now
  rejected with a clear error message. This is a tiny breaking change
  documented in CLAUDE.md status entry. /clone-wars:consult continues
  to support opencode (separate roster mechanism via medic).
- **Pre-v0.20 archived deploys**: silently ignored. `_deploy/routing.txt`
  absence is treated as single-repo (back-compat default).

## Failure modes

| Stage | Failure | Behavior |
|---|---|---|
| Deploy-init | design doc audit FAIL | Print `ISSUE=` lines + exit 1 (existing v0.19.0 behavior) |
| Deploy-init | `--provider opencode` | Reject with clear error message + usage hint |
| DAG parse | `## Execution DAG` section absent on multi-repo doc | rc=1 with `log_error "multi-repo design doc missing ## Execution DAG section"` |
| DAG parse | malformed soft-DAG prose line | rc=1 with `log_error "DAG line malformed: <line>"` |
| DAG parse | cycle detected | rc=1 with `log_error "DAG has cycle: <cycle-hint>"` (Kahn's algorithm naturally exposes this) |
| Multi-init | sub-repo path missing or no CLAUDE.md/AGENTS.md | rc=1 with `log_error "sub-repo <slug> not found at <path>"` |
| Multi-init | commander pool exhausted (>25 sub-repos) | rc=1 (extreme edge case; not expected in practice) |
| Preflight | tmux split fails | Trap-driven rollback (existing v0.19.0 behavior) |
| Spawn (multi) | any of K parallel spawns fails AND `SPAWN_RETRY_COUNT == 0` | Stage 1 retry-once: full teardown + re-preflight + re-dispatch |
| Spawn (multi) | retry also fails | Stage 2 partial-success AskUserQuestion: proceed degraded with K-1 / abort all |
| Trooper turn | trooper TS=failed or TS=timeout (per DAG unit) | Treated as wave-level failure; same Stage 1/Stage 2 handling |
| Final verify | conductor detects bug | Send fix-prompt to offending sub-repo's trooper; increment fix-round counter |
| Fix-loop | MAX_FIX_ROUNDS=3 reached | AskUserQuestion: give up / continue / escalate to new commander |
| Fix-loop "give up" | user picks give up | Mark sub-repo as FAILED in `_deploy/results.txt`; continue final-verification on remaining sub-repos; report failures at end |
| Fix-loop "escalate" | user picks new commander | Spawn new codex trooper with same `--cwd`, different commander name; reset fix-round counter for that DAG unit |

## Testing

### Unit tests (no tmux required)

1. **`tests/test_deploy_dag_parse_line.sh`** — `cw_deploy_dag_parse_line`
   handles: simple line ("1. foo — desc"), with deps ("2. bar — desc (depends on 1)"),
   with multi-deps ("3. baz — desc (depends on 1, 2)"), malformed lines (missing
   step number, missing repo, malformed deps).

2. **`tests/test_deploy_dag_topological.sh`** — `cw_deploy_dag_topological`
   handles: linear chain (1→2→3), parallel wave (1, 2, 3 with no deps),
   diamond (1, 2→1, 3→1, 4→2,3), cycle detection (1→2→1).

3. **`tests/test_deploy_dag_parse.sh`** — `bin/deploy-dag-parse.sh`
   end-to-end on synthetic design docs covering: 3-repo linear, 3-repo
   diamond, missing DAG section (rc=1), malformed DAG line (rc=1).

4. **`tests/test_deploy_multi_init.sh`** — commander assignment is
   deterministic given the same DAG order, skips `cody` from the codex
   pool, calls `cw_deploy_detect_provider` per sub-repo to honor
   plugin-dev exception.

5. **`tests/test_deploy_provider_no_opencode.sh`** — `cw_deploy_detect_provider`
   with `--provider opencode` returns rc≠0 + clear error message.

6. **`tests/test_deploy_init_routing_autodetect.sh`** — given a
   single-repo design doc, `routing.txt` says `single-repo`; given a
   multi-repo doc, says `multi-repo`. Single-repo path doesn't invoke
   deploy-dag-parse.sh / deploy-multi-init.sh.

### Tmux-dependent tests

7. **`tests/test_deploy_multi_preflight.sh`** — uses the same
   isolated-test-window scaffolding as `tests/test_preflight_layout.sh`
   (v0.19.0). Verifies multi-repo deploy preflight allocates K panes
   (K=3 happy path) and writes `_deploy/preflight-panes.txt` with
   commander order matching DAG order.

### Static-wiring test

8. **`tests/test_deploy_directive_v020_static_wiring.sh`** — asserts
   `commands/deploy.md` contains: `routing.txt` reference, `bin/deploy-dag-parse.sh`
   reference, `bin/deploy-multi-init.sh` reference, "Step 3a" and "Step 3b"
   for multi-repo case, MAX_FIX_ROUNDS=3 wording, AskUserQuestion at-cap
   wording, trigger-phrase examples, allowed-tools frontmatter line,
   no `--design-doc` references, no `synthesis.md` references.

### Regression tests

9. All v0.19.0 tests must continue to pass without modification:
   `test_pane_respawn.sh`, `test_preflight_layout.sh`,
   `test_preflight_layout_rollback.sh`, `test_spawn_target_pane_strict.sh`,
   `test_consult_teardown_preflight_orphans.sh`,
   `test_consult_directive_v019_static_wiring.sh`,
   `test_consult_directive_v017_static_wiring.sh`,
   `test_spawn_validation.sh`, `test_spawn_rollback.sh`,
   `test_medic_directive_v018_static_wiring.sh`,
   `test_active_providers_path.sh`, all `test_consult_init_*.sh`,
   all existing `test_deploy_*.sh` (single-repo path tests).

## Success criteria

- [ ] A multi-repo consult design doc (`**Target Sub-Project(s):**` header
  + `## Execution DAG` section) feeds cleanly into `/clone-wars:deploy`
  without manual intervention. K codex troopers spawn, each in its own
  sub-repo cwd, all in evenly-sized panes via main-vertical.
- [ ] DAG waves execute in topological order: wave 2 doesn't start until
  all wave 1 troopers report done.
- [ ] Within a wave, troopers run in parallel (multiple codex sessions
  active concurrently).
- [ ] Each codex trooper invokes superpowers:writing-plans →
  subagent-driven-development → verification-before-completion on its
  sub-repo's design-doc slice.
- [ ] Conductor's final verification runs cross-repo-invariants by
  default; escalates to full check when "feels unsafe" signal fires.
- [ ] Fix-loop sends fix-prompts to the trooper that owns the offending
  sub-repo; honors MAX_FIX_ROUNDS=3 cap with AskUserQuestion.
- [ ] Single-repo design doc (no `**Target Sub-Project(s):**` header)
  takes the v0.19.0 code path byte-equal — same trooper, same single-turn
  flow, same archive shape.
- [ ] `--provider opencode` is rejected with a clear error message.
- [ ] All v0.19.0 tests pass without modification.
- [ ] Eight new v0.20.0 tests pass (one static-wiring + seven functional).

## Out of scope

- **Worktree isolation per trooper.** Multi-repo deploy uses `--cwd`
  to pin troopers to sibling sub-repos (already-existing dirs). True
  worktree isolation is still rejected per `docs/DESIGN.md`.
- **`/executeorder66` deprecation.** Future revisit; for v0.20.0 the
  two commands coexist.
- **Per-task trooper spawning.** User explicitly chose "one trooper per
  sub-repo, NOT one trooper per task." Each trooper does its own task
  decomposition internally via subagent-driven-development.
- **Custom DAG geometry.** The wave-based execution is the only model;
  no fan-out/fan-in optimizations beyond what topological wave-grouping
  already provides.
- **Trooper auto-resurrection.** If a trooper dies between DAG waves
  (e.g., user kills its pane), behavior is undefined — user must
  intervene (kill all + restart). v0.21+ may add resurrection.
- **Conductor's "feels unsafe" heuristic tuning.** Initial heuristics
  are: (1) cross-repo interface change (grep diffs for shared types/
  function signatures); (2) multiple troopers touched same shared module
  path; (3) DAG had 3+ wave levels. Heuristic tuning per real dogfood
  feedback is v0.21+.
- **Multi-repo `/clone-wars:deploy` for non-codex providers.** v0.20.0
  is codex-only for multi-repo (with cody=claude exception only when
  the sub-repo IS itself a Claude plugin). Future opencode/multi-repo
  is rejected per current scope.

## Versioning

- Plugin version: 0.19.0 → **0.20.0** (minor bump)
  - Additive: multi-repo path is purely new code on a new auto-detect
    branch; single-repo path is byte-equal.
  - Tiny breaking change: `--provider opencode` now rejected (was
    accepted as override in v0.19.0).
- Spec doc: `docs/superpowers/specs/2026-05-09-deploy-multi-repo-dag-design.md`
- CLAUDE.md status: add v0.20.0 row + strict-dogfood release gate
  (verify: (1) 3-sub-repo multi-repo deploy walks DAG correctly with
  parallel waves; (2) each trooper invokes superpowers ceremony on its
  sub-repo; (3) cross-repo final-verify default doesn't false-positive;
  (4) fix-loop cap surfaces AskUserQuestion; (5) `--provider opencode`
  rejected; (6) single-repo deploy unchanged from v0.19.0)

## Implementation outline (for writing-plans skill)

Approximate task breakdown — the writing-plans skill produces the
authoritative TDD plan:

1. New `lib/deploy-dag.sh` helpers: `cw_deploy_dag_parse_line`,
   `cw_deploy_dag_topological`, `cw_deploy_dag_unique_repos`,
   `cw_deploy_dag_fan_in_repos` + unit tests
2. New `bin/deploy-dag-parse.sh` (uses lib helpers) + e2e tests
3. New `bin/deploy-multi-init.sh` (commander assignment + per-repo
   provider detect) + tests
4. Generalize `bin/preflight-layout.sh` to accept either consult or
   deploy art dir (small refactor: replace `cw_consult_art_dir` call
   with a parameterized `<art-dir>` argument; update consult callers)
5. Drop opencode from `cw_deploy_detect_provider` + test
6. Update `bin/deploy-init.sh`: drop `--design-doc` / `synthesis.md`
   refs, add auto-detect routing branch + `routing.txt` write
7. Rewrite `commands/deploy.md`: frontmatter + trigger phrases +
   source-defaulting cleanup + routing branch + multi-repo Steps 3a/3b/4/5
8. Fix `description='...'` → `description="..."` interpolation bug
   in `commands/deploy.md`
9. Extend `bin/deploy-teardown.sh` + `bin/deploy-archive.sh` for
   multi-repo (mirror v0.19.0 consult-teardown orphan-cleanup)
10. Static-wiring test for the new directive prose
11. Plugin version bump 0.19.0 → 0.20.0; CLAUDE.md status entry +
    dogfood gate
