# /clone-wars:deploy — git-repo discipline (v0.42.0) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship v0.42.0 — `/clone-wars:deploy` operates on the user's current branch in each affected repo (single-repo and hub mode), wrapped by a pre-deploy WIP snapshot + post-deploy sweep ceremony and a per-repo summary block at Step 4.

**Architecture:** Add four helpers to `lib/deploy.sh` (`cw_deploy_iter_targets`, `cw_deploy_pre_snapshot`, `cw_deploy_post_sweep`, `cw_deploy_format_summary_block`). Two new bin scripts (`deploy-pre-snapshot.sh`, `deploy-summary.sh`) walk targets and call the helpers. `commands/deploy.md` Step 0 invokes the snapshot script after init; Step 4 invokes the summary script before archive. The legacy `feat/deploy-<topic>` auto-branch path becomes opt-in via `--branch`.

**Tech Stack:** Pure bash 4.2+, tmux 3.0+, git ≥ 2.17. No Node/Python runtime. Tests via `tests/run.sh` (glob discovery of `test_*.sh`). Assert helpers at `tests/lib/assert.sh` (`pass`, `assert_eq`, `assert_contains`, `assert_exit`, `assert_file_exists`).

---

## File Structure

```
clone-wars/
├── lib/
│   └── deploy.sh                                     # MODIFY: append 4 helpers + BRANCH DISCIPLINE stanza to 3 prompt builders
├── bin/
│   ├── deploy-pre-snapshot.sh                        # CREATE: walks iter_targets → calls pre_snapshot per row
│   ├── deploy-summary.sh                             # CREATE: walks iter_targets → calls post_sweep + format_summary_block per row
│   └── deploy-init.sh                                # MODIFY: gate rc=7 behind --branch flag
├── commands/
│   └── deploy.md                                     # MODIFY: Step 0 sub-step 5 (default --no-branch) + 5a removal + new 6 (pre-snapshot) + Step 4 new sub-step (summary)
├── .claude-plugin/
│   ├── plugin.json                                   # MODIFY: 0.41.0 → 0.42.0
│   └── marketplace.json                              # MODIFY: both version lines → 0.42.0
├── CLAUDE.md                                         # MODIFY: Current focus rewrite
├── docs/
│   └── CHANGELOG.md                                  # MODIFY: prepend v0.42.0 entry
└── tests/
    ├── test_deploy_iter_targets_single.sh            # CREATE
    ├── test_deploy_iter_targets_hub.sh               # CREATE
    ├── test_deploy_pre_snapshot_clean.sh             # CREATE
    ├── test_deploy_pre_snapshot_dirty.sh             # CREATE
    ├── test_deploy_pre_snapshot_untracked.sh         # CREATE
    ├── test_deploy_pre_snapshot_hook_blocked.sh      # CREATE
    ├── test_deploy_pre_snapshot_detached.sh          # CREATE
    ├── test_deploy_pre_snapshot_not_a_repo.sh        # CREATE
    ├── test_deploy_post_sweep_clean.sh               # CREATE
    ├── test_deploy_post_sweep_dirty.sh               # CREATE
    ├── test_deploy_post_sweep_branch_changed.sh      # CREATE
    ├── test_deploy_format_summary_block.sh           # CREATE
    ├── test_deploy_ceremony_e2e_single.sh            # CREATE
    ├── test_deploy_ceremony_e2e_hub.sh               # CREATE
    ├── test_deploy_branch_pin_lint.sh                # CREATE (permanent lint)
    ├── test_v0_42_0_static_wiring.sh                 # CREATE (skip-guarded version lock)
    ├── test_deploy_init_dirty_tree_rc7.sh            # MODIFY: assertion guarded under --branch flag
    └── test_deploy_dirty_intercept_directive.sh      # DELETE (replaced by new directive-shape assertions)
```

---

## Task 0: Baseline confirmation

**Files:** none (no commit; verification only).

- [ ] **Step 1: Verify branch + version + clean tree**

```bash
git rev-parse --abbrev-ref HEAD
grep '"version"' .claude-plugin/plugin.json | head -1
git status --short
```

Expected:
- branch = `feat/v0.42.0-deploy-git-repo-discipline`
- plugin.json version = `0.41.0`
- status shows only intentionally-untracked `.deepseek/` and `opencode.json`, plus the v0.42.0 spec already committed

- [ ] **Step 2: Run full suite to confirm GREEN baseline**

```bash
bash tests/run.sh 2>&1 | tail -20
```

Expected: final line `0` exit, no `FAIL` lines. Pre-existing timing flakes (`test_consult_targets_forces_escalation`, `test_deploy_archive`, `test_consult_archive`) may flap once; retry the suite once if any of those three fail. Do NOT proceed to T1 unless suite is green.

---

## Task 1: RED test scaffolds (13 unit/integration tests + 1 permanent lint)

**Files:**
- Create: `tests/test_deploy_iter_targets_single.sh`
- Create: `tests/test_deploy_iter_targets_hub.sh`
- Create: `tests/test_deploy_pre_snapshot_clean.sh`
- Create: `tests/test_deploy_pre_snapshot_dirty.sh`
- Create: `tests/test_deploy_pre_snapshot_untracked.sh`
- Create: `tests/test_deploy_pre_snapshot_hook_blocked.sh`
- Create: `tests/test_deploy_pre_snapshot_detached.sh`
- Create: `tests/test_deploy_pre_snapshot_not_a_repo.sh`
- Create: `tests/test_deploy_post_sweep_clean.sh`
- Create: `tests/test_deploy_post_sweep_dirty.sh`
- Create: `tests/test_deploy_post_sweep_branch_changed.sh`
- Create: `tests/test_deploy_format_summary_block.sh`
- Create: `tests/test_deploy_ceremony_e2e_single.sh`
- Create: `tests/test_deploy_ceremony_e2e_hub.sh`
- Create: `tests/test_deploy_branch_pin_lint.sh`

T1 writes every test RED in one commit. T2–T6 turn them GREEN incrementally. T1 commit prefix: `test:`.

- [ ] **Step 1: Write `tests/test_deploy_iter_targets_single.sh`**

```bash
#!/usr/bin/env bash
# tests/test_deploy_iter_targets_single.sh
# v0.42.0: single-repo deploy synthesizes one row 'main\t<target_cwd>'.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deploy.sh"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
cd "$SANDBOX"
git init -q
git config user.email t@t; git config user.name T
echo content > seed.txt; git add seed.txt; git commit -qm seed
export CLONE_WARS_HOME="$SANDBOX/.clone-wars"

TOPIC=iter-single
ART_DIR=$(cw_deploy_art_dir "$TOPIC")
mkdir -p "$ART_DIR"
printf '%s\n' "$SANDBOX" > "$ART_DIR/target_cwd.txt"

OUT=$(cw_deploy_iter_targets "$TOPIC")
EXPECTED=$(printf 'main\t%s' "$SANDBOX")
assert_eq "$OUT" "$EXPECTED" "single-repo emits one row 'main\\t<cwd>'"
pass "1. single-repo iter_targets emits 'main\\t<target_cwd>'"

echo "test_deploy_iter_targets_single: 1 case passed"
```

- [ ] **Step 2: Write `tests/test_deploy_iter_targets_hub.sh`**

```bash
#!/usr/bin/env bash
# tests/test_deploy_iter_targets_hub.sh
# v0.42.0: hub-mode deploy emits one row per troopers.txt entry.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deploy.sh"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
cd "$SANDBOX"
git init -q
git config user.email t@t; git config user.name T
echo c > seed.txt; git add seed.txt; git commit -qm seed
export CLONE_WARS_HOME="$SANDBOX/.clone-wars"

TOPIC=iter-hub
ART_DIR=$(cw_deploy_art_dir "$TOPIC")
mkdir -p "$ART_DIR"
printf 'rex\t/abs/path/repo-a\tcodex\n' >  "$ART_DIR/troopers.txt"
printf 'cody\t/abs/path/repo-b\tclaude\n' >> "$ART_DIR/troopers.txt"

OUT=$(cw_deploy_iter_targets "$TOPIC")
EXPECTED=$'rex\t/abs/path/repo-a\ncody\t/abs/path/repo-b'
assert_eq "$OUT" "$EXPECTED" "hub-mode iter_targets emits 2 rows from troopers.txt"
pass "1. hub-mode iter_targets emits one row per troopers.txt entry"

echo "test_deploy_iter_targets_hub: 1 case passed"
```

- [ ] **Step 3: Write `tests/test_deploy_pre_snapshot_clean.sh`**

```bash
#!/usr/bin/env bash
# tests/test_deploy_pre_snapshot_clean.sh
# v0.42.0: clean tree → no commit, state=clean, baseline.sha = current HEAD.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deploy.sh"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
cd "$SANDBOX"
git init -q
git config user.email t@t; git config user.name T
echo c > seed.txt; git add seed.txt; git commit -qm seed
PRE_SHA=$(git rev-parse HEAD)

BASELINE="$SANDBOX/baseline.tsv"
cw_deploy_pre_snapshot "$SANDBOX" demo-topic main "$BASELINE"
assert_file_exists "$BASELINE" "baseline file written"
grep -qE '^state=clean$'           "$BASELINE" || { echo "FAIL: state not 'clean'" >&2; cat "$BASELINE" >&2; exit 1; }
grep -qE "^baseline_sha=$PRE_SHA$"  "$BASELINE" || { echo "FAIL: baseline_sha != PRE_SHA" >&2; cat "$BASELINE" >&2; exit 1; }
POST_SHA=$(git rev-parse HEAD)
assert_eq "$POST_SHA" "$PRE_SHA" "no commit added on clean tree"
pass "1. clean tree: pre_snapshot writes state=clean, baseline=HEAD, no commit"

echo "test_deploy_pre_snapshot_clean: 1 case passed"
```

- [ ] **Step 4: Write `tests/test_deploy_pre_snapshot_dirty.sh`**

