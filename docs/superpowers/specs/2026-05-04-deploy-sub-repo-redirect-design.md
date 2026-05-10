# Deploy Sub-Repo Redirect Design (v0.10.0)

## Goal

Let `/clone-wars:deploy` redirect into a sub-repo when the design doc declares a `**Target Sub-Project:** <name>` header — useful for hub repos like `/home/liupan/ARS/ars_fleet` that coordinate child sub-repos. Single-repo behavior unchanged when the header is absent. Consult's design-doc mode learns to ask for the header when run in a hub.

## Success Criteria

- A `**Target Sub-Project:** <slug>` header in `design.md` causes `/clone-wars:deploy` to spawn the trooper inside `<conductor-cwd>/<slug>/`, create the branch in that sub-repo, run provider auto-detection against `<sub-repo>/.claude-plugin/plugin.json`, and key state under the sub-repo's repo hash.
- `bin/spawn.sh` accepts an optional `--cwd <abs-path>` flag; trooper pane opens in that directory.
- `cw_deploy_extract_target` parses the header (5 cases tested); `cw_deploy_resolve_target` validates the sub-repo path (4 cases tested); `cw_repo_hash_for <cwd>` lets state-paths be computed against arbitrary cwds (3 cases tested).
- Audit gate `target_subproject_when_invalid` rejects malformed headers (path traversal, bad slug, multiple matches).
- `commands/deploy.md` Step 0 persists the resolved target to `_deploy/target_cwd.txt`; Step 1.1 passes it to spawn; Step 2 cross-verify uses `git -C "$TARGET_CWD"` everywhere.
- Header absent → behavior identical to v0.9.0 (no regression).
- `commands/consult.md` design-doc mode (Step 8.5) detects when conductor cwd is a hub (any immediate child has `.git/`) and asks the user which sub-repo (or "not applicable") via `AskUserQuestion`. Chosen sub-repo is written as the header at the top of the assembled `design.md`.
- New `cw_consult_detect_hub` helper + a self-review gate in `bin/consult-design-doc.sh` validate header well-formedness before commit.
- `bin/medic.sh` deploy-helpers-load probe extends to smoke-test `cw_deploy_resolve_target`.
- `tests/run.sh` stays green; pre-existing failure (`test_consult_load_prompt_migration.sh`) remains unrelated.
- Multi-target / DAG dispatch is **out of scope** (deferred to a future v0.11 spec following the established cross-repo orchestration pattern).

## Architecture

`/clone-wars:deploy` learns to **redirect into a sub-repo** when the design doc names one via a `**Target Sub-Project:** <name>` header. In hub repos (parent git repo coordinating child git repos like `/home/liupan/ARS/ars_fleet`), the trooper's pane, branch, state, and provider auto-detection all happen INSIDE the sub-repo — not the hub. When the header is absent, behavior is unchanged (today's single-repo flow).

**Three load-bearing principles:**

1. **Header is the only signal.** No hub-detection heuristics, no path-parsing magic. The design doc's `**Target Sub-Project:** <name>` line is the single source of truth; `<name>` is matched against `<conductor-cwd>/<name>/.git/` for validity. Absent → single-repo mode (today). Present + valid → redirect. Present + invalid → audit FAIL with clear error.

