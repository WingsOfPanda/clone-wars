# /clone-wars:deploy — git-repo discipline (v0.42.0)

**Status:** Locked 2026-05-17. Implementation plan to follow under
`docs/superpowers/plans/`.

**Predecessors:**
- v0.30.0 — deploy correctness (rc=7 dirty-tree intercept, sibling
  baseline helpers).
- v0.20.x — multi-repo (hub) deploys, `troopers.txt`, per-repo
  `<cmdr>-branch-base.sha`.
- v0.31.0 — project-local state relocation (state under
  `<cwd>/.clone-wars/`).

## Goal

Eliminate the "which branch / which repo is this deploy writing to?"
confusion by laying a single, simple rule: **`/clone-wars:deploy` operates
on the conductor's current branch in each affected repo.** No
auto-branch, no `git checkout`. Wrap the deploy with deterministic
pre/post-deploy commits per target repo and end with a per-repo summary
block.

The contract holds identically for single-repo and hub-mode (multi-repo)
deploys. Hub-mode awareness is built into the iteration helper, not
duplicated in the ceremony.

## Architecture / contract

A single `/clone-wars:deploy <design-doc>` invocation operates on **N
target repos**: N=1 for single-repo, N≥1 for hub mode (one row per
`troopers.txt` entry). For each target:

1. **Branch is whatever HEAD points at when deploy starts.** No
   `git checkout`, no `git switch`, no `git checkout -b`. The user's
   current branch is the canvas. Trooper prompts forbid branch
   switching at instruction level (honor-system; verified post-hoc by
   the summary).
2. **Pre-deploy snapshot.** If the working tree has WIP, the conductor
   commits it as `chore: WIP before deploy <topic>` before any trooper
   spawns. Captures the resulting SHA as the per-repo baseline.