```bash
#!/usr/bin/env bash
# tests/test_deploy_pre_snapshot_dirty.sh
# v0.42.0: modified tracked file → commit + state=wip-committed.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deploy.sh"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
cd "$SANDBOX"
git init -q
git config user.email t@t; git config user.name T
echo c > seed.txt; git add seed.txt; git commit -qm seed
PRE_SHA=$(git rev-parse HEAD)
echo modified >> seed.txt   # dirty (modified tracked file)

BASELINE="$SANDBOX/baseline.tsv"
cw_deploy_pre_snapshot "$SANDBOX" demo-topic main "$BASELINE"
assert_file_exists "$BASELINE"
grep -qE '^state=wip-committed$' "$BASELINE" || { echo "FAIL: state not 'wip-committed'" >&2; cat "$BASELINE" >&2; exit 1; }
NEW_SHA=$(git rev-parse HEAD)
[[ "$NEW_SHA" != "$PRE_SHA" ]] || { echo "FAIL: HEAD did not advance" >&2; exit 1; }
grep -qE "^baseline_sha=$NEW_SHA$" "$BASELINE" || { echo "FAIL: baseline_sha != new HEAD" >&2; exit 1; }
MSG=$(git log -1 --format=%s)
assert_eq "$MSG" "chore: WIP before deploy demo-topic" "commit message matches spec"
pass "1. dirty tree: pre_snapshot commits + state=wip-committed"

echo "test_deploy_pre_snapshot_dirty: 1 case passed"
```

- [ ] **Step 5: Write `tests/test_deploy_pre_snapshot_untracked.sh`**

```bash
#!/usr/bin/env bash
# tests/test_deploy_pre_snapshot_untracked.sh
# v0.42.0: only untracked files (no modified tracked files) → still committed.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deploy.sh"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
cd "$SANDBOX"
git init -q
git config user.email t@t; git config user.name T
echo c > seed.txt; git add seed.txt; git commit -qm seed
PRE_SHA=$(git rev-parse HEAD)
echo new > untracked.txt   # untracked only

BASELINE="$SANDBOX/baseline.tsv"
cw_deploy_pre_snapshot "$SANDBOX" demo-topic main "$BASELINE"
grep -qE '^state=wip-committed$' "$BASELINE" || { echo "FAIL: untracked-only should commit" >&2; cat "$BASELINE" >&2; exit 1; }
NEW_SHA=$(git rev-parse HEAD)
[[ "$NEW_SHA" != "$PRE_SHA" ]] || { echo "FAIL: HEAD did not advance for untracked-only" >&2; exit 1; }
git ls-files --others --exclude-standard | grep -q '^untracked\.txt$' \
  && { echo "FAIL: untracked.txt should now be tracked" >&2; exit 1; }
pass "1. untracked-only: pre_snapshot commits + state=wip-committed"

echo "test_deploy_pre_snapshot_untracked: 1 case passed"
```

- [ ] **Step 6: Write `tests/test_deploy_pre_snapshot_hook_blocked.sh`**

```bash
#!/usr/bin/env bash
# tests/test_deploy_pre_snapshot_hook_blocked.sh
# v0.42.0: pre-commit hook exits 1 → state=hook-blocked, baseline.sha=pre-attempt HEAD, no abort.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deploy.sh"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
cd "$SANDBOX"
git init -q
git config user.email t@t; git config user.name T
echo c > seed.txt; git add seed.txt; git commit -qm seed
PRE_SHA=$(git rev-parse HEAD)
echo modified >> seed.txt
# Install blocking pre-commit hook
cat > .git/hooks/pre-commit <<'EOF'
#!/bin/sh
echo "pre-commit blocked by test hook" >&2
exit 1
EOF
chmod +x .git/hooks/pre-commit

BASELINE="$SANDBOX/baseline.tsv"
set +e
cw_deploy_pre_snapshot "$SANDBOX" demo-topic main "$BASELINE"; rc=$?
set -e
[[ "$rc" -eq 0 ]] || { echo "FAIL: hook-blocked should still rc=0 (warn + proceed); got $rc" >&2; exit 1; }
grep -qE '^state=hook-blocked$' "$BASELINE" || { echo "FAIL: state not 'hook-blocked'" >&2; cat "$BASELINE" >&2; exit 1; }
grep -qE "^baseline_sha=$PRE_SHA$" "$BASELINE" || { echo "FAIL: baseline_sha should be pre-attempt HEAD" >&2; cat "$BASELINE" >&2; exit 1; }
POST_SHA=$(git rev-parse HEAD)
assert_eq "$POST_SHA" "$PRE_SHA" "HEAD did not advance after blocked commit"
pass "1. hook-blocked: pre_snapshot rc=0, state=hook-blocked, baseline=pre-HEAD"

echo "test_deploy_pre_snapshot_hook_blocked: 1 case passed"
```

- [ ] **Step 7: Write `tests/test_deploy_pre_snapshot_detached.sh`**

```bash
#!/usr/bin/env bash
# tests/test_deploy_pre_snapshot_detached.sh
# v0.42.0: detached HEAD → state captured normally, branch=(detached), no abort.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deploy.sh"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
cd "$SANDBOX"
git init -q
git config user.email t@t; git config user.name T
echo c > seed.txt; git add seed.txt; git commit -qm seed
echo c2 > seed2.txt; git add seed2.txt; git commit -qm seed2
git checkout -q HEAD~1   # detached HEAD

BASELINE="$SANDBOX/baseline.tsv"
set +e
cw_deploy_pre_snapshot "$SANDBOX" demo-topic main "$BASELINE"; rc=$?
set -e
[[ "$rc" -eq 0 ]] || { echo "FAIL: detached HEAD should warn + proceed; got rc=$rc" >&2; exit 1; }
grep -qE '^branch=\(detached\)$' "$BASELINE" || { echo "FAIL: branch field not '(detached)'" >&2; cat "$BASELINE" >&2; exit 1; }
pass "1. detached HEAD: pre_snapshot rc=0, branch=(detached)"

echo "test_deploy_pre_snapshot_detached: 1 case passed"
```

- [ ] **Step 8: Write `tests/test_deploy_pre_snapshot_not_a_repo.sh`**

```bash
#!/usr/bin/env bash
# tests/test_deploy_pre_snapshot_not_a_repo.sh
# v0.42.0: target dir without .git → rc=2 abort with explicit error.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deploy.sh"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
# Not a git repo (no git init)

BASELINE="$SANDBOX/baseline.tsv"
set +e
out=$(cw_deploy_pre_snapshot "$SANDBOX" demo-topic main "$BASELINE" 2>&1); rc=$?
set -e
[[ "$rc" -eq 2 ]] || { echo "FAIL: not-a-repo should rc=2; got $rc" >&2; echo "$out" >&2; exit 1; }
assert_contains "$out" "not a git repository" "error message names the failure"
[[ ! -e "$BASELINE" ]] || { echo "FAIL: baseline file should NOT exist on rc=2" >&2; exit 1; }
pass "1. not-a-repo: pre_snapshot rc=2, no baseline file written"

echo "test_deploy_pre_snapshot_not_a_repo: 1 case passed"
```

- [ ] **Step 9: Write `tests/test_deploy_post_sweep_clean.sh`**

```bash
#!/usr/bin/env bash
# tests/test_deploy_post_sweep_clean.sh
# v0.42.0: post-deploy clean tree → state=no-leftovers, no commit, no branch_changed.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deploy.sh"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
cd "$SANDBOX"
git init -q
git config user.email t@t; git config user.name T
echo c > seed.txt; git add seed.txt; git commit -qm seed
PRE_SHA=$(git rev-parse HEAD)

BASELINE="$SANDBOX/baseline.tsv"
cw_deploy_pre_snapshot "$SANDBOX" demo-topic main "$BASELINE"

POST="$SANDBOX/post.tsv"
cw_deploy_post_sweep "$BASELINE" demo-topic "$POST"
assert_file_exists "$POST"
grep -qE '^state=no-leftovers$' "$POST" || { echo "FAIL: state not 'no-leftovers'" >&2; cat "$POST" >&2; exit 1; }
grep -qE '^branch_changed=false$' "$POST" || { echo "FAIL: branch_changed not false" >&2; cat "$POST" >&2; exit 1; }
POST_SHA=$(git rev-parse HEAD)
assert_eq "$POST_SHA" "$PRE_SHA" "no commit added on clean post-deploy"
pass "1. clean post-deploy: post_sweep writes state=no-leftovers, branch_changed=false"

echo "test_deploy_post_sweep_clean: 1 case passed"
```

- [ ] **Step 10: Write `tests/test_deploy_post_sweep_dirty.sh`**

```bash
#!/usr/bin/env bash
# tests/test_deploy_post_sweep_dirty.sh
# v0.42.0: post-deploy leftover files → commit + state=swept.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deploy.sh"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
cd "$SANDBOX"
git init -q
git config user.email t@t; git config user.name T
echo c > seed.txt; git add seed.txt; git commit -qm seed

BASELINE="$SANDBOX/baseline.tsv"
cw_deploy_pre_snapshot "$SANDBOX" demo-topic main "$BASELINE"
BASE_SHA=$(git rev-parse HEAD)

# Simulate a trooper leaving leftover work uncommitted
echo trooper-leftover > leftover.txt

POST="$SANDBOX/post.tsv"
cw_deploy_post_sweep "$BASELINE" demo-topic "$POST"
grep -qE '^state=swept$' "$POST" || { echo "FAIL: state not 'swept'" >&2; cat "$POST" >&2; exit 1; }
NEW_SHA=$(git rev-parse HEAD)
[[ "$NEW_SHA" != "$BASE_SHA" ]] || { echo "FAIL: sweep should have committed leftover" >&2; exit 1; }
MSG=$(git log -1 --format=%s)
assert_eq "$MSG" "chore: post-deploy leftovers for demo-topic" "sweep commit message"
pass "1. dirty post-deploy: post_sweep commits leftover + state=swept"

echo "test_deploy_post_sweep_dirty: 1 case passed"
```

- [ ] **Step 11: Write `tests/test_deploy_post_sweep_branch_changed.sh`**