2. **State, branch, and provider all move with the redirect.** When the trooper deploys into `ARS-Perfusion`:
   - State lives at `<state-root>/state/<sub-repo-hash>/<topic>/_deploy/` (sub-repo's hash, not hub's). Two parallel deploys in different sub-repos of the same hub never collide.
   - Branch `feat/deploy-<topic>` is created in the sub-repo (`git -C <sub-repo> checkout -b ...`), not the hub.
   - Provider auto-detect reads `<sub-repo>/.claude-plugin/plugin.json` (not the hub's). The asymmetric confirmation pattern (codex auto-go / claude with confirmation) still applies; just relative to the sub-repo.
   - Tmux pane spawns with `cwd = <sub-repo>` so the trooper sees `git status` against the sub-repo, runs the sub-repo's tests, etc.

3. **Conductor stays at the hub; trooper lives in the sub-repo.** The conductor never `cd`s into the sub-repo. All sub-repo operations use absolute paths (`git -C <sub-repo> ...`, `tmux split-window -c <sub-repo>`). The user's `tmux select-pane` to attach the trooper still works because the pane's cwd is the sub-repo.

**What stays the same:** the single-repo flow (no header → today's behavior, full backward compat), the audit gates (with one new gate), the turn/fix-loop machinery, the cross-verify reads (just against `<sub-repo-hash>/<topic>/_deploy/...`), the teardown+archive flow, the spec/plan filename convention.

**What's new:** a `**Target Sub-Project:** <name>` header convention; one new audit gate (`target_subproject_when_invalid`); `cw_deploy_extract_target` + `cw_deploy_resolve_target` helpers; `cw_repo_hash_for <cwd>` helper; redirected `git -C` / `tmux -c` invocations; sub-repo-keyed state path resolution; `bin/spawn.sh --cwd <abs-path>` flag; `cw_consult_detect_hub` helper; consult design-doc walk asks for the header in hub mode.

**Out of scope:** multi-target / DAG dispatch (deferred to v0.11 spec — established cross-repo orchestration pattern); `.gitmodules` introspection (we don't care if the sub-repo is a submodule, just that it's a git repo); cross-sub-repo integration audit; a `--target` CLI override (the header is the source of truth).

## Components

### Deploy side

**1. New `**Target Sub-Project:** <name>` header convention** in design docs:

```markdown
# My Feature Design Doc

**Target Sub-Project:** ARS-Perfusion

## Goal
...
```

`<name>` is a slug matching `^[A-Za-z0-9._-]+$` (allows `ARS-Perfusion`, `web-frontend`, `api.v2`, etc.). Case-sensitive — the header value must match the sub-repo directory name exactly. The header is purely additive; existing single-repo specs without it remain valid.

**2. New helper `cw_deploy_extract_target <design-path>`** in `lib/deploy.sh`:

- Greps for `^\*\*Target Sub-Project:\*\*\s+\S+` at the start of any line.
- If absent: prints empty string + returns 0 (caller treats as single-repo).
- If present: prints the slug + returns 0.
- If present but malformed (multiple matches, non-slug value): returns 1 + clear error.

**3. Updated `cw_deploy_audit_doc`** in `lib/deploy.sh`:

- Add a new gate `target_subproject_when_invalid`: if the header is present, validate the slug matches `^[A-Za-z0-9._-]+$`. (Existence-of-sub-repo-dir check happens later in `cw_deploy_resolve_target`, not here — audit only cares about doc shape.)
- Existing gates (Goal / Architecture / Testing / Success / no-TBD / etc.) unchanged.

**4. New helper `cw_deploy_resolve_target <design-path> <conductor-cwd>`** in `lib/deploy.sh`:

```bash
# Returns the absolute target cwd for the deploy:
#   - If design doc has no Target Sub-Project header → returns <conductor-cwd>.
#   - If header present + <conductor-cwd>/<slug>/.git exists → returns <conductor-cwd>/<slug>.
#   - If header present but <conductor-cwd>/<slug>/.git missing → rc=1 + log_error.
#   - If header present + <conductor-cwd>/<slug> exists but no .git → rc=1 + log_error.
# rc=2 on missing args.
```

The helper does the file-existence check that the audit deliberately doesn't do — separation of concerns: audit validates doc shape; resolver validates filesystem reality.

**5. `bin/deploy-init.sh` integration:**

- After audit completes, call `cw_deploy_resolve_target "$DESIGN_PATH" "$(cw_repo_root)"`.
- Set `TARGET_CWD=$(cw_deploy_resolve_target ...)`.
- Compute `ART_DIR` using the new `cw_repo_hash_for "$TARGET_CWD"` (instead of bare `cw_repo_hash`).
- Use `git -C "$TARGET_CWD"` for branch-create.
- Provider auto-detect reads `<TARGET_CWD>/.claude-plugin/plugin.json`.
- Persist `$TARGET_CWD` to `_deploy/target_cwd.txt` (atomic-write via `cw_atomic_write`).

**6. `lib/state.sh` extension:** add `cw_repo_hash_for <cwd>` — same SHA256 logic as `cw_repo_hash` but takes an explicit cwd instead of `$PWD`. The existing `cw_repo_hash` becomes a thin wrapper: `cw_repo_hash() { cw_repo_hash_for "$PWD"; }`.

**7. `bin/spawn.sh` `--cwd <abs-path>` flag:**

- Optional flag. When present, validates the value is an existing absolute path; passes to `tmux split-window -c <cwd>`.
- When absent, uses today's behavior (inherits conductor cwd).
- Argv parsing follows the same pattern as `--from` / `--mode` flags already in spawn.sh.

**8. `commands/deploy.md` Step 0 changes:**

- Read `target_cwd.txt` after init returns; export `$TARGET_CWD` for the rest of the directive.
- Document `target_cwd.txt` in the env-var/state-file section.

**9. `commands/deploy.md` Step 1.1 spawn line:**

```
TARGET_CWD=$(cat "$ART_DIR/target_cwd.txt")
PROVIDER=$(cat "$ART_DIR/provider.txt")
"$CLAUDE_PLUGIN_ROOT/bin/spawn.sh" cody "$PROVIDER" "$TOPIC" --cwd "$TARGET_CWD"
```

**10. `commands/deploy.md` Step 2 cross-verify:**

- All `git log/diff` invocations use `git -C "$TARGET_CWD" log/diff ...`.
- `$BRANCH_BASE` is computed via `git -C "$TARGET_CWD" rev-parse HEAD`.
- Spot-check Reads happen against absolute paths under `$TARGET_CWD`.

### Consult side

**11. New helper `cw_consult_detect_hub <cwd>`** in `lib/consult.sh`:

- Returns `0` (success, prints names of sub-repos one per line) if any IMMEDIATE child of `<cwd>` contains a `.git/` directory AND `<cwd>` itself is a git repo.
- Returns `1` (no output) otherwise.

**12. `commands/consult.md` design-doc walk extension** (Step 8.5):

- BEFORE the Architecture section walk, call `cw_consult_detect_hub "$(pwd)"`.
- If hub detected: AskUserQuestion *"This looks like a hub repo (sub-repos: A, B, C). Which sub-repo will implement this design — or is it hub-level?"* with options being each detected sub-repo + "Hub-level / multi-target / not applicable".
- If user picks a sub-repo: prepend the design-doc body with `**Target Sub-Project:** <chosen-name>\n\n` so the assembled `design.md` carries the header.
- If user picks the "not applicable" option: no header written.

**13. `bin/consult-design-doc.sh` validation gate:**

- The existing self-review pass (placeholder scan) gets one new check: if a `**Target Sub-Project:**` header is present, validate the slug format (matches `^[A-Za-z0-9._-]+$`). Malformed → fail loudly so the user can fix before committing.

### Cross-cutting

**14. `bin/medic.sh` deploy-helpers-load probe** extension: add `cw_deploy_resolve_target /tmp /tmp >/dev/null` to the probe chain so refactor breakage surfaces immediately.

## Data Flow

**1. Conductor invokes `/clone-wars:deploy <design-path>` from a hub** (Step 0):

```
commands/deploy.md Step 0
  → bin/deploy-init.sh --args-file ...
       └─ existing: derive topic, copy design.md, audit
       └─ NEW: TARGET_CWD=$(cw_deploy_resolve_target "$DESIGN_PATH" "$(cw_repo_root)")
       └─ NEW: ART_DIR uses cw_repo_hash_for "$TARGET_CWD"
       └─ NEW: persist atomic-write → $ART_DIR/target_cwd.txt
       └─ existing branch-create now uses git -C "$TARGET_CWD" checkout -b
       └─ existing provider auto-detect now reads "$TARGET_CWD/.claude-plugin/plugin.json"
       └─ existing auto_provider.txt write
  → captures topic from stdout (unchanged)
```

State path now uses sub-repo hash:

```
ART_DIR=<state-root>/state/<sub-repo-hash>/<topic>/_deploy/
```

**2. Spawn (Step 1.1):**

```
TARGET_CWD=$(cat "$ART_DIR/target_cwd.txt")
PROVIDER=$(cat "$ART_DIR/provider.txt")
"$CLAUDE_PLUGIN_ROOT/bin/spawn.sh" cody "$PROVIDER" "$TOPIC" --cwd "$TARGET_CWD"
```

The trooper's pane opens with `pwd = $TARGET_CWD` (the sub-repo). The trooper runs `git status` against the sub-repo, runs the sub-repo's tests, etc.

**3. Cross-verify (Step 2):**

```
git -C "$TARGET_CWD" log --oneline "$BRANCH_BASE..HEAD"
git -C "$TARGET_CWD" diff --stat "$BRANCH_BASE..HEAD"
```

Yoda's spot-check Reads use absolute paths under `$TARGET_CWD`.

**4. Auto-retry path:** unchanged. `target_cwd.txt` is locked at Step 0; auto-retry just re-dispatches the same prompt to the same pane. Provider, target, branch, and state are all immutable for the duration of the topic.

**5. Teardown + archive:** state (including `target_cwd.txt`, `auto_provider.txt`, `provider.txt`) moves to `<archive-root>/...` under the sub-repo's hash. Single archive per topic; no cross-pollination with hub-level state.

**6. Single-repo case (no header):** `cw_deploy_resolve_target` returns `$(cw_repo_root)`. State path uses conductor's repo hash (today's behavior). Spawn uses default cwd. Behavior identical to v0.9.

**7. Consult design-doc walk (Step 8.5) in a hub:**

```
commands/consult.md Step 8.5 (BEFORE the Architecture section walk)
  → SUB_REPOS=$(cw_consult_detect_hub "$(pwd)")
  → if non-empty: AskUserQuestion (each sub-repo + "Hub-level / multi-target / not applicable")
  → if user picks <name>: TARGET_PREAMBLE="**Target Sub-Project:** $name\n\n"
  → else: TARGET_PREAMBLE=""
  → existing: walk Architecture / Components / Data Flow / Error Handling / Testing sections
  → existing: bin/consult-design-doc.sh assembles → prepends $TARGET_PREAMBLE → commits
```

The assembled spec at `docs/clone-wars/specs/...` carries the header. When the user later runs `/clone-wars:deploy <path-to-this-spec>`, deploy reads the header, redirects to the sub-repo. End-to-end ergonomic: consult → designed → deploy → trooper-in-sub-repo, no manual annotations.

## Error Handling

**1. Header present but `<sub-repo-name>/.git` is missing** — `cw_deploy_resolve_target` returns rc=1 with `log_error "target sub-project '<name>' not found at <conductor-cwd>/<name> (no .git dir; check spelling or that the sub-repo is checked out)"`. Surfaces during `bin/deploy-init.sh`; auto-rollback `_deploy/` and exit non-zero. User fixes the header (typo) or the sub-repo (not cloned) and re-runs.

**2. Header malformed** (multiple matches, slug fails regex, value contains `/` or `..`) — caught by the audit gate `target_subproject_when_invalid` BEFORE init proceeds. Audit RC=1; directive's existing AUDIT_RC handler fires (Proceed anyway / Abort and edit). Spec text recommends "Abort" since malformed headers indicate a real spec problem.

**3. Header present, sub-repo dir exists, but it's a regular dir not a git repo** (no `.git/`) — same as #1: rc=1 with a slightly different message: `target sub-project '<name>' is a directory but not a git repo`. Defensive — if the sub-repo directory exists without `.git/`, the user probably meant to clone it.

**4. `bin/spawn.sh --cwd` arg missing or invalid** — spawn.sh validates the flag value: must be an existing absolute path. Failure → exit non-zero with `log_error "spawn --cwd target does not exist: <path>"`. Won't fire from the directive's flow (target existence was validated at init), but defends against direct manual invocation.

**5. Branch creation fails inside the sub-repo** — `cw_deploy_branch_create` already handles dirty-tree / pre-existing-branch refusal. No change needed; the helper just runs against `git -C "$TARGET_CWD"` instead of `$PWD`. Auto-rollback in deploy-init.sh removes `$ART_DIR` (the sub-repo-keyed one) on failure.

**6. State-path collision across hub sub-repos** — impossible by design. Each sub-repo has a distinct hash; two simultaneous deploys in `ARS-Perfusion` and `ARS-CppOps` produce distinct `<state-root>/state/<hash-A>/...` vs `.../<hash-B>/...` paths. This is a feature, not a bug.

**7. Single-repo invocations (no header)** — `cw_deploy_resolve_target` returns `$(cw_repo_root)`, no error path triggered. State path equals today's path. No regression.

**8. Hub user runs deploy with a single-repo (no-header) spec from inside the hub** — works exactly as today: trooper spawns with `cwd = hub`. Predictable and useful for hub-level work (e.g., updating hub docs). Header convention is opt-in.

**9. Consult invoked in a non-hub repo** — `cw_consult_detect_hub` returns rc=1; consult's design-doc walk skips the Target Sub-Project prompt entirely. No behavior change for single-repo consult users.

**10. Consult invoked in a hub but user picks "Hub-level / multi-target / not applicable"** — no `Target Sub-Project` header written. Designer can manually add it later, or split the spec, or use external multi-agent dispatch for multi-target. Consistent with the spec's deferred multi-target scope.

**11. Backward compatibility** — existing `_deploy/` directories from before this feature ships have no `target_cwd.txt`. Step 0 runs from scratch on each new deploy; existing pre-existing state was either teardown'd or lives in archive. No migration logic needed.

**12. Migration for legacy state-path users** — none. Pre-v0.10 deploys used `<conductor-cwd>` for state hashing. New deploys in hubs use `<sub-repo-cwd>`. The two paths simply don't overlap. `/clone-wars:list` will show old hub-keyed topics under the hub hash and new sub-repo-keyed topics under the sub-repo hash; users see both.

## Testing

**1. New `cw_deploy_extract_target` assertions in `tests/test_deploy_helpers.sh`** (5 cases):

- Returns empty + rc=0 when no header in fixture spec.
- Returns `ARS-Perfusion` + rc=0 for valid header `**Target Sub-Project:** ARS-Perfusion`.
- Returns rc=1 for malformed header (e.g. multiple matches, slug fails `^[A-Za-z0-9._-]+$`).
- Returns rc=2 with clear error for missing arg.
- Tolerates leading/trailing whitespace + alternate emphasis (`**…:** name` and `**…:**  name` both extract correctly).

**2. New `cw_deploy_resolve_target` assertions in `tests/test_deploy_helpers.sh`** (4 cases):

- No header → returns conductor-cwd verbatim.
- Header + valid sub-repo (fixture: `tmp/repo/sub/.git/`) → returns `tmp/repo/sub`.
- Header + missing sub-repo → returns rc=1 with message containing "not found".
- Header + sub-repo dir exists but no `.git` → returns rc=1 with message containing "not a git repo".

**3. New `cw_repo_hash_for` assertions in `tests/test_state.sh`** (3 cases):

- Explicit cwd produces deterministic hash.
- `cw_repo_hash_for "$PWD"` equals `cw_repo_hash` (backward-compat invariant).
- Non-existent dir returns rc=1.

**4. New audit-gate assertion in `tests/test_deploy_helpers.sh`**:

- Audit RC=1 + ISSUE=`target_subproject_when_invalid` for a spec with `**Target Sub-Project:** ../escape`.
- Audit PASS for a spec with valid header `**Target Sub-Project:** ARS-Perfusion`.
- Audit PASS for a spec without any header (single-repo case unchanged).

**5. Extended `tests/test_deploy_init.sh`** (2 cases):

- Hub fixture (`tmp/hub/.git/` + `tmp/hub/sub/.git/`) with header-bearing spec → init writes `_deploy/target_cwd.txt` containing `tmp/hub/sub` AND `_deploy/auto_provider.txt` reflecting the SUB-REPO's plugin.json (not the hub's).
- Hub fixture with header pointing at missing sub-repo → init exits non-zero, `_deploy/` auto-rolled-back.