3. **Trooper work.** Per-task commits (already implemented — see
   `cw_deploy_build_turn_prompt_round1`'s "Commit per task" stanza).
   Trooper prompts gain a "do not switch branches" stanza.
4. **Post-deploy sweep.** If any target has uncommitted changes after
   troopers finish, the conductor commits them as
   `chore: post-deploy leftovers for <topic>`. Catches troopers that
   wrote files but didn't commit, or hook-deferred work.
5. **Per-repo summary block.** One block per target showing baseline-SHA
   → current-HEAD diff, listing branch (and flagging if branch changed
   despite the rule).

The legacy `feat/deploy-<topic>` auto-branch behavior is preserved as
**opt-in via `--branch [name]`** for users who explicitly want a sandbox
branch. The pre/post commit ceremony still applies in opt-in mode.

## Components

### Library helpers (lib/deploy.sh)

#### `cw_deploy_iter_targets <topic>`

Single source of truth for "which repos does this deploy touch?". Emits
TSV `<slug>\t<cwd>` rows. Hub mode reads `troopers.txt`; single-repo
synthesizes one row from `target_cwd.txt`.

```bash
cw_deploy_iter_targets() {
  local art
  art="$(cw_deploy_art_dir "$1")"
  if [[ -f "$art/troopers.txt" ]]; then
    # hub mode: <cmdr>\t<cwd>\t<provider> → use cmdr slug as the row id
    awk -F'\t' '{print $1"\t"$2}' "$art/troopers.txt"
  else
    # single-repo: synthesize one row with slug 'main'
    printf 'main\t%s\n' "$(cat "$art/target_cwd.txt")"
  fi
}
```

The slug `main` for the single-repo case is a stable label for summary
blocks; it does not refer to a git branch.

#### `cw_deploy_pre_snapshot <target-cwd> <topic> <slug> <baseline-file>`

Runs the pre-deploy ceremony for one target. Writes a TSV baseline file
the post-deploy phase reads later.

Behavior:
- Resolve current branch via `git -C <cwd> symbolic-ref --short HEAD`;
  on detached HEAD, record literal `(detached)`.
- Probe dirty state via `git -C <cwd> status --porcelain` (single
  command catches both modifications and untracked).
- If dirty: `git -C <cwd> add -A && git -C <cwd> commit -m "chore: WIP
  before deploy <topic>"`. On non-zero rc (hook block, signing
  failure, etc.), log warning, record `state=hook-blocked` in the
  baseline file, capture pre-attempt HEAD as the SHA, proceed.
- Capture resulting HEAD via `git -C <cwd> rev-parse HEAD`.
- Atomic-write `<baseline-file>` (via `cw_atomic_write`):

  ```
  slug=<slug>
  cwd=<absolute-cwd>
  branch=<branch-or-(detached)>
  baseline_sha=<sha>
  state=<clean|wip-committed|hook-blocked>
  snapshot_ts=<iso-8601-utc>
  ```

- Abort the entire deploy (rc=2) only when `<cwd>` is not a git repo —
  this is a setup bug, not a runtime warning.

#### `cw_deploy_post_sweep <baseline-file> <topic>`

Mirror of `_pre_snapshot`. Reads the baseline file, then:

- If working tree dirty: `git -C <cwd> add -A && commit -m "chore:
  post-deploy leftovers for <topic>"`. On hook block, log warning,
  record outcome in an emitted `post-<slug>.tsv` next to the baseline.
- Capture post-HEAD SHA and current branch.
- Compute `branch_changed = (baseline.branch != current.branch)`.
- Atomic-write `post-<slug>.tsv`:

  ```
  slug=<slug>
  cwd=<absolute-cwd>
  branch=<post-branch>
  post_sha=<sha>
  state=<no-leftovers|swept|sweep-failed>
  branch_changed=<true|false>
  sweep_ts=<iso-8601-utc>
  ```

#### `cw_deploy_format_summary_block <baseline-file> <post-file>`

Pure formatting helper — reads both TSVs and prints the per-repo block
defined in the "Summary output" section. No git calls inside; takes the
captured state as input so it's unit-testable.

### Trooper prompt stanza

Append to each of the three prompt builders in `lib/deploy.sh`:

- `cw_deploy_build_turn_prompt_round1` (single-repo round-1)
- `cw_deploy_build_turn_prompt_fix` (single-repo fix rounds)
- `cw_deploy_build_dag_unit_prompt` (multi-repo per-sub-repo prompt)

The appended stanza, with `<branch>` and `<cwd>` interpolated from the
matching baseline-file at dispatch time:

```
BRANCH DISCIPLINE (hard rule):
- You are on branch '<branch>' in '<cwd>'.
- Do NOT run `git checkout`, `git switch`, `git branch -m`, or create
  new branches.
- Commit per task with Conventional Commits prefixes on the current
  branch.
- If your work genuinely needs a fresh branch, abort with
  {"event":"error","reason":"branch-discipline: needed new branch"}
  and let the conductor decide.
```

Instruction-only. The summary detects violations and surfaces them as
WARNING lines; the deploy still completes.

### CLI surface (bin/)

#### `bin/deploy-pre-snapshot.sh <topic>`

Walks `cw_deploy_iter_targets <topic>` and invokes `cw_deploy_pre_snapshot`
per row. Writes baselines uniformly under `$ART_DIR/baselines/<slug>.tsv`
for both single-repo and hub mode (single-repo writes
`baselines/main.tsv`, matching `iter_targets`'s synthesized slug). One
thin script so the directive can call it as one Bash block.

#### `bin/deploy-summary.sh <topic>`

Walks `cw_deploy_iter_targets <topic>` and per row:
1. Calls `cw_deploy_post_sweep` (writes the post-TSV).
2. Calls `cw_deploy_format_summary_block` and prints to stdout.

Exits 0 unless a per-repo step itself errors fatally (e.g. baseline file
missing for a known target — symptom of a directive bug, not a runtime
warning).

### Directive changes (commands/deploy.md)

- **Step 0 sub-step 5 (init invocation)**: when `--branch` is NOT in
  args, pass `--no-branch` to `bin/deploy-init.sh`. Default invocation
  no longer creates `feat/deploy-<topic>`.
- **Step 0 sub-step 5a (dirty-tree intercept)**: removed. Replaced by
  the unconditional pre-snapshot call below.
- **NEW Step 0 sub-step 6 — pre-deploy snapshot**: after init succeeds
  (single-repo or multi-repo), invoke `bin/deploy-pre-snapshot.sh
  $TOPIC`. Log one line summarizing how many targets got committed vs
  clean. Always proceeds regardless of per-target hook failures.
- **Step 4 (teardown + archive)**: BEFORE the archive call, invoke
  `bin/deploy-summary.sh $TOPIC`. Pipe to chat verbatim — this is the
  per-repo summary block. THEN archive.

### Removed surface

- `bin/deploy-init.sh` rc=7 (dirty-tree refusal) — kept only for the
  opt-in `--branch` path. Default path no longer exits 7.
- `commands/deploy.md` sub-step 5a AskUserQuestion (Stash / Commit /
  Abort) — removed.
- The stash machinery (`pre-deploy-stash.txt` artifact, Step 4 stash-pop
  logic if any) — removed. Stash semantics drop from the supported set.

## Data flow

```
/clone-wars:deploy <doc>
    │
    ├─ Step 0.5: deploy-init.sh --no-branch (default) | --branch (opt-in)
    │     • writes target_cwd.txt OR troopers.txt
    │     • does NOT touch git in default mode
    │
    ├─ Step 0.6: deploy-pre-snapshot.sh $TOPIC      ← NEW
    │     • iter_targets → for each row:
    │         pre_snapshot → baselines/<slug>.tsv
    │
    ├─ Steps 1–3 / 3a–3d: trooper turns (unchanged)
    │     • dispatch prompts now carry BRANCH DISCIPLINE stanza
    │     • troopers commit per task on the current branch
    │
    ├─ Step 4 (pre-archive): deploy-summary.sh $TOPIC ← NEW
    │     • iter_targets → for each row:
    │         post_sweep → post-<slug>.tsv
    │         format_summary_block → stdout
    │
    └─ Step 4: deploy-archive.sh (unchanged)
```

## Summary output

One block per target. Hub-mode prints N blocks back-to-back, ordered by
the row order in `troopers.txt` (DAG wave order). Single-repo prints one
block labeled `main`.

```
═══ <slug> [<cwd>] ═══
  branch:     <post-branch>
  baseline:   <baseline-sha>   <baseline-branch>   (<state>)
  HEAD:       <post-sha>       <post-branch>
  diff stat:  N files changed, M+ insertions, K- deletions
  commits (oldest → newest):
    abc123   feat(<scope>): <subject>
    def456   test(<scope>): <subject>
    789abc   chore: post-deploy leftovers for <topic>          ← only if sweep committed
```

WARNING lines append above the `branch:` field when present:

- `[WARNING: branch changed from <baseline-branch> to <post-branch>]`
  → trooper violated branch discipline.
- `[WARNING: pre-deploy snapshot hook-blocked; baseline = pre-attempt
  HEAD]` → user's pre-commit hooks blocked the WIP snapshot.
- `[WARNING: post-deploy sweep hook-blocked; leftovers remain in
  working tree]` → sweep commit failed; uncommitted files remain.
- `[WARNING: baseline branch detached]` → conductor started on detached
  HEAD; diff range may be ambiguous.

`diff stat` line is the `git diff --shortstat <baseline>..HEAD` output,
trimmed of leading whitespace. `commits` section is
`git log --reverse --oneline <baseline>..HEAD`; prints
`(no commits since baseline)` when empty.

## Error handling / failure modes

| Condition | Behavior |
|---|---|
| Pre-snapshot: commit hook blocks | Warn, baseline.state=hook-blocked, baseline.sha = pre-attempt HEAD, proceed |
| Pre-snapshot: target is not a git repo | Abort deploy (rc=2) with explicit error naming the target slug |
| Pre-snapshot: detached HEAD | Warn, baseline.branch=`(detached)`, proceed |
| Pre-snapshot: nothing to stage (clean tree) | No commit, baseline.state=clean, normal path |
| Trooper switches branch despite stanza | Detected by post-sweep (branch_changed=true) → WARNING in block, deploy completes |
| Post-sweep: commit hook blocks | Warn, post.state=sweep-failed, deploy completes |
| Post-sweep: nothing to sweep | post.state=no-leftovers, normal path |
| Post-sweep: target gone (rmdir mid-deploy) | Warn, omit block for that target, deploy completes |
| Hub mode: one sub-repo's snapshot/sweep fails | Other repos still get summarized; no atomic rollback |

No new abort paths beyond "target is not a git repo". Everything else is
warn-and-proceed per the user's locked call.

## Migration / backward-compat

| Before v0.42.0 | After v0.42.0 |
|---|---|
| `/clone-wars:deploy <doc>` → creates `feat/deploy-<topic>`, refuses on dirty tree (rc=7) | Stays on current branch, snapshots WIP, no refusal |
| `/clone-wars:deploy --no-branch <doc>` → stays on current branch (no snapshot) | Default behavior; `--no-branch` becomes a no-op flag kept for one release for back-compat |
| `/clone-wars:deploy --branch [name] <doc>` → custom branch | Unchanged — opt-in sandbox-branch mode; snapshot still applies |
| Sub-step 5a AskUserQuestion (Stash/Commit/Abort) | Removed |
| `bin/deploy-init.sh` rc=7 dirty-tree exit | Preserved only when `--branch` flag is present |
| `pre-deploy-stash.txt` artifact | Removed |
| Tests asserting rc=7 default behavior | Migrated to assert new default path; counted upfront in the plan |

`--no-branch` is kept as a recognized no-op flag for v0.42.0 only so
existing user workflows keep working through one release cycle. v0.43.0
or later may remove it.

## Test surface

### New unit tests

- `test_deploy_pre_snapshot_clean.sh` — clean tree → no commit, state=clean
- `test_deploy_pre_snapshot_dirty.sh` — dirty tree → commit + state=wip-committed
- `test_deploy_pre_snapshot_untracked.sh` — only untracked files → commit + state=wip-committed
- `test_deploy_pre_snapshot_hook_blocked.sh` — pre-commit hook exits 1 → state=hook-blocked, no abort
- `test_deploy_pre_snapshot_detached.sh` — detached HEAD → state=clean OR wip-committed, branch=`(detached)`
- `test_deploy_pre_snapshot_not_a_repo.sh` — target dir without `.git` → rc=2 abort
- `test_deploy_iter_targets_single.sh` — single-repo synthesizes one row
- `test_deploy_iter_targets_hub.sh` — 2-row troopers.txt → 2 rows emitted
- `test_deploy_post_sweep_clean.sh` — post-deploy clean → state=no-leftovers
- `test_deploy_post_sweep_dirty.sh` — leftover files → commit + state=swept
- `test_deploy_post_sweep_branch_changed.sh` — branch differs → branch_changed=true
- `test_deploy_format_summary_block.sh` — given baseline + post TSV fixtures, asserts exact block text

### New integration tests

- `test_deploy_ceremony_e2e_single.sh` — temp repo, dispatch a no-op
  trooper stub via `cw_deploy_iter_targets`, verify baselines/post
  files exist and summary block prints correctly
- `test_deploy_ceremony_e2e_hub.sh` — temp hub with 2 sub-repos, one
  clean / one dirty, verify both blocks render

### Permanent lint

- `test_deploy_branch_pin_lint.sh` — greps `lib/deploy.sh` for the
  literal `BRANCH DISCIPLINE` stanza in all three prompt builders
  (`cw_deploy_build_turn_prompt_round1`, `_fix`, `_dag_unit`). Catches
  prompt-builder drift.

### Migrated / removed tests

- `test_deploy_branch_create_dirty_tree.sh` (rc=7 assertion) →
  migrated to assert new default snapshot path; rc=7 path moved into
  a new `--branch`-mode test
- Any test asserting 5a AskUserQuestion path → removed
- `test_deploy_stash_pop.sh` (if it exists) → removed alongside stash
  machinery removal

### Static-wiring lock

A `test_v0_42_0_static_wiring.sh` lock covering ≥6 invariants
(per the repo's release pattern):
- `lib/deploy.sh` exports `cw_deploy_iter_targets`,
  `cw_deploy_pre_snapshot`, `cw_deploy_post_sweep`,
  `cw_deploy_format_summary_block`
- All three prompt builders contain the `BRANCH DISCIPLINE` stanza
- `commands/deploy.md` invokes `bin/deploy-pre-snapshot.sh` exactly
  once in Step 0
- `commands/deploy.md` invokes `bin/deploy-summary.sh` exactly once in
  Step 4 (before archive)
- `commands/deploy.md` does NOT contain the legacy 5a AskUserQuestion
  Stash/Commit/Abort options
- `bin/deploy-init.sh` only exits 7 inside a `--branch`-flag guard

Skip-guarded at `plugin.json` version `0.42.0` per the established
release pattern.

## Success criteria

- A single-repo deploy on a dirty current branch completes without
  prompting the user about dirty tree, leaves a `chore: WIP before
  deploy <topic>` commit at the start, troopers commit per task on the
  same branch, and prints one summary block at the end naming the
  current branch, the diff stat, and the commit list.
- A hub-mode deploy with 2 sub-repos (each on its own current branch)
  produces 2 summary blocks back-to-back, with no branch switches
  observed in either.
- A trooper that violates the branch-pin stanza (e.g. runs
  `git checkout -b foo`) gets flagged in the summary block but does
  not crash the deploy.
- A user with a `pre-commit` hook that rejects WIP commits sees a
  WARNING in the summary block instead of an aborted deploy.
- Running `/clone-wars:deploy --branch sandbox <doc>` still creates a
  `sandbox` branch and applies the snapshot/sweep ceremony there
  (opt-in path preserved).

## Out of scope (explicit)

- **Stash mode**: today's "Stash and continue" path goes away. If users
  want stash semantics, they can `git stash` manually before invoking.
  No flag.
- **Per-task summary granularity**: summary is per-repo, not
  per-trooper-task. Troopers' commit messages serve that purpose.
- **Cross-repo coordination / atomic rollback**: if a hub deploy has 3
  sub-repos and 1 fails, the other 2 still get committed and
  summarized. The v0.30.0 `cw_deploy_revert_and_replay` helper exists
  for adjacent-tree rescue but is not invoked by this ceremony.
- **Summary persistence to a file**: ephemeral chat block only. Can be
  added later via `--summary-file <path>` if requested.
- **Auto-recovery from branch-pin violations**: instruction-level only.
  We surface violations in the summary; we don't `git checkout -` the
  trooper back.
- **Synthesized slug collision** (single-repo `main` vs a hub commander
  named `main`): not handled — commander pool (`config/commanders.yaml`)
  is Star Wars characters (rex, cody, wolffe, …); a literal `main`
  commander would be a user-introduced conflict outside the spec's
  contract.
- **Cross-cwd-snapshot dedup**: if two sub-repos happen to share a path
  somehow (symlink, bind mount), they each get snapshotted
  independently. No dedup logic.
- **Snapshot replay / undo command**: no `/clone-wars:deploy:undo`
  shortcut. The baseline SHA is in `baselines/<slug>.tsv` if a user
  wants to `git reset --hard <baseline>` manually.

## Release version

Targeting **v0.42.0** ("deploy git-repo discipline"). Refactor + new
feature scope; not refactor-only, so static-wiring lock applies.