```bash
#!/usr/bin/env bash
# tests/test_deploy_post_sweep_branch_changed.sh
# v0.42.0: branch differs at sweep time → branch_changed=true (WARNING in summary).
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deploy.sh"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
cd "$SANDBOX"
git init -q -b main
git config user.email t@t; git config user.name T
echo c > seed.txt; git add seed.txt; git commit -qm seed

BASELINE="$SANDBOX/baseline.tsv"
cw_deploy_pre_snapshot "$SANDBOX" demo-topic main "$BASELINE"
# Simulate a trooper violating branch discipline
git checkout -q -b rogue-branch

POST="$SANDBOX/post.tsv"
cw_deploy_post_sweep "$BASELINE" demo-topic "$POST"
grep -qE '^branch_changed=true$' "$POST" || { echo "FAIL: branch_changed not 'true'" >&2; cat "$POST" >&2; exit 1; }
grep -qE '^branch=rogue-branch$' "$POST" || { echo "FAIL: post branch not 'rogue-branch'" >&2; cat "$POST" >&2; exit 1; }
pass "1. branch changed: post_sweep records branch_changed=true and new branch name"

echo "test_deploy_post_sweep_branch_changed: 1 case passed"
```

- [ ] **Step 12: Write `tests/test_deploy_format_summary_block.sh`**

```bash
#!/usr/bin/env bash
# tests/test_deploy_format_summary_block.sh
# v0.42.0: format_summary_block prints the documented per-repo block from baseline+post TSVs.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deploy.sh"

# Build a real sandbox repo so the commits/diff lines have real SHAs.
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
cd "$SANDBOX"
git init -q -b main
git config user.email t@t; git config user.name T
echo c > seed.txt; git add seed.txt; git commit -qm seed
BASE_SHA=$(git rev-parse HEAD)
echo c2 > seed2.txt; git add seed2.txt; git commit -qm "feat: add seed2"
POST_SHA=$(git rev-parse HEAD)

BASELINE="$SANDBOX/baseline.tsv"
cat > "$BASELINE" <<EOF
slug=main
cwd=$SANDBOX
branch=main
baseline_sha=$BASE_SHA
state=clean
snapshot_ts=2026-05-17T12:00:00Z
EOF

POST="$SANDBOX/post.tsv"
cat > "$POST" <<EOF
slug=main
cwd=$SANDBOX
branch=main
post_sha=$POST_SHA
state=no-leftovers
branch_changed=false
sweep_ts=2026-05-17T12:30:00Z
EOF

OUT=$(cw_deploy_format_summary_block "$BASELINE" "$POST")
assert_contains "$OUT" "═══ main [$SANDBOX] ═══" "block header"
assert_contains "$OUT" "branch:     main"        "branch line"
assert_contains "$OUT" "baseline:   $BASE_SHA"   "baseline sha"
assert_contains "$OUT" "HEAD:       $POST_SHA"   "post sha"
assert_contains "$OUT" "feat: add seed2"         "commit list includes feat commit"
pass "1. format_summary_block prints documented per-repo block"

echo "test_deploy_format_summary_block: 1 case passed"
```

- [ ] **Step 13: Write `tests/test_deploy_ceremony_e2e_single.sh`**

```bash
#!/usr/bin/env bash
# tests/test_deploy_ceremony_e2e_single.sh
# v0.42.0: end-to-end snapshot → trooper-stub commit → sweep → summary on temp single-repo.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deploy.sh"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
cd "$SANDBOX"
git init -q -b main
git config user.email t@t; git config user.name T
echo c > seed.txt; git add seed.txt; git commit -qm seed
echo wip >> seed.txt   # pre-deploy WIP
export CLONE_WARS_HOME="$SANDBOX/.clone-wars"

TOPIC=e2e-single
ART_DIR=$(cw_deploy_art_dir "$TOPIC")
mkdir -p "$ART_DIR"
printf '%s\n' "$SANDBOX" > "$ART_DIR/target_cwd.txt"

# Pre-deploy snapshot
"$PLUGIN_ROOT/bin/deploy-pre-snapshot.sh" "$TOPIC" >/dev/null
assert_file_exists "$ART_DIR/baselines/main.tsv" "baseline file created"
grep -qE '^state=wip-committed$' "$ART_DIR/baselines/main.tsv"

# Simulate trooper work
echo trooper > trooper.txt
git add trooper.txt
git commit -qm "feat: trooper added file"

# Post-deploy summary
OUT=$("$PLUGIN_ROOT/bin/deploy-summary.sh" "$TOPIC")
assert_file_exists "$ART_DIR/posts/main.tsv" "post file created"
assert_contains "$OUT" "═══ main [$SANDBOX] ═══" "summary block header"
assert_contains "$OUT" "feat: trooper added file"  "summary lists trooper commit"
pass "1. e2e single-repo: snapshot → trooper commit → summary roundtrip"

echo "test_deploy_ceremony_e2e_single: 1 case passed"
```

- [ ] **Step 14: Write `tests/test_deploy_ceremony_e2e_hub.sh`**

```bash
#!/usr/bin/env bash
# tests/test_deploy_ceremony_e2e_hub.sh
# v0.42.0: end-to-end ceremony on a hub with 2 sub-repos (one clean, one dirty).
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deploy.sh"

HUB=$(mktemp -d)
trap 'rm -rf "$HUB"' EXIT
mkdir -p "$HUB/repo-a" "$HUB/repo-b"
for r in repo-a repo-b; do
  ( cd "$HUB/$r"
    git init -q -b main
    git config user.email t@t; git config user.name T
    echo "$r seed" > seed.txt; git add seed.txt; git commit -qm seed )
done
# repo-a stays clean; repo-b has WIP
echo wip >> "$HUB/repo-b/seed.txt"

cd "$HUB"
export CLONE_WARS_HOME="$HUB/.clone-wars"

TOPIC=e2e-hub
ART_DIR=$(cw_deploy_art_dir "$TOPIC")
mkdir -p "$ART_DIR"
printf 'rex\t%s/repo-a\tcodex\n'  "$HUB" >  "$ART_DIR/troopers.txt"
printf 'cody\t%s/repo-b\tclaude\n' "$HUB" >> "$ART_DIR/troopers.txt"

# Pre-deploy snapshot
"$PLUGIN_ROOT/bin/deploy-pre-snapshot.sh" "$TOPIC" >/dev/null
assert_file_exists "$ART_DIR/baselines/rex.tsv"
assert_file_exists "$ART_DIR/baselines/cody.tsv"
grep -qE '^state=clean$'         "$ART_DIR/baselines/rex.tsv"
grep -qE '^state=wip-committed$' "$ART_DIR/baselines/cody.tsv"

# Simulate trooper work in each sub-repo
( cd "$HUB/repo-a"; echo work-a > w.txt; git add w.txt; git commit -qm "feat: rex work" )
( cd "$HUB/repo-b"; echo work-b > w.txt; git add w.txt; git commit -qm "feat: cody work" )

# Post-deploy summary
OUT=$("$PLUGIN_ROOT/bin/deploy-summary.sh" "$TOPIC")
assert_contains "$OUT" "═══ rex [$HUB/repo-a] ═══"  "rex block present"
assert_contains "$OUT" "═══ cody [$HUB/repo-b] ═══" "cody block present"
assert_contains "$OUT" "feat: rex work"   "rex commit listed"
assert_contains "$OUT" "feat: cody work"  "cody commit listed"
pass "1. e2e hub-mode: 2 sub-repos → 2 baselines → 2 summary blocks"

echo "test_deploy_ceremony_e2e_hub: 1 case passed"
```

- [ ] **Step 15: Write `tests/test_deploy_branch_pin_lint.sh`**

```bash
#!/usr/bin/env bash
# tests/test_deploy_branch_pin_lint.sh — v0.42.0 PERMANENT LINT
# Asserts the BRANCH DISCIPLINE stanza appears in all three deploy
# prompt builders so the stanza can't silently drift away.
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib/assert.sh

LIB="lib/deploy.sh"
[[ -f "$LIB" ]] || { echo "FAIL: $LIB missing" >&2; exit 1; }

# Extract each builder body (function start → next function start or EOF).
for fn in cw_deploy_build_turn_prompt_round1 cw_deploy_build_turn_prompt_fix cw_deploy_build_dag_unit_prompt; do
  body=$(awk -v fn="$fn" '
    $0 ~ "^"fn"\\(\\) \\{" { p=1 }
    p && /^# cw_deploy_/ && !/^# cw_deploy_build/ { exit }
    p && /^cw_deploy_/ && $0 !~ "^"fn"\\(\\) \\{" { exit }
    p
  ' "$LIB")
  echo "$body" | grep -qE 'BRANCH DISCIPLINE' \
    || { echo "FAIL: $fn missing BRANCH DISCIPLINE stanza" >&2; exit 1; }
  echo "$body" | grep -qE 'Do NOT run .git checkout' \
    || { echo "FAIL: $fn missing 'Do NOT run \`git checkout\`' clause" >&2; exit 1; }
  pass "$fn carries BRANCH DISCIPLINE stanza"
done

echo "test_deploy_branch_pin_lint: 3 builders carry the stanza"
```

- [ ] **Step 16: chmod + verify all 15 fail RED**

```bash
chmod +x tests/test_deploy_iter_targets_single.sh \
         tests/test_deploy_iter_targets_hub.sh \
         tests/test_deploy_pre_snapshot_clean.sh \
         tests/test_deploy_pre_snapshot_dirty.sh \
         tests/test_deploy_pre_snapshot_untracked.sh \
         tests/test_deploy_pre_snapshot_hook_blocked.sh \
         tests/test_deploy_pre_snapshot_detached.sh \
         tests/test_deploy_pre_snapshot_not_a_repo.sh \
         tests/test_deploy_post_sweep_clean.sh \
         tests/test_deploy_post_sweep_dirty.sh \
         tests/test_deploy_post_sweep_branch_changed.sh \
         tests/test_deploy_format_summary_block.sh \
         tests/test_deploy_ceremony_e2e_single.sh \
         tests/test_deploy_ceremony_e2e_hub.sh \
         tests/test_deploy_branch_pin_lint.sh

for t in tests/test_deploy_iter_targets_single.sh tests/test_deploy_pre_snapshot_clean.sh tests/test_deploy_post_sweep_clean.sh tests/test_deploy_format_summary_block.sh tests/test_deploy_ceremony_e2e_single.sh tests/test_deploy_branch_pin_lint.sh; do
  bash "$t" 2>&1 | tail -3
  echo "---"
done
```