**6. New `tests/test_deploy_directive_target.sh`** static-wiring assertions:

- `grep -q 'target_cwd.txt' commands/deploy.md` — directive references the file.
- `grep -qE 'git -C "?\$TARGET_CWD"?' commands/deploy.md` — Step 2 uses git -C.
- `grep -q '\-\-cwd' commands/deploy.md` — Step 1.1 spawn passes the flag.
- No leftover bare `git checkout -b` (without `git -C`) in directive.

**7. New `bin/spawn.sh --cwd` flag tests in `tests/test_spawn_validation.sh`**:

- `--cwd <existing-abs-path>` accepted; `tmux split-window -c <path>` issued (verify via grep on captured tmux command in a fixture).
- `--cwd <missing-path>` rejected with rc≠0.
- `--cwd` without value rejected.
- No `--cwd` → today's behavior preserved.

**8. New `cw_consult_detect_hub` assertions in `tests/test_consult_detect_hub.sh`** (4 cases):

- Hub fixture (parent + 2 child .git dirs) → returns rc=0 + lists 2 sub-repo names.
- Single-repo fixture (parent .git only, no children) → rc=1 + empty.
- Nested non-git child dirs → rc=1 (children must have `.git`).
- Cwd is not a git repo → rc=1 (the parent must be a git repo too — a hub IS a git repo).