Expected: each of those 6 representative tests fails (`cw_deploy_iter_targets: command not found`, `cw_deploy_pre_snapshot: command not found`, etc., and lint fails because the stanza isn't yet present). T2–T6 turn them GREEN one helper at a time.

- [ ] **Step 17: Commit T1 (RED scaffolds)**

```bash
git add tests/test_deploy_iter_targets_*.sh \
        tests/test_deploy_pre_snapshot_*.sh \
        tests/test_deploy_post_sweep_*.sh \
        tests/test_deploy_format_summary_block.sh \
        tests/test_deploy_ceremony_e2e_*.sh \
        tests/test_deploy_branch_pin_lint.sh
git commit -m "$(cat <<'EOF'
test(deploy): v0.42.0 RED scaffolds for git-repo discipline

13 unit/integration tests + 1 permanent lint covering the new
ceremony surface from the v0.42.0 spec:
- iter_targets (single, hub)
- pre_snapshot (clean, dirty, untracked, hook-blocked, detached, not-a-repo)
- post_sweep (clean, dirty, branch_changed)
- format_summary_block
- e2e single-repo and hub-mode ceremony roundtrip
- branch-pin lint (stanza presence in all 3 prompt builders)

All RED at this commit. T2–T6 turn them GREEN as helpers land.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: `cw_deploy_iter_targets` helper

**Files:**
- Modify: `lib/deploy.sh` (append helper after `cw_deploy_resolve_hub`)
- Test: `tests/test_deploy_iter_targets_single.sh`, `tests/test_deploy_iter_targets_hub.sh` (turn GREEN)

- [ ] **Step 1: Read `lib/deploy.sh` (recovery: re-Read if Edit later says modified)**

```bash
wc -l lib/deploy.sh
```

Then Read the file fully in one shot.

- [ ] **Step 2: Append `cw_deploy_iter_targets` to the end of `lib/deploy.sh`**

```bash
# cw_deploy_iter_targets <topic>
# Single source of truth for "which repos does this deploy touch?".
# Emits TSV `<slug>\t<cwd>` rows. Hub mode reads troopers.txt; single-repo
# synthesizes one row with slug 'main' from target_cwd.txt.
# rc=0 always; empty stdout if neither file exists.
cw_deploy_iter_targets() {
  local art
  art="$(cw_deploy_art_dir "$1")"
  if [[ -f "$art/troopers.txt" ]]; then
    awk -F'\t' '{print $1"\t"$2}' "$art/troopers.txt"
  elif [[ -f "$art/target_cwd.txt" ]]; then
    printf 'main\t%s\n' "$(cat "$art/target_cwd.txt")"
  fi
}
```

- [ ] **Step 3: Run the 2 tests to verify GREEN**

```bash
bash tests/test_deploy_iter_targets_single.sh
bash tests/test_deploy_iter_targets_hub.sh
```

Expected: both print `... ok ...` and exit 0.

- [ ] **Step 4: Run full suite to confirm no regressions**

```bash
bash tests/run.sh 2>&1 | tail -10
```

Expected: 0 exit code. (Other T1 RED tests still fail — that's by design until T3–T6.)

- [ ] **Step 5: Commit**

```bash
git add lib/deploy.sh
git commit -m "$(cat <<'EOF'
feat(deploy): add cw_deploy_iter_targets helper (v0.42.0)

One source of truth for "which repos does a deploy touch":
- Hub mode (troopers.txt present) → one row per trooper
- Single-repo (target_cwd.txt present) → synthesized 'main' row

Used by deploy-pre-snapshot.sh and deploy-summary.sh to walk
targets uniformly. Turns 2 RED tests GREEN.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: `cw_deploy_pre_snapshot` helper + `bin/deploy-pre-snapshot.sh`

**Files:**
- Modify: `lib/deploy.sh` (append helper)
- Create: `bin/deploy-pre-snapshot.sh`
- Test: 6 pre_snapshot tests + ceremony_e2e_single (turn GREEN)

- [ ] **Step 1: Append `cw_deploy_pre_snapshot` to `lib/deploy.sh`**

```bash
# cw_deploy_pre_snapshot <target-cwd> <topic> <slug> <baseline-file>
# Pre-deploy ceremony for one target. Writes a TSV baseline file the
# post-deploy phase reads later.
#
# - Dirty tree (modified OR untracked): commits as
#   "chore: WIP before deploy <topic>", baseline.sha = new HEAD,
#   state=wip-committed.
# - Clean tree: no commit, baseline.sha = current HEAD, state=clean.
# - Pre-commit hook blocks the WIP commit: warn, baseline.sha =
#   pre-attempt HEAD, state=hook-blocked, rc=0 (proceed).
# - Detached HEAD: branch field literal "(detached)"; ceremony still
#   runs.
# - Not a git repo: log error, rc=2 (abort entire deploy).
cw_deploy_pre_snapshot() {
  local cwd="$1" topic="$2" slug="$3" baseline="$4"
  local branch pre_sha new_sha state ts dirty
  if ! git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
    log_error "pre_snapshot: not a git repository: $cwd"
    return 2
  fi
  branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null) || branch="(detached)"
  pre_sha=$(git -C "$cwd" rev-parse HEAD 2>/dev/null) || pre_sha=""
  dirty=$(git -C "$cwd" status --porcelain)
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if [[ -z "$dirty" ]]; then
    state=clean
    new_sha="$pre_sha"
  else
    if git -C "$cwd" add -A \
        && git -C "$cwd" commit -m "chore: WIP before deploy $topic" -q; then
      state=wip-committed
      new_sha=$(git -C "$cwd" rev-parse HEAD)
    else
      log_warn "pre_snapshot: commit hook blocked WIP commit in $cwd; baseline = pre-attempt HEAD"
      state=hook-blocked
      new_sha="$pre_sha"
    fi
  fi
  {
    printf 'slug=%s\n'         "$slug"
    printf 'cwd=%s\n'          "$cwd"
    printf 'branch=%s\n'       "$branch"
    printf 'baseline_sha=%s\n' "$new_sha"
    printf 'state=%s\n'        "$state"
    printf 'snapshot_ts=%s\n'  "$ts"
  } | cw_atomic_write "$baseline"
}
```

- [ ] **Step 2: Run the 6 unit tests to verify GREEN**

```bash
for t in clean dirty untracked hook_blocked detached not_a_repo; do
  bash "tests/test_deploy_pre_snapshot_${t}.sh"
done
```

Expected: all 6 print `... ok ...` and exit 0.

- [ ] **Step 3: Create `bin/deploy-pre-snapshot.sh`**

```bash
#!/usr/bin/env bash
# bin/deploy-pre-snapshot.sh <topic>
# Walks cw_deploy_iter_targets <topic> and calls cw_deploy_pre_snapshot
# per row, writing baselines under $ART_DIR/baselines/<slug>.tsv.
#
# Exits 0 even when individual targets hit hook-blocked warnings; exits
# 2 when any target is not a git repo (pre_snapshot returns 2).
set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deploy.sh"

[[ $# -eq 1 ]] || { echo "Usage: $0 <topic>" >&2; exit 2; }
TOPIC="$1"
cw_deploy_assert_topic "$TOPIC"

ART_DIR=$(cw_deploy_art_dir "$TOPIC")
[[ -d "$ART_DIR" ]] || { log_error "art-dir missing: $ART_DIR (run deploy-init.sh first)"; exit 1; }
mkdir -p "$ART_DIR/baselines"

count_clean=0; count_committed=0; count_blocked=0
while IFS=$'\t' read -r slug cwd; do
  [[ -n "$slug" && -n "$cwd" ]] || continue
  baseline="$ART_DIR/baselines/$slug.tsv"
  if ! cw_deploy_pre_snapshot "$cwd" "$TOPIC" "$slug" "$baseline"; then
    log_error "pre_snapshot failed for slug=$slug cwd=$cwd"
    exit 2
  fi
  state=$(grep -E '^state=' "$baseline" | head -1 | cut -d= -f2)
  case "$state" in
    clean)         count_clean=$(( count_clean + 1 )) ;;
    wip-committed) count_committed=$(( count_committed + 1 )) ;;
    hook-blocked)  count_blocked=$(( count_blocked + 1 )) ;;
  esac
done < <(cw_deploy_iter_targets "$TOPIC")

log_ok "pre-snapshot: $count_clean clean, $count_committed committed, $count_blocked hook-blocked"
```

- [ ] **Step 4: chmod + run e2e single-repo test**

```bash
chmod +x bin/deploy-pre-snapshot.sh
bash tests/test_deploy_ceremony_e2e_single.sh
```

Expected: e2e_single still partially fails because `bin/deploy-summary.sh` doesn't yet exist; the snapshot portion (`assert_file_exists "$ART_DIR/baselines/main.tsv"`) should now pass.

If you want to confirm just the pre-snapshot portion in isolation, extract those lines into an inline check:

```bash
SANDBOX=$(mktemp -d) && cd "$SANDBOX" && git init -q -b main \
  && git config user.email t@t && git config user.name T \
  && echo c > seed.txt && git add seed.txt && git commit -qm seed \
  && export CLONE_WARS_HOME="$SANDBOX/.clone-wars" \
  && ART=$(cd /home/liupan/CC/clone-wars && source lib/log.sh && source lib/state.sh && source lib/deploy.sh && cw_deploy_art_dir prelocal) \
  && mkdir -p "$ART" && echo "$SANDBOX" > "$ART/target_cwd.txt" \
  && CLAUDE_PLUGIN_ROOT=/home/liupan/CC/clone-wars /home/liupan/CC/clone-wars/bin/deploy-pre-snapshot.sh prelocal \
  && ls "$ART/baselines/" && rm -rf "$SANDBOX"
```

Expected: `main.tsv` listed in the final `ls`.

- [ ] **Step 5: Run full suite (e2e tests still RED is OK; everything else GREEN)**

```bash
bash tests/run.sh 2>&1 | tail -15
```

Expected: only `test_deploy_ceremony_e2e_*.sh` and `test_deploy_branch_pin_lint.sh` and a few sweep/format tests still fail. T4–T6 will close those.

- [ ] **Step 6: Commit**

```bash
git add lib/deploy.sh bin/deploy-pre-snapshot.sh
git commit -m "$(cat <<'EOF'
feat(deploy): cw_deploy_pre_snapshot + bin/deploy-pre-snapshot.sh (v0.42.0)

Per-target pre-deploy ceremony:
- Dirty tree → commit as "chore: WIP before deploy <topic>"
- Clean → no commit, baseline = current HEAD
- Hook-blocked → warn + state=hook-blocked, rc=0 (proceed)
- Detached HEAD → branch="(detached)", proceed
- Not a git repo → rc=2 abort

bin/deploy-pre-snapshot.sh walks cw_deploy_iter_targets and writes
baselines under $ART_DIR/baselines/<slug>.tsv. Turns 6 RED tests GREEN.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: BRANCH DISCIPLINE stanza in 3 prompt builders + lint GREEN

**Files:**
- Modify: `lib/deploy.sh` — append stanza to `cw_deploy_build_turn_prompt_round1`, `cw_deploy_build_turn_prompt_fix`, `cw_deploy_build_dag_unit_prompt`
- Test: `tests/test_deploy_branch_pin_lint.sh` (turn GREEN)

- [ ] **Step 1: Re-Read `lib/deploy.sh` (recovery if Edit later complains)**

```bash
wc -l lib/deploy.sh
```

Then Read the three prompt builders specifically (the bodies are quoted in spec §Components).

- [ ] **Step 2: Modify `cw_deploy_build_turn_prompt_round1` — add stanza before the heredoc closes**

Locate the heredoc inside `cw_deploy_build_turn_prompt_round1` that begins `cat <<EOF` and ends `END_OF_INSTRUCTION\nEOF`. Insert this block immediately BEFORE `END_OF_INSTRUCTION`:

```bash
BRANCH DISCIPLINE (hard rule):
- You are operating on the conductor's current branch in the target
  repository. Do NOT run \`git checkout\`, \`git switch\`,
  \`git branch -m\`, or create new branches.
- Commit per task with Conventional Commits prefixes on the current
  branch (rule already stated above).
- If your work genuinely needs a fresh branch, abort with
  {"event":"error","reason":"branch-discipline: needed new branch"}
  and let the conductor decide.

```

(Note the backticks need to be escaped — `\`git checkout\`` — because the surrounding `cat <<EOF` is unquoted and would otherwise interpret them as command substitution.)

- [ ] **Step 3: Modify `cw_deploy_build_turn_prompt_fix` — same insertion**

Same stanza, inserted before `END_OF_INSTRUCTION` in the fix-round heredoc.

- [ ] **Step 4: Modify `cw_deploy_build_dag_unit_prompt` — same insertion (with branch+cwd interpolated)**

Same stanza inserted before `END_OF_INSTRUCTION`. In this builder the trooper's cwd is the per-sub-repo cwd, so reference it explicitly:

```bash
BRANCH DISCIPLINE (hard rule):
- You are operating on the current branch in sub-repo "$slug". Do
  NOT run \`git checkout\`, \`git switch\`, \`git branch -m\`, or
  create new branches.
- Commit per task with Conventional Commits prefixes on the current
  branch.
- If your work genuinely needs a fresh branch, abort with
  {"event":"error","reason":"branch-discipline: needed new branch"}
  and let the conductor decide.

```

- [ ] **Step 5: Run the lint test to verify GREEN**

```bash
bash tests/test_deploy_branch_pin_lint.sh
```

Expected: all 3 builders pass, prints `test_deploy_branch_pin_lint: 3 builders carry the stanza`.

- [ ] **Step 6: Run full suite to confirm no regressions in prompt-builder consumers**

```bash
bash tests/run.sh 2>&1 | tail -15
```

Expected: 0 exit code; specifically check that `test_deploy_build_dag_unit_prompt.sh` still passes (it asserts the existing prompt shape; the new stanza is appended, not replacing existing content).

If `test_deploy_build_dag_unit_prompt.sh` fails because it asserts specific prompt-length or absent-content invariants, update its assertions to match the new shape in the same commit.

- [ ] **Step 7: Commit**

```bash
git add lib/deploy.sh
git commit -m "$(cat <<'EOF'
feat(deploy): add BRANCH DISCIPLINE stanza to all prompt builders (v0.42.0)

Trooper-side enforcement of v0.42.0's "stay on the conductor's current
branch" rule. Stanza appended to:
- cw_deploy_build_turn_prompt_round1
- cw_deploy_build_turn_prompt_fix
- cw_deploy_build_dag_unit_prompt

Instruction-only (honor-system); violations are detected by the
post-deploy summary (branch_changed=true → WARNING in block) but do
not abort the deploy.

test_deploy_branch_pin_lint goes GREEN at this commit; the lint
prevents the stanza from silently drifting away.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: `cw_deploy_post_sweep` + `cw_deploy_format_summary_block`

**Files:**
- Modify: `lib/deploy.sh` (append 2 helpers)
- Test: `tests/test_deploy_post_sweep_clean.sh`, `tests/test_deploy_post_sweep_dirty.sh`, `tests/test_deploy_post_sweep_branch_changed.sh`, `tests/test_deploy_format_summary_block.sh` (turn GREEN)

- [ ] **Step 1: Append `cw_deploy_post_sweep` to `lib/deploy.sh`**

```bash
# cw_deploy_post_sweep <baseline-file> <topic> <post-file>
# Mirror of cw_deploy_pre_snapshot for the post-deploy phase. Reads
# the baseline TSV to find target cwd; runs the sweep; writes the
# post TSV.
#
# - Dirty tree (leftover trooper work): commit as
#   "chore: post-deploy leftovers for <topic>", state=swept.
# - Clean: no commit, state=no-leftovers.
# - Hook-blocked: warn, state=sweep-failed, rc=0 (deploy still completes).
# - branch_changed = (baseline.branch != current.branch), bool.
# Always rc=0.
cw_deploy_post_sweep() {
  local baseline="$1" topic="$2" post="$3"
  local cwd slug base_branch dirty state ts post_branch post_sha changed
  cwd=$(grep -E '^cwd=' "$baseline" | head -1 | cut -d= -f2-)
  slug=$(grep -E '^slug=' "$baseline" | head -1 | cut -d= -f2-)
  base_branch=$(grep -E '^branch=' "$baseline" | head -1 | cut -d= -f2-)
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  post_branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null) || post_branch="(detached)"
  dirty=$(git -C "$cwd" status --porcelain)
  if [[ -z "$dirty" ]]; then
    state=no-leftovers
  else
    if git -C "$cwd" add -A \
        && git -C "$cwd" commit -m "chore: post-deploy leftovers for $topic" -q; then
      state=swept
    else
      log_warn "post_sweep: commit hook blocked sweep in $cwd"
      state=sweep-failed
    fi
  fi
  post_sha=$(git -C "$cwd" rev-parse HEAD 2>/dev/null) || post_sha=""
  if [[ "$base_branch" == "$post_branch" ]]; then
    changed=false
  else
    changed=true
  fi
  {
    printf 'slug=%s\n'           "$slug"
    printf 'cwd=%s\n'            "$cwd"
    printf 'branch=%s\n'         "$post_branch"
    printf 'post_sha=%s\n'       "$post_sha"
    printf 'state=%s\n'          "$state"
    printf 'branch_changed=%s\n' "$changed"
    printf 'sweep_ts=%s\n'       "$ts"
  } | cw_atomic_write "$post"
}
```

- [ ] **Step 2: Run the 3 sweep tests to verify GREEN**

```bash
bash tests/test_deploy_post_sweep_clean.sh
bash tests/test_deploy_post_sweep_dirty.sh
bash tests/test_deploy_post_sweep_branch_changed.sh
```

Expected: all 3 print `... 1 case passed`.

- [ ] **Step 3: Append `cw_deploy_format_summary_block` to `lib/deploy.sh`**

```bash
# cw_deploy_format_summary_block <baseline-file> <post-file>
# Pure formatter — reads baseline + post TSVs and prints one per-repo
# block to stdout. No git calls inside (input-driven for unit-testability).
# Always rc=0.
cw_deploy_format_summary_block() {
  local baseline="$1" post="$2"
  local slug cwd base_branch baseline_sha base_state post_branch post_sha post_state changed
  slug=$(grep -E '^slug=' "$baseline"           | head -1 | cut -d= -f2-)
  cwd=$(grep -E '^cwd=' "$baseline"             | head -1 | cut -d= -f2-)
  base_branch=$(grep -E '^branch=' "$baseline"  | head -1 | cut -d= -f2-)
  baseline_sha=$(grep -E '^baseline_sha=' "$baseline" | head -1 | cut -d= -f2-)
  base_state=$(grep -E '^state=' "$baseline"    | head -1 | cut -d= -f2-)
  post_branch=$(grep -E '^branch=' "$post"      | head -1 | cut -d= -f2-)
  post_sha=$(grep -E '^post_sha=' "$post"       | head -1 | cut -d= -f2-)
  post_state=$(grep -E '^state=' "$post"        | head -1 | cut -d= -f2-)
  changed=$(grep -E '^branch_changed=' "$post"  | head -1 | cut -d= -f2-)

  printf '═══ %s [%s] ═══\n' "$slug" "$cwd"
  # WARNING lines (above the branch field)
  if [[ "$changed" == "true" ]]; then
    printf '  [WARNING: branch changed from %s to %s]\n' "$base_branch" "$post_branch"
  fi
  if [[ "$base_state" == "hook-blocked" ]]; then
    printf '  [WARNING: pre-deploy snapshot hook-blocked; baseline = pre-attempt HEAD]\n'
  fi
  if [[ "$post_state" == "sweep-failed" ]]; then
    printf '  [WARNING: post-deploy sweep hook-blocked; leftovers remain in working tree]\n'
  fi
  if [[ "$base_branch" == "(detached)" ]]; then
    printf '  [WARNING: baseline branch detached]\n'
  fi
  printf '  branch:     %s\n' "$post_branch"
  printf '  baseline:   %s   %s   (%s)\n' "$baseline_sha" "$base_branch" "$base_state"
  printf '  HEAD:       %s   %s\n' "$post_sha" "$post_branch"
  local stat
  stat=$(git -C "$cwd" diff --shortstat "$baseline_sha..HEAD" 2>/dev/null | sed -E 's/^[[:space:]]+//')
  if [[ -n "$stat" ]]; then
    printf '  diff stat:  %s\n' "$stat"
  else
    printf '  diff stat:  (no changes since baseline)\n'
  fi
  printf '  commits (oldest → newest):\n'
  local commits
  commits=$(git -C "$cwd" log --reverse --oneline "$baseline_sha..HEAD" 2>/dev/null)
  if [[ -n "$commits" ]]; then
    printf '%s\n' "$commits" | sed -E 's/^/    /'
  else
    printf '    (no commits since baseline)\n'
  fi
}
```

- [ ] **Step 4: Run the format test to verify GREEN**

```bash
bash tests/test_deploy_format_summary_block.sh
```

Expected: prints `... 1 case passed`.

- [ ] **Step 5: Run full suite**

```bash
bash tests/run.sh 2>&1 | tail -15
```

Expected: only `test_deploy_ceremony_e2e_*.sh` still RED. T6 closes them.

- [ ] **Step 6: Commit**

```bash
git add lib/deploy.sh
git commit -m "$(cat <<'EOF'
feat(deploy): cw_deploy_post_sweep + cw_deploy_format_summary_block (v0.42.0)

Post-deploy half of the ceremony:
- post_sweep — mirror of pre_snapshot; commits leftover trooper work
  as "chore: post-deploy leftovers for <topic>", records branch_changed
  vs baseline, warns on hook-blocked.
- format_summary_block — pure formatter; reads baseline + post TSVs
  and prints the documented per-repo block (header, WARNING lines,
  branch/baseline/HEAD fields, diff stat, commits list).

Turns 4 RED tests GREEN.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: `bin/deploy-summary.sh` + e2e tests GREEN

**Files:**
- Create: `bin/deploy-summary.sh`
- Test: `tests/test_deploy_ceremony_e2e_single.sh`, `tests/test_deploy_ceremony_e2e_hub.sh` (turn GREEN)

- [ ] **Step 1: Create `bin/deploy-summary.sh`**

```bash
#!/usr/bin/env bash
# bin/deploy-summary.sh <topic>
# Walks cw_deploy_iter_targets <topic>, calls cw_deploy_post_sweep for
# each row (writes $ART_DIR/posts/<slug>.tsv), then prints one
# cw_deploy_format_summary_block per row to stdout.
#
# Exits 0 unless a per-target step itself errors fatally (e.g. baseline
# file missing for a known target).
set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deploy.sh"

[[ $# -eq 1 ]] || { echo "Usage: $0 <topic>" >&2; exit 2; }
TOPIC="$1"
cw_deploy_assert_topic "$TOPIC"

ART_DIR=$(cw_deploy_art_dir "$TOPIC")
[[ -d "$ART_DIR" ]] || { log_error "art-dir missing: $ART_DIR"; exit 1; }
mkdir -p "$ART_DIR/posts"

while IFS=$'\t' read -r slug cwd; do
  [[ -n "$slug" && -n "$cwd" ]] || continue
  baseline="$ART_DIR/baselines/$slug.tsv"
  post="$ART_DIR/posts/$slug.tsv"
  if [[ ! -f "$baseline" ]]; then
    log_error "summary: baseline missing for slug=$slug ($baseline)"
    continue
  fi
  if [[ ! -d "$cwd" ]]; then
    log_warn "summary: target gone for slug=$slug (cwd=$cwd); omitting block"
    continue
  fi
  cw_deploy_post_sweep "$baseline" "$TOPIC" "$post"
  cw_deploy_format_summary_block "$baseline" "$post"
  printf '\n'
done < <(cw_deploy_iter_targets "$TOPIC")
```