**9. Extended `tests/test_consult_design_doc.sh`**:

- Hub fixture + simulated user-pick-of-sub-repo → assembled spec contains `**Target Sub-Project:** <name>` as the second non-blank line (right after the title).
- Hub fixture + user picks "not applicable" → assembled spec has NO header.

**10. Extended `bin/medic.sh` deploy-helpers-load probe** — add `cw_deploy_resolve_target /tmp /tmp >/dev/null` to the probe chain.

**11. Manual dogfood gate** — extend `tests/test_deploy_v07_dogfood.sh` (or create v0.10) with one new scenario:

- `cd /home/liupan/ARS/ars_fleet`. Author a small fixture spec with `**Target Sub-Project:** ARS-Perfusion`. Run `/clone-wars:deploy <spec>`.
- Confirm: trooper pane spawns with `pwd = ars_fleet/ARS-Perfusion`; branch `feat/deploy-<topic>` created in the sub-repo; state at `<state-root>/state/<sub-repo-hash>/<topic>/_deploy/`; `target_cwd.txt` content matches.
- Re-run with a header pointing at non-existent `ARS-Foo` → confirm clean rc≠0 + auto-rollback.

**12. Test-suite invariant** — `tests/run.sh` discovers `test_*.sh`; new tests use the same `set -euo pipefail` + `cw_assert_*` helpers. No new framework dependency.