- [ ] **Step 2: chmod + run both e2e tests**

```bash
chmod +x bin/deploy-summary.sh
bash tests/test_deploy_ceremony_e2e_single.sh
bash tests/test_deploy_ceremony_e2e_hub.sh
```

Expected: both print `... 1 case passed`.

- [ ] **Step 3: Run full suite to confirm everything GREEN except the directive surgery tests (T7 next)**

```bash
bash tests/run.sh 2>&1 | tail -15
```

Expected: only pre-existing tests asserting the old rc=7 default behavior or 5a Stash/Commit/Abort options should be failing now. Those get migrated in T7.

If anything else is failing, stop and diagnose before T7 — drift means a helper is wrong.

- [ ] **Step 4: Commit**

```bash
git add bin/deploy-summary.sh
git commit -m "$(cat <<'EOF'
feat(deploy): bin/deploy-summary.sh for per-repo post-deploy summary (v0.42.0)

Walks cw_deploy_iter_targets <topic>, calls cw_deploy_post_sweep per
row (writing $ART_DIR/posts/<slug>.tsv), and prints one
cw_deploy_format_summary_block per row to stdout. Single-repo prints
one block ('main'); hub mode prints N blocks back-to-back in
troopers.txt order.

Turns the e2e single-repo and hub-mode ceremony tests GREEN.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Directive surgery + `bin/deploy-init.sh` rc=7 gating + test migration

**Files:**
- Modify: `commands/deploy.md` — Step 0 sub-step 5 (default `--no-branch` when `--branch` not present), 5a removal, NEW sub-step 6 (pre-snapshot invocation); Step 4 NEW sub-step (summary invocation before archive)
- Modify: `bin/deploy-init.sh` — gate rc=7 path behind `--branch` flag presence
- Modify: `tests/test_deploy_init_dirty_tree_rc7.sh` — restructure: rc=7 only fires when `--branch` flag passed
- Delete: `tests/test_deploy_dirty_intercept_directive.sh` (locks the old 5a AskUserQuestion shape, replaced by new directive shape)

- [ ] **Step 1: Re-Read `bin/deploy-init.sh` and `commands/deploy.md` Step 0 + Step 4**

```bash
wc -l bin/deploy-init.sh commands/deploy.md
```

Already Read both during brainstorm; if Edit complains about "modified since read", Re-Read the relevant sections.

- [ ] **Step 2: Edit `bin/deploy-init.sh` to detect `--branch` flag and gate the auto-branch path**

In the argv parser block (`while [[ $# -gt 0 ]]; do case "$1" in`), confirm `--branch` is already captured into `BRANCH_OVERRIDE` (it is, line 41-42). The gate is the existing `if (( NO_BRANCH == 0 )); then` block at line 121. Change that to also require `BRANCH_OVERRIDE` to be set:

OLD (line 121):
```bash
if (( NO_BRANCH == 0 )); then
```

NEW:
```bash
if (( NO_BRANCH == 0 )) && [[ -n "$BRANCH_OVERRIDE" ]]; then
```

This means: branch creation only happens when the caller explicitly passes `--branch <name>`. The default (no `--branch`, no `--no-branch`) is "stay on current branch".

- [ ] **Step 3: Migrate `tests/test_deploy_init_dirty_tree_rc7.sh`**

Open the file and rewrite the 6 cases so that:
- Cases 1-4 (lib-level `cw_deploy_branch_create` direct tests) stay unchanged — that helper still returns 7 on dirty tree as before.
- Case 6 (init.sh propagation) changes to pass `--branch dirty-init-branch` so the gate engages:

OLD (line 101):
```bash
out=$("$PLUGIN_ROOT/bin/deploy-init.sh" --topic dirty-init "$SPEC" 2>&1); rc=$?
```

NEW:
```bash
# v0.42.0: rc=7 only fires when --branch flag is present (opt-in sandbox-branch mode).
out=$("$PLUGIN_ROOT/bin/deploy-init.sh" --topic dirty-init --branch sandbox-branch "$SPEC" 2>&1); rc=$?
```

Also update the case-6 `pass` message to reflect the gate:

OLD:
```bash
pass "6. bin/deploy-init.sh propagates rc=7 from branch_create"
```

NEW:
```bash
pass "6. bin/deploy-init.sh propagates rc=7 from branch_create when --branch is passed"
```

- [ ] **Step 4: Delete `tests/test_deploy_dirty_intercept_directive.sh`**

This test locks the old 5a AskUserQuestion shape (`Stash and continue` / `Commit first` options) which we're removing. The new directive shape gets asserted by `test_v0_42_0_static_wiring.sh` (T8) instead.

```bash
git rm tests/test_deploy_dirty_intercept_directive.sh
```

- [ ] **Step 5: Edit `commands/deploy.md` Step 0 sub-step 5 — default-pass `--no-branch` when `--branch` not present**

Locate sub-step 5's init invocation (around line 110-125 per the existing Read). Wrap the init invocation with a Bash-side flag check:

OLD (the block starting at line 114 `TOPIC=$("${CLAUDE_PLUGIN_ROOT}/bin/deploy-init.sh" \`):
```
   TOPIC=$("${CLAUDE_PLUGIN_ROOT}/bin/deploy-init.sh" \
              --args-file "$ARGS_FILE" 2>"$RUN_DIR/init-err") \
              && INIT_RC=0 || INIT_RC=$?
```

NEW:
```
   # v0.42.0: default = stay on current branch. If the args file does
   # NOT contain --branch, pass --no-branch explicitly so init.sh
   # skips the auto-branch path.
   if grep -qE '(^|[[:space:]])--branch([[:space:]]|$)' "$ARGS_FILE"; then
     EXTRA_INIT_FLAG=""
   else
     EXTRA_INIT_FLAG="--no-branch"
   fi
   TOPIC=$("${CLAUDE_PLUGIN_ROOT}/bin/deploy-init.sh" $EXTRA_INIT_FLAG \
              --args-file "$ARGS_FILE" 2>"$RUN_DIR/init-err") \
              && INIT_RC=0 || INIT_RC=$?
```

- [ ] **Step 6: Edit `commands/deploy.md` Step 0 sub-step 5 — remove 5a + the `INIT_RC == 7` branch**

The dirty-tree intercept block (sub-step 5a, lines ~133-201 per current shape) is gone. The directive should no longer reference `INIT_RC == 7`, `Stash and continue`, `Commit first as chore: WIP`, `pre-deploy-stash.txt`, or `pre-deploy-commit.txt`.

Remove the explanatory text immediately preceding 5a (the paragraph starting "When `INIT_RC == 7`, run sub-step 5a (dirty-tree intercept, v0.30.0…").

Keep the `INIT_RC != 0 && INIT_RC != 7` → 5b (DAG rescue) branch — that path is unrelated to dirty-tree.

After removal, sub-step 5 should branch cleanly:
- `INIT_RC == 0` → continue to new sub-step 6
- `INIT_RC != 0` → run sub-step 5b (DAG rescue)

- [ ] **Step 7: Edit `commands/deploy.md` Step 0 — insert NEW sub-step 6 (pre-snapshot invocation)**

Insert immediately after the (now simplified) sub-step 5 and BEFORE Step 1:

```markdown
6. **Pre-deploy snapshot (v0.42.0).** Walk every target repo touched by
   this deploy and commit WIP as a `chore: WIP before deploy <topic>`
   commit per target. Baselines land at
   `$ART_DIR/baselines/<slug>.tsv` for both single-repo (slug=`main`)
   and hub mode (one slug per `troopers.txt` row). Hook-blocked
   commits log a warning and proceed; only "target is not a git repo"
   aborts.

   ```
   source "${CLAUDE_PLUGIN_ROOT}/lib/log.sh"
   "${CLAUDE_PLUGIN_ROOT}/bin/deploy-pre-snapshot.sh" "$TOPIC" \
     || { log_error "pre-snapshot aborted"; exit 1; }
   ```
```

- [ ] **Step 8: Edit `commands/deploy.md` Step 4 — insert NEW sub-step (summary invocation) BEFORE archive**

Step 4 currently starts at line 1188 and ends with the `deploy-archive.sh` invocation. Insert this NEW sub-step immediately BEFORE the archive call:

```markdown
**Per-repo summary (v0.42.0).** Print one summary block per target
repo: branch, baseline SHA, HEAD SHA, diff stat, and commit list.
Hub-mode prints N blocks back-to-back; single-repo prints one block
labeled `main`.

```
"${CLAUDE_PLUGIN_ROOT}/bin/deploy-summary.sh" "$TOPIC"
```
```

The summary output goes to chat verbatim — Yoda surfaces it to the user as-is (no further formatting needed).

- [ ] **Step 9: Run the full suite**

```bash
bash tests/run.sh 2>&1 | tail -25
```

Expected: 0 exit code. All new tests GREEN. `test_deploy_init_dirty_tree_rc7.sh` GREEN with its case-6 patch. `test_deploy_dirty_intercept_directive.sh` is gone.

If any directive-shape test fails because it asserts old prose ("Stash and continue", "5a", "pre-deploy-stash.txt"), update that test to match the new directive shape in this same commit.

- [ ] **Step 10: Commit**

```bash
git add commands/deploy.md bin/deploy-init.sh tests/test_deploy_init_dirty_tree_rc7.sh
git rm tests/test_deploy_dirty_intercept_directive.sh
git commit -m "$(cat <<'EOF'
refactor(deploy): default to current branch + wire snapshot/summary into directive (v0.42.0)

bin/deploy-init.sh:
- Gate the auto-branch path behind --branch flag presence; default
  invocations no longer create feat/deploy-<topic>.

commands/deploy.md:
- Step 0 sub-step 5: pass --no-branch when --branch is absent from
  args (default = stay on current branch).
- Sub-step 5a (Stash/Commit/Abort AskUserQuestion) and the
  INIT_RC == 7 branch removed. Dirty trees are now handled by the
  unconditional pre-snapshot ceremony in new sub-step 6.
- New sub-step 6: invoke bin/deploy-pre-snapshot.sh "$TOPIC" after
  init succeeds.
- Step 4: invoke bin/deploy-summary.sh "$TOPIC" before archive.

Tests:
- test_deploy_init_dirty_tree_rc7: case 6 now passes --branch so
  the rc=7 propagation gate engages.
- test_deploy_dirty_intercept_directive: removed (locked the old
  5a shape, replaced by new directive shape covered by the v0.42.0
  static-wiring lock in T8).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Static-wiring lock scaffold (skip-guarded at 0.42.0)

**Files:**
- Create: `tests/test_v0_42_0_static_wiring.sh`

T8 scaffolds the version-stamped invariant lock. It passes via SKIP at this commit because `plugin.json` is still `0.41.0`. T9 bumps the version and the lock activates.

- [ ] **Step 1: Write `tests/test_v0_42_0_static_wiring.sh`**

```bash
#!/usr/bin/env bash
# tests/test_v0_42_0_static_wiring.sh
# Version-stamped static-wiring lock for v0.42.0. Skip-guards when
# plugin.json is not at 0.42.0 (so it passes via skip during v0.41.x
# work). Activates and locks 8 invariants when version matches.
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib/assert.sh

PLUGIN_JSON=".claude-plugin/plugin.json"
[[ -f "$PLUGIN_JSON" ]] || { echo "FAIL: $PLUGIN_JSON missing" >&2; exit 1; }

CURRENT_VERSION=$(grep -E '"version"' "$PLUGIN_JSON" | head -1 \
  | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')

if [[ "$CURRENT_VERSION" != "0.42.0" ]]; then
  echo "SKIP: plugin.json version $CURRENT_VERSION != 0.42.0 (v0.42.0 invariants inactive)"
  exit 0
fi

# Invariant 1: marketplace.json both version lines = 0.42.0
MKT=".claude-plugin/marketplace.json"
MKT_HITS=$(grep -cE '"version"[[:space:]]*:[[:space:]]*"0\.42\.0"' "$MKT")
[[ "$MKT_HITS" -ge 2 ]] \
  || { echo "FAIL: marketplace.json should have ≥2 lines reading version 0.42.0 (got $MKT_HITS)" >&2; exit 1; }
pass "1. plugin.json + marketplace.json both at 0.42.0"

# Invariant 2: lib/deploy.sh exports all 4 new helpers
LIB="lib/deploy.sh"
for fn in cw_deploy_iter_targets cw_deploy_pre_snapshot cw_deploy_post_sweep cw_deploy_format_summary_block; do
  grep -qE "^$fn\(\)[[:space:]]*\{" "$LIB" \
    || { echo "FAIL: $LIB missing helper $fn" >&2; exit 1; }
done
pass "2. lib/deploy.sh exports iter_targets + pre_snapshot + post_sweep + format_summary_block"

# Invariant 3: BRANCH DISCIPLINE stanza in all 3 prompt builders
# (covered by test_deploy_branch_pin_lint too — duplicated here for static lock)
for fn in cw_deploy_build_turn_prompt_round1 cw_deploy_build_turn_prompt_fix cw_deploy_build_dag_unit_prompt; do
  body=$(awk -v fn="$fn" '
    $0 ~ "^"fn"\\(\\) \\{" { p=1 }
    p && /^# cw_deploy_/ && !/^# cw_deploy_build/ { exit }
    p && /^cw_deploy_/ && $0 !~ "^"fn"\\(\\) \\{" { exit }
    p
  ' "$LIB")
  echo "$body" | grep -qE 'BRANCH DISCIPLINE' \
    || { echo "FAIL: $fn missing BRANCH DISCIPLINE stanza" >&2; exit 1; }
done
pass "3. all 3 prompt builders carry BRANCH DISCIPLINE stanza"

# Invariant 4: commands/deploy.md invokes deploy-pre-snapshot.sh exactly once in Step 0
DIRECTIVE="commands/deploy.md"
STEP0=$(awk '/^### Step 0/,/^### Step 1/' "$DIRECTIVE")
PRE_HITS=$(echo "$STEP0" | grep -cE 'deploy-pre-snapshot\.sh')
[[ "$PRE_HITS" -eq 1 ]] \
  || { echo "FAIL: Step 0 should invoke deploy-pre-snapshot.sh exactly once (got $PRE_HITS)" >&2; exit 1; }
pass "4. commands/deploy.md Step 0 invokes deploy-pre-snapshot.sh exactly once"

# Invariant 5: commands/deploy.md invokes deploy-summary.sh exactly once in Step 4 (before archive)
STEP4=$(awk '/^### Step 4/,0' "$DIRECTIVE")
SUM_HITS=$(echo "$STEP4" | grep -cE 'deploy-summary\.sh')
[[ "$SUM_HITS" -eq 1 ]] \
  || { echo "FAIL: Step 4 should invoke deploy-summary.sh exactly once (got $SUM_HITS)" >&2; exit 1; }
pass "5. commands/deploy.md Step 4 invokes deploy-summary.sh exactly once"

# Invariant 6: legacy 5a AskUserQuestion options must NOT appear anywhere in directive
! grep -qE 'Stash and continue' "$DIRECTIVE" \
  || { echo "FAIL: directive still references 'Stash and continue' (v0.42.0 removed sub-step 5a)" >&2; exit 1; }
! grep -qE 'pre-deploy-stash\.txt' "$DIRECTIVE" \
  || { echo "FAIL: directive still references pre-deploy-stash.txt (v0.42.0 dropped stash machinery)" >&2; exit 1; }
pass "6. commands/deploy.md does NOT contain legacy 5a AskUserQuestion options"

# Invariant 7: bin/deploy-init.sh gates rc=7 behind --branch flag (BRANCH_OVERRIDE)
INIT="bin/deploy-init.sh"
grep -qE 'NO_BRANCH == 0.*BRANCH_OVERRIDE|BRANCH_OVERRIDE.*NO_BRANCH == 0' "$INIT" \
  || { echo "FAIL: bin/deploy-init.sh should gate branch_create behind BRANCH_OVERRIDE presence" >&2; exit 1; }
pass "7. bin/deploy-init.sh gates auto-branch path behind --branch flag"

# Invariant 8: CLAUDE.md Current focus names v0.42.0
grep -qE 'Most recent merge:.*v0\.42\.0' CLAUDE.md \
  || { echo "FAIL: CLAUDE.md Current focus should name v0.42.0" >&2; exit 1; }
pass "8. CLAUDE.md Current focus names v0.42.0"

pass "test_v0_42_0_static_wiring: 8 invariants locked"
```

- [ ] **Step 2: chmod + verify it passes via SKIP at current 0.41.0 version**

```bash
chmod +x tests/test_v0_42_0_static_wiring.sh
bash tests/test_v0_42_0_static_wiring.sh
```

Expected: prints `SKIP: plugin.json version 0.41.0 != 0.42.0 (v0.42.0 invariants inactive)` and exits 0.

- [ ] **Step 3: Run full suite (still GREEN — skip-guarded)**

```bash
bash tests/run.sh 2>&1 | tail -10
```

Expected: 0 exit code.

- [ ] **Step 4: Commit**

```bash
git add tests/test_v0_42_0_static_wiring.sh
git commit -m "$(cat <<'EOF'
chore(release): scaffold v0.42.0 static-wiring lock

8 invariants for the v0.42.0 deploy git-repo discipline:
1. plugin.json + marketplace.json both at 0.42.0
2. lib/deploy.sh exports all 4 new helpers
3. all 3 prompt builders carry BRANCH DISCIPLINE stanza
4. commands/deploy.md Step 0 invokes deploy-pre-snapshot.sh once
5. commands/deploy.md Step 4 invokes deploy-summary.sh once
6. legacy 5a AskUserQuestion options removed from directive
7. bin/deploy-init.sh gates auto-branch behind --branch flag
8. CLAUDE.md Current focus names v0.42.0

Skip-guarded at plugin.json version 0.42.0; passes via SKIP at
this commit (version still 0.41.0). Activates and locks invariants
when T9 bumps the version.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Version bump + CHANGELOG + CLAUDE.md (static-wiring activates)

**Files:**
- Modify: `.claude-plugin/plugin.json` (version `0.41.0` → `0.42.0`)
- Modify: `.claude-plugin/marketplace.json` (both version lines → `0.42.0`)
- Modify: `CLAUDE.md` (Current focus rewrite naming v0.42.0)
- Modify: `docs/CHANGELOG.md` (prepend v0.42.0 entry)

- [ ] **Step 1: Read both JSON files (Read-before-Edit)**

```bash
wc -l .claude-plugin/plugin.json .claude-plugin/marketplace.json
```

Then Read both. (Both are short; full Read is fine.)

- [ ] **Step 2: Edit `.claude-plugin/plugin.json`**

OLD:
```json
  "version": "0.41.0",
```

NEW:
```json
  "version": "0.42.0",
```

- [ ] **Step 3: Edit `.claude-plugin/marketplace.json` (2 occurrences)**

Both lines containing `"version": "0.41.0"` → `"version": "0.42.0"`. The file has two version fields (one inside `plugins[0]`, one at the top level — see lines 13 and 29 of the current file).

Use `replace_all: true` on the single string `"version": "0.41.0"` since the Edit will be unique to that file.

- [ ] **Step 4: Read `CLAUDE.md` (Read-before-Edit)**

```bash
wc -l CLAUDE.md
```

Then Read.

- [ ] **Step 5: Edit `CLAUDE.md` "Current focus" section**

Locate the three-bullet `## Current focus` block. Replace with:

```markdown
## Current focus

- **Most recent merge:** v0.42.0 (deploy git-repo discipline — stay
  on current branch, pre-deploy WIP snapshot + post-deploy sweep per
  target repo, per-repo summary block at Step 4; opt-in
  feat/deploy-<topic> sandbox via `--branch`).
- **Next priority:** strict-dogfood passes for v0.31.0 through v0.42.0
  (release-gate items tracked in `docs/CHANGELOG.md`); v0.42.0 highest
  priority because the default behavior shift needs real-machine
  validation on both single-repo and hub-mode deploys.
- **No code freeze.** Feature work in flight should still go through
  the brainstorm → spec → plan → PR loop per `docs/superpowers/`.
```

- [ ] **Step 6: Read `docs/CHANGELOG.md` (Read-before-Edit) to see the most recent v0.41.0 entry header**

```bash
head -50 docs/CHANGELOG.md
```

- [ ] **Step 7: Edit `docs/CHANGELOG.md` — prepend the v0.42.0 entry above v0.41.0**

Insert this block immediately above the existing v0.41.0 entry (preserve newest-first order):

```markdown
## v0.42.0 — deploy git-repo discipline (2026-05-17)

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

```

- [ ] **Step 8: Run the static-wiring lock to confirm it activates and passes**

```bash
bash tests/test_v0_42_0_static_wiring.sh
```

Expected: prints all 8 `PASS:` lines and `test_v0_42_0_static_wiring: 8 invariants locked`. If any invariant fails, drift means T1–T7 didn't match the spec; fix the offending helper/file/directive in this same commit.

- [ ] **Step 9: Run full suite**

```bash
bash tests/run.sh 2>&1 | tail -15
```

Expected: 0 exit code, no FAIL lines. Pre-existing timing flakes may flap once; retry once if so.

- [ ] **Step 10: Commit**

```bash
git add .claude-plugin/plugin.json .claude-plugin/marketplace.json CLAUDE.md docs/CHANGELOG.md
git commit -m "$(cat <<'EOF'
chore(release): v0.42.0 — deploy git-repo discipline

- plugin.json + marketplace.json → 0.42.0
- CLAUDE.md Current focus rewrite naming v0.42.0
- CHANGELOG.md prepend v0.42.0 entry

Activates the v0.42.0 static-wiring lock (8 invariants).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Push branch + open PR against main

**Files:** none (network operation only).

- [ ] **Step 1: Push the branch**

```bash
git push -u origin feat/v0.42.0-deploy-git-repo-discipline
```

- [ ] **Step 2: Open the PR**

```bash
gh pr create --base main --head feat/v0.42.0-deploy-git-repo-discipline \
  --title "feat: v0.42.0 — deploy git-repo discipline" \
  --body "$(cat <<'EOF'
## Summary

- `/clone-wars:deploy` now operates on the conductor's current branch in every affected repo (single-repo and hub mode). The auto-branch `feat/deploy-<topic>` becomes opt-in via `--branch [name]`.
- Pre-deploy WIP is committed automatically per target as `chore: WIP before deploy <topic>`; post-deploy leftovers swept as `chore: post-deploy leftovers for <topic>`.
- Per-repo summary block lands in chat at Step 4 before archive (one block for single-repo, N back-to-back for hub mode).
- Branch-pin trooper instruction added to all 3 prompt builders; instruction-level enforcement, post-hoc verification via summary's `branch_changed=true` WARNING.

## Surface delta

- 4 new helpers in `lib/deploy.sh` (iter_targets, pre_snapshot, post_sweep, format_summary_block)
- 2 new CLI scripts (`bin/deploy-pre-snapshot.sh`, `bin/deploy-summary.sh`)
- 13 new tests + 1 permanent lint + 1 static-wiring lock (8 invariants)
- 1 test removed (`test_deploy_dirty_intercept_directive.sh` — locked the old 5a shape)
- Old sub-step 5a (Stash/Commit/Abort) gone; `pre-deploy-stash.txt` artifact gone

## Spec / plan

- Spec: `docs/superpowers/specs/2026-05-17-deploy-git-repo-discipline-design.md`
- Plan: `docs/superpowers/plans/2026-05-17-deploy-git-repo-discipline-plan.md`

## Test plan

- [ ] Full suite green: `bash tests/run.sh`
- [ ] v0.42.0 static-wiring lock activates: `bash tests/test_v0_42_0_static_wiring.sh` → 8 PASS lines
- [ ] Single-repo dogfood: `/clone-wars:deploy <design.md>` on a dirty branch — verify snapshot commit lands, trooper commits per task on the same branch, summary block prints at end with the correct diff/commit list, no AskUserQuestion fires
- [ ] Hub-mode dogfood: `/clone-wars:deploy <hub-design.md>` with ≥2 sub-repos — verify N baselines, N posts, N summary blocks back-to-back
- [ ] Opt-in sandbox-branch path still works: `/clone-wars:deploy --branch sandbox <doc>` — verify branch is created and snapshot/sweep apply
- [ ] Hook-blocked path: configure a `pre-commit` hook that exits 1 — verify deploy completes with WARNING in summary block

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: Capture the PR URL and report it back to the user**

Expected: `gh pr create` prints the URL on success. Surface it in the final message.

---

## Self-review (planner's checklist — already run)

- **Spec coverage**: every section of `2026-05-17-deploy-git-repo-discipline-design.md` maps to a task:
  - §Architecture/contract → T2 (iter_targets), T3 (pre_snapshot), T5 (post_sweep/format), T6 (summary script), T7 (directive wiring)
  - §Components → T2–T6 (helpers + bin scripts); T4 (BRANCH DISCIPLINE stanza); T7 (directive surgery, init.sh gating); T8 (static-wiring lock)
  - §Migration → T7 (init.sh + directive); T7 (test migration); T9 (CHANGELOG migration table cite)
  - §Test surface → T1 (RED scaffolds), T2–T6 (turn GREEN), T8 (static-wiring lock), T9 (lock activates)
  - §Success criteria → covered by e2e tests (T6) + dogfood checklist in T10's PR body
  - §Out of scope → reflected in CHANGELOG (T9) and not added to any task
- **Placeholder scan**: clean — no TBD/TODO/fill in later, every step contains code or exact commands.
- **Type consistency**: helper names (`cw_deploy_iter_targets`, `cw_deploy_pre_snapshot`, `cw_deploy_post_sweep`, `cw_deploy_format_summary_block`) match across spec + plan + tests + static-wiring lock. Baseline file path `$ART_DIR/baselines/<slug>.tsv` matches across spec, T3, T6, e2e tests, summary script. Post file path `$ART_DIR/posts/<slug>.tsv` introduced in T6 and used by static-wiring lock invariant.
