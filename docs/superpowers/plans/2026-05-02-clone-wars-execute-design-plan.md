# /clone-wars:execute-design Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `/clone-wars:execute-design` (v0.6.0) — a slash command that takes a design doc, dispatches it to a Codex trooper for plan-write/implementation/self-verification, and runs a Yoda-side cross-verify+fix loop bounded at 5 rounds.

**Architecture:** Mirrors the v0.2 consult split-orchestrator: one slash directive (Master Yoda) drives a chain of `bin/execute-design-*.sh` sub-scripts that talk to a single persistent Codex trooper (`cody-codex-<topic>`) via the existing file-IPC primitives. Yoda owns the design-doc audit and the cross-verify; codex owns plan/implement/self-verify (uses `superpowers:writing-plans`, `superpowers:subagent-driven-development`, `superpowers:verification-before-completion`, `superpowers:systematic-debugging`).

**Tech Stack:** bash 4.2+, tmux, the existing `lib/{state,ipc,consult,argsfile,log}.sh` helpers, and the project's `tests/run.sh` harness (`set -euo pipefail` per-test, `tests/lib/assert.sh`).

**Spec:** `docs/superpowers/specs/2026-05-02-clone-wars-execute-design.md`

---

## Source-of-truth references

These already exist and the new code consumes them as-is:

- `lib/state.sh` — `cw_state_root`, `cw_repo_hash`, `cw_state_ensure`
- `lib/ipc.sh` — `cw_trooper_dir`, `cw_outbox_path`, `cw_outbox_wait_since`, `cw_state_archive`
- `lib/consult.sh` — `cw_consult_topic_validate` (slug regex `^[a-z0-9][a-z0-9-]{0,31}$`), `cw_consult_outbox_match_endbyte` (re-used for end-byte capture in wait scripts)
- `lib/argsfile.sh` — `cw_args_file_load`
- `bin/spawn.sh` — `bin/spawn.sh <commander> <model> <topic>`; emits `{event:"ready"}` to outbox.jsonl on success
- `bin/send.sh` — `bin/send.sh <commander> <topic> <msg-or-@file>` (writes inbox.md + nudges pane)
- `bin/teardown.sh` — `bin/teardown.sh <topic>` (kills pane + archives state via `cw_state_archive`)
- `tests/lib/assert.sh` — `assert_eq`, `assert_contains`, `assert_exit`, `assert_file_exists`, `pass`

---

## File structure

**Created:**

| File | Responsibility |
|---|---|
| `lib/execute_design.sh` | Topic/art helpers, design-doc audit checklist, branch helper, prompt builders, classifier |
| `bin/execute-design-init.sh` | Derive slug from design-doc filename; create `_execute/`; copy design doc; create `feat/exec-<topic>` branch |
| `bin/execute-design-plan-send.sh` | Dispatch plan-phase prompt to codex (uses `superpowers:writing-plans`) |
| `bin/execute-design-plan-wait.sh` | Block on `done`/`error`; record `PS=ok\|failed\|timeout` |
| `bin/execute-design-implement-send.sh` | Dispatch implement-phase prompt (uses `superpowers:subagent-driven-development`) |
| `bin/execute-design-implement-wait.sh` | Block (long timeout default 7200s); record `IS=ok\|failed\|timeout` |
| `bin/execute-design-verify-send.sh` | Dispatch self-verify-phase prompt (uses `superpowers:verification-before-completion`); takes round# |
| `bin/execute-design-verify-wait.sh` | Block; record `VS=ok\|failed\|timeout` per round |
| `bin/execute-design-fix-send.sh` | Dispatch fix-phase prompt (skill named in `fix-prompt-N.md` preamble); takes round# |
| `bin/execute-design-teardown.sh` | Thin wrapper: `bin/teardown.sh <topic>` + topic validation |
| `bin/execute-design-archive.sh` | Move `_execute/` to `archive/<repo-hash>/<topic>/_execute-<ts>/` |
| `commands/execute-design.md` | Slash directive — Master Yoda orchestrates all phases including cross-verify + fix-loop |
| `tests/test_execute_design_helpers.sh` | Unit tests for `cw_execute_design_*` helpers |
| `tests/test_execute_design_init.sh` | init script: slug derivation, dir creation, branch behavior |
| `tests/test_execute_design_plan_send.sh` | static wiring + idempotency-fail-loud |
| `tests/test_execute_design_implement_send.sh` | static wiring + idempotency |
| `tests/test_execute_design_verify_send.sh` | static wiring + per-round file naming |
| `tests/test_execute_design_fix_send.sh` | static wiring + skill-routing preamble check |
| `tests/test_execute_design_archive.sh` | move-to-archive behavior |
| `tests/test_execute_design_v060_dogfood.sh` | manual release gate (skipped in `tests/run.sh`) |

**Modified:**

| File | Change |
|---|---|
| `bin/medic.sh` | Add execute-design helper-source check (cheap sanity that the new lib loads) |
| `tests/run.sh` | Add new dogfood test to the skip-list (manual gate) |
| `README.md` | Add `/clone-wars:execute-design` to the command table + one-paragraph quickstart |
| `CLAUDE.md` | Status line: `[x] v0.6.0: execute-design — codex-implements + yoda-verifies pipeline` |

---

## Naming conventions (locked before tasks)

- **Slug derivation:** `2026-05-02-clone-wars-execute-design.md` → strip leading `^\d{4}-\d{2}-\d{2}-`, strip trailing `-design.md`, result: `clone-wars-execute-design`. Must match `^[a-z0-9][a-z0-9-]{0,31}$` after derivation.
- **Topic prefix:** Topics are stored as **the derived slug, no prefix** (unlike consult which adds `consult-`). Rationale: design-doc filenames already encode the project shape; prefixing would cause `execute-clone-wars-execute-design`. The slug regex limit (32 chars) is enforced in init.
- **State file naming:** `_execute/{phase}-cody.txt` for phases plan/implement; `_execute/{phase}-cody-N.txt` for per-round phases verify; `_execute/verify-report-N.md`, `_execute/test-output-N.log`, `_execute/cross-verify-N.md`, `_execute/fix-prompt-N.md` (or `-N-debug.md` / `-N-gap.md` if split).
- **Status fields:** `PS=` (plan), `IS=` (implement), `VS=` (verify) — same pattern as consult's `FS=` (research) and `VS=` (verify).
- **Branch name:** `feat/exec-<topic>` by default. `--branch <name>` overrides.

---

## Task sequence rationale

The build order minimises rebreakage:

1. **Helpers first** (Tasks 1-4) — pure functions, no side effects, fully unit-tested. Every later script depends on them.
2. **Init second** (Task 5) — sets up the `_execute/` directory the rest of the pipeline expects.
3. **Phase scripts in pipeline order** (Tasks 6-12) — each phase's send-script + wait-script land together so the pair can be tested. Verify (Task 10-11) before fix (Task 12) because fix consumes verify's output shape.
4. **Teardown + archive** (Task 13) — needs no upstream changes.
5. **Slash directive** (Task 14) — the only piece that needs all sub-scripts present.
6. **Polish** (Task 15) — medic, README, dogfood gate.

---

## Task 1: Helpers — topic dir, art dir, assert, derive

**Files:**
- Create: `lib/execute_design.sh`
- Create: `tests/test_execute_design_helpers.sh`

- [ ] **Step 1.1: Write failing test for topic_dir + art_dir + assert_topic**

```bash
cat > tests/test_execute_design_helpers.sh <<'EOF'
#!/usr/bin/env bash
# tests/test_execute_design_helpers.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/state.sh
source ../lib/consult.sh         # for cw_consult_outbox_match_endbyte (re-use)
source ../lib/execute_design.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

# 1. topic_dir + art_dir return absolute paths under $CLONE_WARS_HOME/state/.
RH=$(cw_repo_hash)
got=$(cw_execute_design_topic_dir my-topic)
assert_eq "$got" "$CLONE_WARS_HOME/state/$RH/my-topic" "topic_dir"
got=$(cw_execute_design_art_dir my-topic)
assert_eq "$got" "$CLONE_WARS_HOME/state/$RH/my-topic/_execute" "art_dir"
pass "topic_dir + art_dir"

# 2. assert_topic accepts valid slugs, rejects invalid.
( cw_execute_design_assert_topic my-topic ) || { echo "FAIL: valid slug rejected" >&2; exit 1; }
out=$( cw_execute_design_assert_topic "../bad" 2>&1 ) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: path-traversal accepted" >&2; exit 1; }
out=$( cw_execute_design_assert_topic "Bad-Topic" 2>&1 ) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: uppercase accepted" >&2; exit 1; }
pass "assert_topic"
EOF
```

- [ ] **Step 1.2: Run the test — expect FAIL (lib doesn't exist yet)**

Run: `bash tests/test_execute_design_helpers.sh`
Expected: error sourcing `../lib/execute_design.sh` (no such file).

- [ ] **Step 1.3: Create lib/execute_design.sh with the three helpers**

```bash
cat > lib/execute_design.sh <<'EOF'
# lib/execute_design.sh — /clone-wars:execute-design helpers.
# Sourced. Depends on lib/state.sh, lib/consult.sh (for slug regex re-use).

cw_execute_design_topic_dir() {
  printf '%s/state/%s/%s\n' "$(cw_state_root)" "$(cw_repo_hash)" "$1"
}

cw_execute_design_art_dir() {
  printf '%s/state/%s/%s/_execute\n' "$(cw_state_root)" "$(cw_repo_hash)" "$1"
}

# cw_execute_design_assert_topic <topic>
# Slug regex must match consult's so existing pipelines stay aligned.
cw_execute_design_assert_topic() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] \
    || { log_error "invalid topic slug: '$1' (must match ^[a-z0-9][a-z0-9-]{0,31}\$)"; exit 2; }
}
EOF
```

- [ ] **Step 1.4: Run the test — expect PASS**

Run: `bash tests/test_execute_design_helpers.sh`
Expected: `PASS: topic_dir + art_dir` and `PASS: assert_topic`.

- [ ] **Step 1.5: Add derive_topic test case**

Append to `tests/test_execute_design_helpers.sh`:

```bash
# 3. derive_topic strips date prefix + -design.md suffix.
got=$(cw_execute_design_derive_topic "docs/superpowers/specs/2026-05-02-foo-bar-design.md")
assert_eq "$got" "foo-bar" "derive_topic strips prefix+suffix"
got=$(cw_execute_design_derive_topic "/abs/path/2026-04-29-x-design.md")
assert_eq "$got" "x" "derive_topic abs path"
# Filename without date prefix → return basename minus -design.md (caller decides)
got=$(cw_execute_design_derive_topic "anything-design.md")
assert_eq "$got" "anything" "derive_topic missing date prefix"
# Filename without -design.md suffix → return basename minus extension
got=$(cw_execute_design_derive_topic "raw.md")
assert_eq "$got" "raw" "derive_topic missing -design suffix"
# Empty / no-extension → empty string (caller refuses)
got=$(cw_execute_design_derive_topic "")
assert_eq "$got" "" "derive_topic empty input"
pass "derive_topic"
```

- [ ] **Step 1.6: Run — expect FAIL on derive_topic**

Run: `bash tests/test_execute_design_helpers.sh`
Expected: `cw_execute_design_derive_topic: command not found` or similar.

- [ ] **Step 1.7: Add derive_topic to lib/execute_design.sh**

Append:

```bash
# cw_execute_design_derive_topic <design-path>
# Strip leading YYYY-MM-DD- and trailing -design.md (or .md). Print slug.
cw_execute_design_derive_topic() {
  local p="$1" base
  [[ -n "$p" ]] || { printf ''; return 0; }
  base="${p##*/}"                       # basename
  base="${base#????-??-??-}"            # strip YYYY-MM-DD-
  base="${base%-design.md}"             # strip -design.md
  base="${base%.md}"                    # strip .md if -design.md missed
  printf '%s\n' "$base"
}
```

- [ ] **Step 1.8: Run the test — expect PASS**

Run: `bash tests/test_execute_design_helpers.sh`
Expected: all four helper tests pass.

- [ ] **Step 1.9: Commit**

```bash
git add lib/execute_design.sh tests/test_execute_design_helpers.sh
git commit -m "feat(execute-design): add topic/art/assert/derive helpers (v0.6.0 task 1)"
```

---

## Task 2: Helper — design-doc audit

The audit is a heuristic checklist run by `init` (and re-runnable from the slash directive). It produces a structured PASS/FAIL summary that Yoda reads to decide whether to refuse or `AskUserQuestion`. The helper itself is pure-bash heuristics — no LLM judgement. Yoda is the actual auditor; the helper just structures Yoda's reading.

**Files:**
- Modify: `lib/execute_design.sh`
- Modify: `tests/test_execute_design_helpers.sh`

- [ ] **Step 2.1: Append audit test cases**

Append to `tests/test_execute_design_helpers.sh`:

```bash
# 4. audit_doc — PASS for a complete spec, FAIL for one with TBDs and missing sections.
GOOD="$TMP/good.md"
cat > "$GOOD" <<'MD'
# Foo Spec
**Status:** Design
## Goal
Build foo.
## Architecture
Use bar pattern.
## Testing strategy
Unit tests under tests/test_foo.sh; integration via fixtures/.
## Success criteria
1. tests pass
2. medic OK
MD
out=$(cw_execute_design_audit_doc "$GOOD") && rc=0 || rc=$?
[[ "$rc" -eq 0 ]] || { echo "FAIL: good spec scored FAIL: $out" >&2; exit 1; }
echo "$out" | grep -q '^VERDICT=PASS' || { echo "FAIL: missing VERDICT=PASS in: $out" >&2; exit 1; }
pass "audit_doc PASS on complete spec"

BAD="$TMP/bad.md"
cat > "$BAD" <<'MD'
# Bad Spec
## Goal
TBD
## Architecture
fill in later
MD
out=$(cw_execute_design_audit_doc "$BAD") && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: bad spec scored PASS: $out" >&2; exit 1; }
echo "$out" | grep -q '^VERDICT=FAIL' || { echo "FAIL: missing VERDICT=FAIL in: $out" >&2; exit 1; }
echo "$out" | grep -q 'no_testing_section'   || { echo "FAIL: testing section not flagged" >&2; exit 1; }
echo "$out" | grep -q 'no_success_section'   || { echo "FAIL: success criteria not flagged" >&2; exit 1; }
echo "$out" | grep -q 'tbd_marker'           || { echo "FAIL: TBD not flagged" >&2; exit 1; }
echo "$out" | grep -q 'fill_in_later_marker' || { echo "FAIL: 'fill in later' not flagged" >&2; exit 1; }
pass "audit_doc FAIL on incomplete spec with structured issues"

# 5. Missing file → exit 2 with usage-style error.
out=$(cw_execute_design_audit_doc "$TMP/nope.md" 2>&1) && rc=0 || rc=$?
[[ "$rc" -eq 2 ]] || { echo "FAIL: missing file did not exit 2: rc=$rc out=$out" >&2; exit 1; }
pass "audit_doc rc=2 on missing file"
```

- [ ] **Step 2.2: Run — expect FAIL (audit_doc not defined)**

Run: `bash tests/test_execute_design_helpers.sh`
Expected: `cw_execute_design_audit_doc: command not found`.

- [ ] **Step 2.3: Add audit_doc to lib/execute_design.sh**

Append:

```bash
# cw_execute_design_audit_doc <design-path>
# Heuristic checklist for design-doc readiness. Prints one VERDICT= line plus
# one ISSUE= line per detected issue. Returns 0 on PASS, 1 on FAIL, 2 on
# missing/unreadable file.
#
# Heuristic gates (each ISSUE= prints only if the gate fails):
#   no_goal_section       — no '^## Goal' heading
#   no_arch_section       — no '^## Architecture' or '^## Approach' heading
#   no_testing_section    — no heading containing 'Test' or 'test'
#   no_success_section    — no heading containing 'Success' or 'success'
#   tbd_marker            — file contains 'TBD' as a word
#   todo_marker           — file contains 'TODO' as a word (case-sensitive; lowercase
#                           'todo' is allowed since it commonly appears in field names)
#   fill_in_later_marker  — file matches /fill in later/i
#   to_be_determined_marker — file matches /to be determined/i
cw_execute_design_audit_doc() {
  local doc="$1"
  [[ -f "$doc" && -r "$doc" ]] || { log_error "design-doc unreadable: $doc"; return 2; }
  local fail=0
  local -a issues=()
  grep -qE '^##\s+Goal\b'                       "$doc" || { issues+=("no_goal_section"); fail=1; }
  grep -qE '^##\s+(Architecture|Approach)\b'    "$doc" || { issues+=("no_arch_section"); fail=1; }
  grep -qE '^##\s+.*[Tt]est'                    "$doc" || { issues+=("no_testing_section"); fail=1; }
  grep -qE '^##\s+.*[Ss]uccess'                 "$doc" || { issues+=("no_success_section"); fail=1; }
  grep -qE '\bTBD\b'                            "$doc" && { issues+=("tbd_marker"); fail=1; }
  grep -qE '\bTODO\b'                           "$doc" && { issues+=("todo_marker"); fail=1; }
  grep -qiE 'fill in later'                     "$doc" && { issues+=("fill_in_later_marker"); fail=1; }
  grep -qiE 'to be determined'                  "$doc" && { issues+=("to_be_determined_marker"); fail=1; }
  if (( fail == 0 )); then
    printf 'VERDICT=PASS\n'
    return 0
  fi
  printf 'VERDICT=FAIL\n'
  local i
  for i in "${issues[@]}"; do
    printf 'ISSUE=%s\n' "$i"
  done
  return 1
}
```

- [ ] **Step 2.4: Run — expect PASS**

Run: `bash tests/test_execute_design_helpers.sh`
Expected: 3 new pass lines (`audit_doc PASS`, `audit_doc FAIL`, `audit_doc rc=2`).

- [ ] **Step 2.5: Commit**

```bash
git add lib/execute_design.sh tests/test_execute_design_helpers.sh
git commit -m "feat(execute-design): add design-doc audit helper (task 2)"
```

---

## Task 3: Helper — branch_create

Auto-creates `feat/exec-<topic>`. Refuses on dirty tree (suggests `--no-branch` or `git stash`). Refuses if branch exists (suggests `--branch <name>`). Returns the branch name on stdout.

**Files:**
- Modify: `lib/execute_design.sh`
- Modify: `tests/test_execute_design_helpers.sh`

- [ ] **Step 3.1: Append branch_create test cases**

Append to `tests/test_execute_design_helpers.sh`:

```bash
# 6. branch_create — happy path: clean tree, branch doesn't exist.
REPO="$TMP/repo"
git -C "$TMP" init --quiet --initial-branch=main "$REPO"
cd "$REPO"
git config user.email t@t; git config user.name t
echo init > a.txt; git add a.txt; git commit --quiet -m init

out=$(cw_execute_design_branch_create my-topic) && rc=0 || rc=$?
[[ "$rc" -eq 0 ]] || { echo "FAIL: branch_create happy-path rc=$rc out=$out" >&2; exit 1; }
[[ "$out" == "feat/exec-my-topic" ]] || { echo "FAIL: bad branch name printed: $out" >&2; exit 1; }
got=$(git rev-parse --abbrev-ref HEAD)
assert_eq "$got" "feat/exec-my-topic" "branch checked out"
pass "branch_create happy path"

# 7. Refuses if branch exists.
git checkout --quiet main
out=$(cw_execute_design_branch_create my-topic 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: existing branch accepted" >&2; exit 1; }
echo "$out" | grep -q 'already exists' || { echo "FAIL: error msg missing 'already exists': $out" >&2; exit 1; }
pass "branch_create refuses existing branch"

# 8. Refuses if working tree is dirty.
git checkout --quiet main
echo dirty > b.txt
out=$(cw_execute_design_branch_create other-topic 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: dirty tree accepted" >&2; exit 1; }
echo "$out" | grep -q 'dirty\|uncommitted' || { echo "FAIL: error msg missing 'dirty': $out" >&2; exit 1; }
pass "branch_create refuses dirty tree"

# Cleanup test cwd
cd "$TMP"
rm -rf "$REPO"
```

- [ ] **Step 3.2: Run — expect FAIL (branch_create undefined)**

Run: `bash tests/test_execute_design_helpers.sh`
Expected: `cw_execute_design_branch_create: command not found`.

- [ ] **Step 3.3: Add branch_create to lib/execute_design.sh**

Append:

```bash
# cw_execute_design_branch_create <topic> [<branch-name-override>]
# Refuses on dirty tree or pre-existing branch. Prints created branch name.
cw_execute_design_branch_create() {
  local topic="$1" override="${2:-}" branch
  branch="${override:-feat/exec-$topic}"
  # Dirty-tree check
  if ! git diff --quiet || ! git diff --cached --quiet; then
    log_error "working tree is dirty (uncommitted changes); commit/stash or pass --no-branch"
    return 1
  fi
  # Untracked-files check (ls-files -o exit code is unreliable; count instead)
  if [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
    log_error "working tree is dirty (untracked files); commit/stash or pass --no-branch"
    return 1
  fi
  # Pre-existing branch check
  if git show-ref --verify --quiet "refs/heads/$branch"; then
    log_error "branch '$branch' already exists; pass --branch <name> to override"
    return 1
  fi
  git checkout -b "$branch" >/dev/null 2>&1 || { log_error "git checkout -b failed"; return 1; }
  printf '%s\n' "$branch"
}
```

- [ ] **Step 3.4: Run — expect PASS**

Run: `bash tests/test_execute_design_helpers.sh`
Expected: 3 new pass lines for branch_create.

- [ ] **Step 3.5: Commit**

```bash
git add lib/execute_design.sh tests/test_execute_design_helpers.sh
git commit -m "feat(execute-design): add branch_create helper (task 3)"
```

---

## Task 4: Helpers — phase prompt builders

Four pure-string builders that produce the inbox-prompt body for each phase. Living in lib so the prompts can be unit-tested against a frozen string and so the slash directive stays slim. Each builder ends the prompt with `END_OF_INSTRUCTION` so trooper-side parsing matches consult conventions.

**Files:**
- Modify: `lib/execute_design.sh`
- Modify: `tests/test_execute_design_helpers.sh`

- [ ] **Step 4.1: Append prompt-builder test cases**

Append to `tests/test_execute_design_helpers.sh`:

```bash
# 9. plan-prompt builder names the writing-plans skill + the design path.
out=$(cw_execute_design_build_plan_prompt /abs/_execute/design.md /abs/_execute/plan.md)
echo "$out" | grep -q 'superpowers:writing-plans'    || { echo "FAIL: skill missing" >&2; exit 1; }
echo "$out" | grep -q '/abs/_execute/design.md'      || { echo "FAIL: design path missing" >&2; exit 1; }
echo "$out" | grep -q '/abs/_execute/plan.md'        || { echo "FAIL: plan path missing" >&2; exit 1; }
echo "$out" | grep -q 'END_OF_INSTRUCTION'           || { echo "FAIL: sentinel missing" >&2; exit 1; }
pass "plan-prompt builder"

# 10. implement-prompt names subagent-driven-development + plan path.
out=$(cw_execute_design_build_implement_prompt /abs/_execute/plan.md)
echo "$out" | grep -q 'superpowers:subagent-driven-development' \
  || { echo "FAIL: skill missing" >&2; exit 1; }
echo "$out" | grep -q '/abs/_execute/plan.md'        || { echo "FAIL: plan path missing" >&2; exit 1; }
echo "$out" | grep -q 'commit per task'              || { echo "FAIL: commit guidance missing" >&2; exit 1; }
echo "$out" | grep -q 'END_OF_INSTRUCTION'           || { echo "FAIL: sentinel missing" >&2; exit 1; }
pass "implement-prompt builder"

# 11. verify-prompt names verification-before-completion + per-round paths.
out=$(cw_execute_design_build_verify_prompt /abs/_execute/design.md 1 /abs/_execute/verify-report-1.md /abs/_execute/test-output-1.log)
echo "$out" | grep -q 'superpowers:verification-before-completion' \
  || { echo "FAIL: skill missing" >&2; exit 1; }
echo "$out" | grep -q '/abs/_execute/design.md'             || { echo "FAIL: design path missing" >&2; exit 1; }
echo "$out" | grep -q '/abs/_execute/verify-report-1.md'    || { echo "FAIL: report path missing" >&2; exit 1; }
echo "$out" | grep -q '/abs/_execute/test-output-1.log'     || { echo "FAIL: test-output path missing" >&2; exit 1; }
echo "$out" | grep -q 'END_OF_INSTRUCTION'                  || { echo "FAIL: sentinel missing" >&2; exit 1; }
pass "verify-prompt builder"

# 12. fix-prompt names the fix-prompt path; the directive selects the skill.
out=$(cw_execute_design_build_fix_prompt /abs/_execute/fix-prompt-1.md)
echo "$out" | grep -q '/abs/_execute/fix-prompt-1.md'       || { echo "FAIL: fix-prompt path missing" >&2; exit 1; }
echo "$out" | grep -q 'preamble'                            || { echo "FAIL: preamble guidance missing" >&2; exit 1; }
echo "$out" | grep -q 'commit per fix'                      || { echo "FAIL: commit guidance missing" >&2; exit 1; }
echo "$out" | grep -q 'END_OF_INSTRUCTION'                  || { echo "FAIL: sentinel missing" >&2; exit 1; }
pass "fix-prompt builder"
```

- [ ] **Step 4.2: Run — expect FAIL (builders undefined)**

Run: `bash tests/test_execute_design_helpers.sh`
Expected: `cw_execute_design_build_plan_prompt: command not found`.

- [ ] **Step 4.3: Add the four builders to lib/execute_design.sh**

Append:

```bash
# Phase prompt builders. Each prints a self-contained inbox-prompt body
# terminating in END_OF_INSTRUCTION. The slash directive writes the body
# to inbox.md via bin/send.sh.

cw_execute_design_build_plan_prompt() {
  local design="$1" plan_out="$2"
  cat <<EOF
You are entering the PLAN phase of /clone-wars:execute-design.

Use the superpowers:writing-plans skill. Read the design doc at:
  $design

Produce a comprehensive implementation plan and write it to:
  $plan_out

Follow the writing-plans skill's task-decomposition conventions
(bite-sized steps, exact file paths, complete code, frequent commits).

When the plan file is written, emit a {"event":"done"} line to your
outbox.

END_OF_INSTRUCTION
EOF
}

cw_execute_design_build_implement_prompt() {
  local plan="$1"
  cat <<EOF
You are entering the IMPLEMENT phase of /clone-wars:execute-design.

Use the superpowers:subagent-driven-development skill. Read the plan at:
  $plan

Implement every task in order. For each task: write failing tests, make
them pass, commit per task, run the full test suite after each task and
confirm it stays green. Do not skip tasks. Do not declare done before all
tasks are implemented and all tests pass.

When all tasks are complete and the full test suite is green, emit a
{"event":"done"} line to your outbox.

END_OF_INSTRUCTION
EOF
}

cw_execute_design_build_verify_prompt() {
  local design="$1" round="$2" report="$3" test_log="$4"
  cat <<EOF
You are entering the SELF-VERIFY phase (round $round) of /clone-wars:execute-design.

Use the superpowers:verification-before-completion skill. Verify your
implementation against the design doc at:
  $design

Write your verification report to:
  $report

The report must include:
  - top-line VERDICT: PASS | PARTIAL | FAIL
  - per-requirement verdicts (PASS / PARTIAL / FAIL) with evidence
    (file:line or commit SHA references)

Also run the full test suite and write the raw output to:
  $test_log

When both files are written, emit a {"event":"done"} line to your outbox.

END_OF_INSTRUCTION
EOF
}

cw_execute_design_build_fix_prompt() {
  local fix_prompt="$1"
  cat <<EOF
You are entering the FIX phase of /clone-wars:execute-design.

Cross-verification flagged issues. Read the fix-prompt at:
  $fix_prompt

The file's preamble names the superpowers skill you must use
(systematic-debugging for bugs/regressions, writing-plans for spec gaps).
Resolve every issue listed. Commit per fix. Re-run the full test suite
after each fix. Do NOT skip any issue.

When every issue is resolved and the full test suite is green, emit a
{"event":"done"} line to your outbox.

END_OF_INSTRUCTION
EOF
}
```

- [ ] **Step 4.4: Run — expect PASS**

Run: `bash tests/test_execute_design_helpers.sh`
Expected: 4 new pass lines for the builders.

- [ ] **Step 4.5: Commit**

```bash
git add lib/execute_design.sh tests/test_execute_design_helpers.sh
git commit -m "feat(execute-design): add phase prompt builders (task 4)"
```

---

## Task 5: bin/execute-design-init.sh

Derives the topic slug from the design-doc filename, creates `_execute/` under the topic dir, copies the design doc in, and (unless `--no-branch`) creates `feat/exec-<topic>`. Prints the topic slug to stdout (so the slash directive captures it).

**Files:**
- Create: `bin/execute-design-init.sh`
- Create: `tests/test_execute_design_init.sh`

- [ ] **Step 5.1: Write the failing test**

```bash
cat > tests/test_execute_design_init.sh <<'EOF'
#!/usr/bin/env bash
# tests/test_execute_design_init.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

# Stage a tmp git repo so branch creation works.
REPO="$TMP/repo"
mkdir -p "$REPO"
( cd "$REPO" && git init --quiet --initial-branch=main \
    && git config user.email t@t && git config user.name t \
    && echo seed > seed.txt && git add seed.txt && git commit --quiet -m init )

# Stage a sample design doc.
DDOC="$REPO/docs/superpowers/specs/2026-05-02-foo-bar-design.md"
mkdir -p "$(dirname "$DDOC")"
cat > "$DDOC" <<'MD'
# Foo
## Goal
Build foo.
## Architecture
Use bar.
## Testing strategy
Unit tests.
## Success criteria
1. tests pass
MD
( cd "$REPO" && git add . && git commit --quiet -m "spec: foo-bar" )

# 1. Happy path — derives slug, creates _execute/, copies design.md, creates branch.
( cd "$REPO" && bash "$OLDPWD/../bin/execute-design-init.sh" "$DDOC" ) > "$TMP/topic.txt" 2>"$TMP/err.log"
TOPIC=$(cat "$TMP/topic.txt" | tr -d '\r\n')
assert_eq "$TOPIC" "foo-bar" "init prints derived slug"
RH=$(bash -c "cd $REPO && source $OLDPWD/../lib/state.sh && cw_repo_hash")
ART="$CLONE_WARS_HOME/state/$RH/foo-bar/_execute"
assert_file_exists "$ART/design.md" "design.md copied into _execute/"
assert_file_exists "$ART/topic.txt" "topic.txt written"
got=$(cat "$ART/topic.txt"); assert_eq "$got" "foo-bar" "topic.txt content"
got=$( cd "$REPO" && git rev-parse --abbrev-ref HEAD )
assert_eq "$got" "feat/exec-foo-bar" "branch created"
pass "init happy path"

# 2. --no-branch skips branch creation.
( cd "$REPO" && git checkout --quiet main && git branch -D feat/exec-foo-bar >/dev/null )
rm -rf "$ART"
( cd "$REPO" && bash "$OLDPWD/../bin/execute-design-init.sh" --no-branch "$DDOC" ) >/dev/null
got=$( cd "$REPO" && git rev-parse --abbrev-ref HEAD )
assert_eq "$got" "main" "no-branch keeps main"
pass "init --no-branch keeps current branch"

# 3. Refuses if design doc unreadable.
out=$( cd "$REPO" && bash "$OLDPWD/../bin/execute-design-init.sh" "$REPO/no-such.md" 2>&1 ) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: missing design accepted" >&2; exit 1; }
pass "init refuses missing design"

# 4. --topic <slug> overrides derived slug.
rm -rf "$CLONE_WARS_HOME/state/$RH/explicit-slug"
( cd "$REPO" && git checkout --quiet main )
( cd "$REPO" && bash "$OLDPWD/../bin/execute-design-init.sh" --no-branch --topic explicit-slug "$DDOC" ) > "$TMP/topic2.txt"
TOPIC2=$(cat "$TMP/topic2.txt" | tr -d '\r\n')
assert_eq "$TOPIC2" "explicit-slug" "--topic overrides"
assert_file_exists "$CLONE_WARS_HOME/state/$RH/explicit-slug/_execute/design.md" "explicit slug got dir"
pass "init --topic override"

# 5. Refuses if topic dir already exists (no implicit overwrite).
out=$( cd "$REPO" && bash "$OLDPWD/../bin/execute-design-init.sh" --no-branch --topic explicit-slug "$DDOC" 2>&1 ) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: dup topic accepted" >&2; exit 1; }
echo "$out" | grep -q 'already exists' || { echo "FAIL: error msg missing 'already exists': $out" >&2; exit 1; }
pass "init refuses duplicate topic"
EOF
```

- [ ] **Step 5.2: Run — expect FAIL (script doesn't exist)**

Run: `bash tests/test_execute_design_init.sh`
Expected: `bash: .../bin/execute-design-init.sh: No such file or directory`.

- [ ] **Step 5.3: Implement bin/execute-design-init.sh**

```bash
cat > bin/execute-design-init.sh <<'EOF'
#!/usr/bin/env bash
# bin/execute-design-init.sh — derive topic slug, create _execute/, copy
# design doc, create feat/exec-<topic> branch (unless --no-branch).
# Prints the topic slug on stdout.
#
# Usage:
#   bin/execute-design-init.sh [--no-branch] [--branch <name>] [--topic <slug>] <design-path>

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/argsfile.sh"
source "$PLUGIN_ROOT/lib/consult.sh"     # cw_consult_outbox_match_endbyte (later)
source "$PLUGIN_ROOT/lib/execute_design.sh"

# --args-file passthrough (mirrors bin/spawn.sh / bin/send.sh).
if [[ "${1:-}" == "--args-file" ]]; then
  [[ -n "${2:-}" ]] || { echo "--args-file requires a path" >&2; exit 2; }
  args_file="$2"; shift 2
  mapfile -t _TOKENS < <(cw_args_file_load "$args_file")
  set -- "${_TOKENS[@]}" "$@"
fi

NO_BRANCH=0
BRANCH_OVERRIDE=""
TOPIC_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-branch)  NO_BRANCH=1; shift ;;
    --branch)     BRANCH_OVERRIDE="$2"; shift 2 ;;
    --topic)      TOPIC_OVERRIDE="$2"; shift 2 ;;
    --) shift; break ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *)  break ;;
  esac
done

[[ $# -eq 1 ]] || { echo "Usage: $0 [--no-branch] [--branch <n>] [--topic <slug>] <design-path>" >&2; exit 2; }
DESIGN_PATH="$1"
[[ -f "$DESIGN_PATH" && -r "$DESIGN_PATH" ]] || { log_error "design doc unreadable: $DESIGN_PATH"; exit 1; }

# Derive topic
if [[ -n "$TOPIC_OVERRIDE" ]]; then
  TOPIC="$TOPIC_OVERRIDE"
else
  TOPIC=$(cw_execute_design_derive_topic "$DESIGN_PATH")
  [[ -n "$TOPIC" ]] || { log_error "could not derive topic from filename; pass --topic <slug>"; exit 1; }
fi
cw_execute_design_assert_topic "$TOPIC"

TOPIC_DIR="$(cw_execute_design_topic_dir "$TOPIC")"
ART_DIR="$(cw_execute_design_art_dir "$TOPIC")"
[[ ! -d "$TOPIC_DIR" ]] || { log_error "topic dir already exists: $TOPIC_DIR (pick a different --topic or run teardown)"; exit 1; }

mkdir -p "$ART_DIR"
cp "$DESIGN_PATH" "$ART_DIR/design.md"
printf '%s' "$TOPIC" > "$ART_DIR/topic.txt"

# Branch
if (( NO_BRANCH == 0 )); then
  if branch=$(cw_execute_design_branch_create "$TOPIC" "$BRANCH_OVERRIDE"); then
    log_info "branch: $branch"
  else
    log_error "branch creation failed; remove $ART_DIR or pass --no-branch and retry"
    exit 1
  fi
fi

log_info "topic:        $TOPIC"
log_info "  artifacts:  $ART_DIR"
log_info "  design.md:  $ART_DIR/design.md"

printf '%s\n' "$TOPIC"
EOF
chmod +x bin/execute-design-init.sh
```

- [ ] **Step 5.4: Run — expect PASS**

Run: `bash tests/test_execute_design_init.sh`
Expected: 5 pass lines.

- [ ] **Step 5.5: Commit**

```bash
git add bin/execute-design-init.sh tests/test_execute_design_init.sh
git commit -m "feat(execute-design): bin/execute-design-init.sh (task 5)"
```

---

## Task 6: bin/execute-design-plan-send.sh

Mirrors `bin/consult-research-send.sh`. Writes the prompt file, captures outbox-OFFSET, sends via `bin/send.sh`, refuses if state file already exists.

**Files:**
- Create: `bin/execute-design-plan-send.sh`
- Create: `tests/test_execute_design_plan_send.sh`

- [ ] **Step 6.1: Write the failing test**

```bash
cat > tests/test_execute_design_plan_send.sh <<'EOF'
#!/usr/bin/env bash
# tests/test_execute_design_plan_send.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

# Static wiring: sources lib, builds plan prompt, captures OFFSET, calls send.sh.
grep -q 'source.*lib/execute_design.sh' ../bin/execute-design-plan-send.sh \
  || { echo "FAIL: missing lib source" >&2; exit 1; }
grep -q 'cw_execute_design_assert_topic' ../bin/execute-design-plan-send.sh \
  || { echo "FAIL: missing topic assert" >&2; exit 1; }
grep -q 'cw_execute_design_build_plan_prompt' ../bin/execute-design-plan-send.sh \
  || { echo "FAIL: missing plan-prompt builder" >&2; exit 1; }
grep -q 'wc -c' ../bin/execute-design-plan-send.sh \
  || { echo "FAIL: missing wc -c offset capture" >&2; exit 1; }
grep -q 'OFFSET=' ../bin/execute-design-plan-send.sh \
  || { echo "FAIL: missing OFFSET= write" >&2; exit 1; }
pass "plan-send static wiring"

# Build a fake topic dir + cody trooper outbox, exercise idempotency.
RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
TOPIC=plan-send-fixture
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
mkdir -p "$TD/_execute" "$TD/cody-codex"
echo "fake design body" > "$TD/_execute/design.md"
touch "$TD/cody-codex/outbox.jsonl"
printf '{"pane_id":"%%99","spawned_at":"x"}\n' > "$TD/cody-codex/pane.json"

# Pre-populate plan-cody.txt and assert second call refuses.
echo "OFFSET=0" > "$TD/_execute/plan-cody.txt"
err=$(../bin/execute-design-plan-send.sh "$TOPIC" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && echo "$err" | grep -q 'already exists' \
  || { echo "FAIL: should refuse with existing state file. rc=$rc out=$err" >&2; exit 1; }
pass "plan-send fails loud on existing state file"

# Bad topic rejected.
err=$(../bin/execute-design-plan-send.sh "../bad" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: bad topic accepted" >&2; exit 1; }
pass "plan-send rejects bad topic"
EOF
```

- [ ] **Step 6.2: Run — expect FAIL (script absent)**

Run: `bash tests/test_execute_design_plan_send.sh`
Expected: `grep: ../bin/execute-design-plan-send.sh: No such file or directory`.

- [ ] **Step 6.3: Implement the script**

```bash
cat > bin/execute-design-plan-send.sh <<'EOF'
#!/usr/bin/env bash
# bin/execute-design-plan-send.sh — Phase 1 plan dispatch (codex).
#
# Usage: bin/execute-design-plan-send.sh <topic>
#
# Writes _execute/plan-cody.txt with one line: OFFSET=<n>.
# Refuses if the file already exists (idempotency-fail-loud).

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/execute_design.sh"

[[ $# -eq 1 ]] || { echo "Usage: $0 <topic>" >&2; exit 2; }
TOPIC="$1"
cw_execute_design_assert_topic "$TOPIC"

ART_DIR="$(cw_execute_design_art_dir "$TOPIC")"
[[ -d "$ART_DIR" ]] || { log_error "$ART_DIR not found — run execute-design-init first"; exit 1; }

STATE_FILE="$ART_DIR/plan-cody.txt"
[[ ! -e "$STATE_FILE" ]] || { log_error "$STATE_FILE already exists; rm to retry"; exit 1; }

DESIGN="$ART_DIR/design.md"
PLAN_OUT="$ART_DIR/plan.md"
TROOPER_DIR=$(cw_trooper_dir cody codex "$TOPIC")
OUTBOX="$TROOPER_DIR/outbox.jsonl"
[[ -f "$OUTBOX" ]] || { log_error "outbox not found at $OUTBOX — was cody spawned?"; exit 1; }

PROMPT_FILE="$ART_DIR/cody_plan_prompt.md"
cw_execute_design_build_plan_prompt "$DESIGN" "$PLAN_OUT" > "$PROMPT_FILE"

OFFSET=$(wc -c < "$OUTBOX" | tr -d ' ')
printf 'OFFSET=%s\n' "$OFFSET" > "$STATE_FILE"

if ! "$PLUGIN_ROOT/bin/send.sh" cody "$TOPIC" "@$PROMPT_FILE" >/dev/null; then
  log_error "send.sh failed; state file kept for retry"
  exit 1
fi

log_info "[plan-send] cody offset=$OFFSET"
EOF
chmod +x bin/execute-design-plan-send.sh
```

- [ ] **Step 6.4: Run — expect PASS**

Run: `bash tests/test_execute_design_plan_send.sh`
Expected: 3 pass lines.

- [ ] **Step 6.5: Commit**

```bash
git add bin/execute-design-plan-send.sh tests/test_execute_design_plan_send.sh
git commit -m "feat(execute-design): plan-send dispatch (task 6)"
```

---

## Task 7: bin/execute-design-plan-wait.sh

Mirrors `bin/consult-research-wait.sh` (without the question-event loop — codex's writing-plans skill doesn't ask user questions through the consult question protocol). Writes `PS=ok|failed|timeout` to `_execute/plan-cody.txt`. Drops a `plan-cody.done` sentinel for background-await.

**Files:**
- Create: `bin/execute-design-plan-wait.sh`

- [ ] **Step 7.1: Write the script**

```bash
cat > bin/execute-design-plan-wait.sh <<'EOF'
#!/usr/bin/env bash
# bin/execute-design-plan-wait.sh — Phase 1 plan wait.
#
# Usage: bin/execute-design-plan-wait.sh <topic>
#
# Reads OFFSET= from _execute/plan-cody.txt; appends PS=<status>.
# Returns rc=0 always — status field carries the outcome.

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/execute_design.sh"

[[ $# -eq 1 ]] || { echo "Usage: $0 <topic>" >&2; exit 2; }
TOPIC="$1"
cw_execute_design_assert_topic "$TOPIC"

ART_DIR="$(cw_execute_design_art_dir "$TOPIC")"
STATE_FILE="$ART_DIR/plan-cody.txt"
[[ -f "$STATE_FILE" ]] || { log_error "$STATE_FILE missing — run execute-design-plan-send first"; exit 1; }
# shellcheck disable=SC1090
source "$STATE_FILE"
[[ -n "${OFFSET:-}" ]] || { log_error "OFFSET not set in $STATE_FILE"; exit 1; }

TIMEOUT="${CW_EXECUTE_PLAN_TIMEOUT:-600}"
log_info "[plan-wait] cody offset=$OFFSET timeout=${TIMEOUT}s"

cw_outbox_wait_since cody codex "$TOPIC" "$OFFSET" done error "$TIMEOUT" >/dev/null || true

TROOPER_DIR=$(cw_trooper_dir cody codex "$TOPIC")
OUTBOX="$TROOPER_DIR/outbox.jsonl"
TAIL=$(tail -c "+$(( OFFSET + 1 ))" "$OUTBOX" 2>/dev/null || true)
MATCHED=$(printf '%s\n' "$TAIL" | grep -m1 -E '"event":"(done|error)"' || true)
EVENT=$(printf '%s' "$MATCHED" | sed -n 's/.*"event":"\([^"]*\)".*/\1/p')

case "$EVENT" in
  done)
    if [[ -f "$ART_DIR/plan.md" && -s "$ART_DIR/plan.md" ]]; then
      printf 'PS=ok\n' >> "$STATE_FILE"
      log_info "[plan-wait] cody PS=ok"
    else
      printf 'PS=failed\n' >> "$STATE_FILE"
      log_warn "[plan-wait] cody PS=failed (done but plan.md empty/missing)"
    fi
    ;;
  error)
    printf 'PS=failed\n' >> "$STATE_FILE"
    log_warn "[plan-wait] cody PS=failed (error event)"
    ;;
  '')
    printf 'PS=timeout\n' >> "$STATE_FILE"
    log_warn "[plan-wait] cody PS=timeout"
    ;;
  *)
    printf 'PS=failed\n' >> "$STATE_FILE"
    log_warn "[plan-wait] cody PS=failed (unknown event '$EVENT')"
    ;;
esac

# background-await sentinel
touch "${STATE_FILE%.txt}.done"
exit 0
EOF
chmod +x bin/execute-design-plan-wait.sh
```

- [ ] **Step 7.2: Smoke-test the script's static wiring**

Run:
```bash
bash -n bin/execute-design-plan-wait.sh && echo SYNTAX_OK
grep -q 'PS=ok\|PS=failed\|PS=timeout' bin/execute-design-plan-wait.sh && echo STATUS_FIELDS_OK
grep -q 'cw_outbox_wait_since cody codex' bin/execute-design-plan-wait.sh && echo WAIT_OK
```
Expected: three OK lines.

- [ ] **Step 7.3: Commit**

```bash
git add bin/execute-design-plan-wait.sh
git commit -m "feat(execute-design): plan-wait blocking (task 7)"
```

---

## Task 8: bin/execute-design-implement-send.sh

Same shape as plan-send. Writes `_execute/implement-cody.txt`. The implement timeout is 7200s by default — the heaviest single phase.

**Files:**
- Create: `bin/execute-design-implement-send.sh`
- Create: `tests/test_execute_design_implement_send.sh`

- [ ] **Step 8.1: Write the failing test**

```bash
cat > tests/test_execute_design_implement_send.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

grep -q 'source.*lib/execute_design.sh' ../bin/execute-design-implement-send.sh \
  || { echo "FAIL: missing lib source" >&2; exit 1; }
grep -q 'cw_execute_design_build_implement_prompt' ../bin/execute-design-implement-send.sh \
  || { echo "FAIL: missing implement-prompt builder" >&2; exit 1; }
grep -q 'OFFSET=' ../bin/execute-design-implement-send.sh \
  || { echo "FAIL: missing OFFSET= write" >&2; exit 1; }
pass "implement-send static wiring"

RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
TOPIC=impl-send-fixture
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
mkdir -p "$TD/_execute" "$TD/cody-codex"
echo "plan body" > "$TD/_execute/plan.md"
touch "$TD/cody-codex/outbox.jsonl"
printf '{"pane_id":"%%88","spawned_at":"x"}\n' > "$TD/cody-codex/pane.json"

# Refuses without plan.md present (plan-phase must have completed).
rm "$TD/_execute/plan.md"
err=$(../bin/execute-design-implement-send.sh "$TOPIC" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && echo "$err" | grep -q 'plan.md' \
  || { echo "FAIL: should refuse without plan.md; rc=$rc out=$err" >&2; exit 1; }
pass "implement-send refuses without plan.md"
echo "plan body" > "$TD/_execute/plan.md"

# Idempotency: pre-populate state file → refuse.
echo "OFFSET=0" > "$TD/_execute/implement-cody.txt"
err=$(../bin/execute-design-implement-send.sh "$TOPIC" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && echo "$err" | grep -q 'already exists' \
  || { echo "FAIL: idempotency: rc=$rc out=$err" >&2; exit 1; }
pass "implement-send idempotency"
EOF
```

- [ ] **Step 8.2: Run — expect FAIL**

Run: `bash tests/test_execute_design_implement_send.sh`
Expected: `grep: ../bin/execute-design-implement-send.sh: No such file or directory`.

- [ ] **Step 8.3: Implement**

```bash
cat > bin/execute-design-implement-send.sh <<'EOF'
#!/usr/bin/env bash
# bin/execute-design-implement-send.sh — Phase 2 implement dispatch.
# Usage: bin/execute-design-implement-send.sh <topic>

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/execute_design.sh"

[[ $# -eq 1 ]] || { echo "Usage: $0 <topic>" >&2; exit 2; }
TOPIC="$1"
cw_execute_design_assert_topic "$TOPIC"

ART_DIR="$(cw_execute_design_art_dir "$TOPIC")"
[[ -d "$ART_DIR" ]] || { log_error "$ART_DIR not found — run init first"; exit 1; }

PLAN="$ART_DIR/plan.md"
[[ -f "$PLAN" && -s "$PLAN" ]] || { log_error "plan.md missing/empty at $PLAN — plan phase did not complete"; exit 1; }

STATE_FILE="$ART_DIR/implement-cody.txt"
[[ ! -e "$STATE_FILE" ]] || { log_error "$STATE_FILE already exists; rm to retry"; exit 1; }

TROOPER_DIR=$(cw_trooper_dir cody codex "$TOPIC")
OUTBOX="$TROOPER_DIR/outbox.jsonl"
[[ -f "$OUTBOX" ]] || { log_error "outbox not found at $OUTBOX"; exit 1; }

PROMPT_FILE="$ART_DIR/cody_implement_prompt.md"
cw_execute_design_build_implement_prompt "$PLAN" > "$PROMPT_FILE"

OFFSET=$(wc -c < "$OUTBOX" | tr -d ' ')
printf 'OFFSET=%s\n' "$OFFSET" > "$STATE_FILE"

if ! "$PLUGIN_ROOT/bin/send.sh" cody "$TOPIC" "@$PROMPT_FILE" >/dev/null; then
  log_error "send.sh failed; state file kept for retry"
  exit 1
fi

log_info "[implement-send] cody offset=$OFFSET"
EOF
chmod +x bin/execute-design-implement-send.sh
```

- [ ] **Step 8.4: Run — expect PASS**

Run: `bash tests/test_execute_design_implement_send.sh`
Expected: 3 pass lines.

- [ ] **Step 8.5: Commit**

```bash
git add bin/execute-design-implement-send.sh tests/test_execute_design_implement_send.sh
git commit -m "feat(execute-design): implement-send dispatch (task 8)"
```

---

## Task 9: bin/execute-design-implement-wait.sh

Same shape as plan-wait, with longer default timeout. Status field = `IS=`.

**Files:**
- Create: `bin/execute-design-implement-wait.sh`

- [ ] **Step 9.1: Write the script**

```bash
cat > bin/execute-design-implement-wait.sh <<'EOF'
#!/usr/bin/env bash
# bin/execute-design-implement-wait.sh — Phase 2 implement wait.
# Usage: bin/execute-design-implement-wait.sh <topic>

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/execute_design.sh"

[[ $# -eq 1 ]] || { echo "Usage: $0 <topic>" >&2; exit 2; }
TOPIC="$1"
cw_execute_design_assert_topic "$TOPIC"

ART_DIR="$(cw_execute_design_art_dir "$TOPIC")"
STATE_FILE="$ART_DIR/implement-cody.txt"
[[ -f "$STATE_FILE" ]] || { log_error "$STATE_FILE missing — run implement-send first"; exit 1; }
# shellcheck disable=SC1090
source "$STATE_FILE"
[[ -n "${OFFSET:-}" ]] || { log_error "OFFSET not set in $STATE_FILE"; exit 1; }

TIMEOUT="${CW_EXECUTE_IMPLEMENT_TIMEOUT:-7200}"
log_info "[implement-wait] cody offset=$OFFSET timeout=${TIMEOUT}s"

cw_outbox_wait_since cody codex "$TOPIC" "$OFFSET" done error "$TIMEOUT" >/dev/null || true

TROOPER_DIR=$(cw_trooper_dir cody codex "$TOPIC")
OUTBOX="$TROOPER_DIR/outbox.jsonl"
TAIL=$(tail -c "+$(( OFFSET + 1 ))" "$OUTBOX" 2>/dev/null || true)
MATCHED=$(printf '%s\n' "$TAIL" | grep -m1 -E '"event":"(done|error)"' || true)
EVENT=$(printf '%s' "$MATCHED" | sed -n 's/.*"event":"\([^"]*\)".*/\1/p')

case "$EVENT" in
  done)  printf 'IS=ok\n'      >> "$STATE_FILE"; log_info "[implement-wait] cody IS=ok" ;;
  error) printf 'IS=failed\n'  >> "$STATE_FILE"; log_warn "[implement-wait] cody IS=failed (error event)" ;;
  '')    printf 'IS=timeout\n' >> "$STATE_FILE"; log_warn "[implement-wait] cody IS=timeout" ;;
  *)     printf 'IS=failed\n'  >> "$STATE_FILE"; log_warn "[implement-wait] cody IS=failed (unknown event '$EVENT')" ;;
esac

touch "${STATE_FILE%.txt}.done"
exit 0
EOF
chmod +x bin/execute-design-implement-wait.sh
```

- [ ] **Step 9.2: Smoke-test**

Run:
```bash
bash -n bin/execute-design-implement-wait.sh && echo SYNTAX_OK
grep -q 'IS=ok\|IS=failed\|IS=timeout' bin/execute-design-implement-wait.sh && echo STATUS_OK
grep -q 'CW_EXECUTE_IMPLEMENT_TIMEOUT:-7200' bin/execute-design-implement-wait.sh && echo TIMEOUT_OK
```
Expected: three OK lines.

- [ ] **Step 9.3: Commit**

```bash
git add bin/execute-design-implement-wait.sh
git commit -m "feat(execute-design): implement-wait blocking (task 9)"
```

---

## Task 10: bin/execute-design-verify-send.sh

Per-round dispatch. Takes `<topic> <round>`. Writes `_execute/verify-cody-N.txt`. Configures the prompt with the per-round report path and test-output path.

**Files:**
- Create: `bin/execute-design-verify-send.sh`
- Create: `tests/test_execute_design_verify_send.sh`

- [ ] **Step 10.1: Write the failing test**

```bash
cat > tests/test_execute_design_verify_send.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

grep -q 'cw_execute_design_build_verify_prompt' ../bin/execute-design-verify-send.sh \
  || { echo "FAIL: missing verify-prompt builder" >&2; exit 1; }
grep -q 'verify-cody-' ../bin/execute-design-verify-send.sh \
  || { echo "FAIL: missing per-round filename" >&2; exit 1; }
grep -q 'verify-report-' ../bin/execute-design-verify-send.sh \
  || { echo "FAIL: missing report filename" >&2; exit 1; }
grep -q 'test-output-' ../bin/execute-design-verify-send.sh \
  || { echo "FAIL: missing test-output filename" >&2; exit 1; }
pass "verify-send static wiring"

RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
TOPIC=ver-send-fixture
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
mkdir -p "$TD/_execute" "$TD/cody-codex"
echo "design body" > "$TD/_execute/design.md"
touch "$TD/cody-codex/outbox.jsonl"
printf '{"pane_id":"%%77","spawned_at":"x"}\n' > "$TD/cody-codex/pane.json"

# Round must be a positive integer.
err=$(../bin/execute-design-verify-send.sh "$TOPIC" 0 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: round=0 accepted" >&2; exit 1; }
err=$(../bin/execute-design-verify-send.sh "$TOPIC" abc 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: round=abc accepted" >&2; exit 1; }
pass "verify-send rejects bad round"

# Idempotency for the same round.
echo "OFFSET=0" > "$TD/_execute/verify-cody-1.txt"
err=$(../bin/execute-design-verify-send.sh "$TOPIC" 1 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && echo "$err" | grep -q 'already exists' \
  || { echo "FAIL: same-round idempotency: rc=$rc out=$err" >&2; exit 1; }
pass "verify-send same-round idempotency"
EOF
```

- [ ] **Step 10.2: Run — expect FAIL**

Run: `bash tests/test_execute_design_verify_send.sh`
Expected: `grep: ... No such file`.

- [ ] **Step 10.3: Implement**

```bash
cat > bin/execute-design-verify-send.sh <<'EOF'
#!/usr/bin/env bash
# bin/execute-design-verify-send.sh — Phase 3 self-verify dispatch.
# Usage: bin/execute-design-verify-send.sh <topic> <round>

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/execute_design.sh"

[[ $# -eq 2 ]] || { echo "Usage: $0 <topic> <round>" >&2; exit 2; }
TOPIC="$1"; ROUND="$2"
cw_execute_design_assert_topic "$TOPIC"
[[ "$ROUND" =~ ^[1-9][0-9]*$ ]] || { log_error "round must be a positive integer; got '$ROUND'"; exit 2; }

ART_DIR="$(cw_execute_design_art_dir "$TOPIC")"
[[ -d "$ART_DIR" ]] || { log_error "$ART_DIR not found"; exit 1; }
DESIGN="$ART_DIR/design.md"
[[ -f "$DESIGN" ]] || { log_error "design.md missing"; exit 1; }

STATE_FILE="$ART_DIR/verify-cody-$ROUND.txt"
REPORT="$ART_DIR/verify-report-$ROUND.md"
TEST_LOG="$ART_DIR/test-output-$ROUND.log"
[[ ! -e "$STATE_FILE" ]] || { log_error "$STATE_FILE already exists; rm to retry round $ROUND"; exit 1; }

TROOPER_DIR=$(cw_trooper_dir cody codex "$TOPIC")
OUTBOX="$TROOPER_DIR/outbox.jsonl"
[[ -f "$OUTBOX" ]] || { log_error "outbox not found at $OUTBOX"; exit 1; }

PROMPT_FILE="$ART_DIR/cody_verify_prompt-$ROUND.md"
cw_execute_design_build_verify_prompt "$DESIGN" "$ROUND" "$REPORT" "$TEST_LOG" > "$PROMPT_FILE"

OFFSET=$(wc -c < "$OUTBOX" | tr -d ' ')
printf 'OFFSET=%s\n' "$OFFSET" > "$STATE_FILE"

if ! "$PLUGIN_ROOT/bin/send.sh" cody "$TOPIC" "@$PROMPT_FILE" >/dev/null; then
  log_error "send.sh failed; state file kept for retry"
  exit 1
fi

log_info "[verify-send] cody round=$ROUND offset=$OFFSET"
EOF
chmod +x bin/execute-design-verify-send.sh
```

- [ ] **Step 10.4: Run — expect PASS**

Run: `bash tests/test_execute_design_verify_send.sh`
Expected: 3 pass lines.

- [ ] **Step 10.5: Commit**

```bash
git add bin/execute-design-verify-send.sh tests/test_execute_design_verify_send.sh
git commit -m "feat(execute-design): verify-send per-round dispatch (task 10)"
```

---

## Task 11: bin/execute-design-verify-wait.sh

Per-round wait. Takes `<topic> <round>`. Status field = `VS=`.

**Files:**
- Create: `bin/execute-design-verify-wait.sh`

- [ ] **Step 11.1: Write the script**

```bash
cat > bin/execute-design-verify-wait.sh <<'EOF'
#!/usr/bin/env bash
# bin/execute-design-verify-wait.sh — Phase 3 self-verify wait.
# Usage: bin/execute-design-verify-wait.sh <topic> <round>

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/execute_design.sh"

[[ $# -eq 2 ]] || { echo "Usage: $0 <topic> <round>" >&2; exit 2; }
TOPIC="$1"; ROUND="$2"
cw_execute_design_assert_topic "$TOPIC"
[[ "$ROUND" =~ ^[1-9][0-9]*$ ]] || { log_error "round must be a positive integer; got '$ROUND'"; exit 2; }

ART_DIR="$(cw_execute_design_art_dir "$TOPIC")"
STATE_FILE="$ART_DIR/verify-cody-$ROUND.txt"
[[ -f "$STATE_FILE" ]] || { log_error "$STATE_FILE missing — run verify-send first"; exit 1; }
# shellcheck disable=SC1090
source "$STATE_FILE"
[[ -n "${OFFSET:-}" ]] || { log_error "OFFSET not set in $STATE_FILE"; exit 1; }

TIMEOUT="${CW_EXECUTE_VERIFY_TIMEOUT:-1200}"
log_info "[verify-wait] cody round=$ROUND offset=$OFFSET timeout=${TIMEOUT}s"

cw_outbox_wait_since cody codex "$TOPIC" "$OFFSET" done error "$TIMEOUT" >/dev/null || true

TROOPER_DIR=$(cw_trooper_dir cody codex "$TOPIC")
OUTBOX="$TROOPER_DIR/outbox.jsonl"
TAIL=$(tail -c "+$(( OFFSET + 1 ))" "$OUTBOX" 2>/dev/null || true)
MATCHED=$(printf '%s\n' "$TAIL" | grep -m1 -E '"event":"(done|error)"' || true)
EVENT=$(printf '%s' "$MATCHED" | sed -n 's/.*"event":"\([^"]*\)".*/\1/p')

REPORT="$ART_DIR/verify-report-$ROUND.md"
case "$EVENT" in
  done)
    if [[ -f "$REPORT" && -s "$REPORT" ]]; then
      printf 'VS=ok\n' >> "$STATE_FILE"
      log_info "[verify-wait] cody round=$ROUND VS=ok"
    else
      printf 'VS=failed\n' >> "$STATE_FILE"
      log_warn "[verify-wait] cody round=$ROUND VS=failed (done but report empty/missing)"
    fi
    ;;
  error) printf 'VS=failed\n'  >> "$STATE_FILE"; log_warn "[verify-wait] cody round=$ROUND VS=failed (error)" ;;
  '')    printf 'VS=timeout\n' >> "$STATE_FILE"; log_warn "[verify-wait] cody round=$ROUND VS=timeout" ;;
  *)     printf 'VS=failed\n'  >> "$STATE_FILE"; log_warn "[verify-wait] cody round=$ROUND VS=failed (unknown event)" ;;
esac

touch "${STATE_FILE%.txt}.done"
exit 0
EOF
chmod +x bin/execute-design-verify-wait.sh
```

- [ ] **Step 11.2: Smoke-test**

Run:
```bash
bash -n bin/execute-design-verify-wait.sh && echo SYNTAX_OK
grep -q 'VS=ok\|VS=failed\|VS=timeout' bin/execute-design-verify-wait.sh && echo STATUS_OK
grep -q 'verify-report-' bin/execute-design-verify-wait.sh && echo REPORT_OK
```
Expected: three OK lines.

- [ ] **Step 11.3: Commit**

```bash
git add bin/execute-design-verify-wait.sh
git commit -m "feat(execute-design): verify-wait per-round blocking (task 11)"
```

---

## Task 12: bin/execute-design-fix-send.sh

Per-round fix dispatch. Takes `<topic> <round> [<variant>]`. The slash directive writes `fix-prompt-N.md` (or split `-N-debug.md` / `-N-gap.md`) before invoking; the script just builds the inbox prompt that points to it.

**Files:**
- Create: `bin/execute-design-fix-send.sh`
- Create: `tests/test_execute_design_fix_send.sh`

- [ ] **Step 12.1: Write the failing test**

```bash
cat > tests/test_execute_design_fix_send.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

grep -q 'cw_execute_design_build_fix_prompt' ../bin/execute-design-fix-send.sh \
  || { echo "FAIL: missing fix-prompt builder" >&2; exit 1; }
grep -q 'fix-prompt-' ../bin/execute-design-fix-send.sh \
  || { echo "FAIL: missing fix-prompt filename" >&2; exit 1; }
pass "fix-send static wiring"

RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
TOPIC=fix-send-fixture
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
mkdir -p "$TD/_execute" "$TD/cody-codex"
touch "$TD/cody-codex/outbox.jsonl"
printf '{"pane_id":"%%66","spawned_at":"x"}\n' > "$TD/cody-codex/pane.json"

# Refuses if fix-prompt-N.md missing.
err=$(../bin/execute-design-fix-send.sh "$TOPIC" 1 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && echo "$err" | grep -q 'fix-prompt' \
  || { echo "FAIL: missing fix-prompt should refuse: rc=$rc out=$err" >&2; exit 1; }
pass "fix-send refuses without fix-prompt-N.md"

# With variant: looks for fix-prompt-N-<variant>.md
echo "preamble" > "$TD/_execute/fix-prompt-1-debug.md"
out=$(../bin/execute-design-fix-send.sh "$TOPIC" 1 debug 2>&1) || rc=$?
# (send.sh will fail because pane is fake; we only care that the script
# accepted the variant + located the file before send.sh's failure.)
echo "$out" | grep -q 'fix-prompt-1-debug.md' \
  || { echo "FAIL: variant not used in prompt body: $out" >&2; exit 1; }
pass "fix-send accepts -<variant> suffix"
EOF
```

- [ ] **Step 12.2: Run — expect FAIL**

Run: `bash tests/test_execute_design_fix_send.sh`
Expected: `grep: ... No such file or directory`.

- [ ] **Step 12.3: Implement**

```bash
cat > bin/execute-design-fix-send.sh <<'EOF'
#!/usr/bin/env bash
# bin/execute-design-fix-send.sh — Phase 5 fix dispatch.
# Usage: bin/execute-design-fix-send.sh <topic> <round> [<variant>]
#
# Looks for $ART_DIR/fix-prompt-<round>[-<variant>].md and tells codex to
# read it. The slash directive must have written that file (with a skill
# preamble) before invoking. Optionally bumps the verify-cody-N.txt to
# next round for the directive's wait flow — but that's the directive's
# responsibility, not this script's.

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/execute_design.sh"

[[ $# -ge 2 && $# -le 3 ]] || { echo "Usage: $0 <topic> <round> [<variant>]" >&2; exit 2; }
TOPIC="$1"; ROUND="$2"; VARIANT="${3:-}"
cw_execute_design_assert_topic "$TOPIC"
[[ "$ROUND" =~ ^[1-9][0-9]*$ ]] || { log_error "round must be a positive integer; got '$ROUND'"; exit 2; }

ART_DIR="$(cw_execute_design_art_dir "$TOPIC")"
[[ -d "$ART_DIR" ]] || { log_error "$ART_DIR not found"; exit 1; }

if [[ -n "$VARIANT" ]]; then
  FIX="$ART_DIR/fix-prompt-$ROUND-$VARIANT.md"
else
  FIX="$ART_DIR/fix-prompt-$ROUND.md"
fi
[[ -f "$FIX" && -s "$FIX" ]] || { log_error "fix-prompt missing/empty: $FIX (the directive must write it before invoking)"; exit 1; }

TROOPER_DIR=$(cw_trooper_dir cody codex "$TOPIC")
OUTBOX="$TROOPER_DIR/outbox.jsonl"
[[ -f "$OUTBOX" ]] || { log_error "outbox not found at $OUTBOX"; exit 1; }

PROMPT_FILE="$ART_DIR/cody_fix_prompt-$ROUND${VARIANT:+-$VARIANT}.md"
cw_execute_design_build_fix_prompt "$FIX" > "$PROMPT_FILE"

if ! "$PLUGIN_ROOT/bin/send.sh" cody "$TOPIC" "@$PROMPT_FILE" >/dev/null; then
  log_error "send.sh failed"
  exit 1
fi

log_info "[fix-send] cody round=$ROUND variant=${VARIANT:-<none>} ($FIX)"
EOF
chmod +x bin/execute-design-fix-send.sh
```

- [ ] **Step 12.4: Run — expect PASS**

Run: `bash tests/test_execute_design_fix_send.sh`
Expected: 3 pass lines.

- [ ] **Step 12.5: Commit**

```bash
git add bin/execute-design-fix-send.sh tests/test_execute_design_fix_send.sh
git commit -m "feat(execute-design): fix-send dispatch with optional variant (task 12)"
```

---

## Task 13: Teardown + Archive

Both are thin wrappers; mirror `bin/consult-{teardown,archive}.sh`.

**Files:**
- Create: `bin/execute-design-teardown.sh`
- Create: `bin/execute-design-archive.sh`
- Create: `tests/test_execute_design_archive.sh`

- [ ] **Step 13.1: Write the failing archive test**

```bash
cat > tests/test_execute_design_archive.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
TOPIC=archive-fixture
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
mkdir -p "$TD/_execute"
echo "design" > "$TD/_execute/design.md"
echo "plan"   > "$TD/_execute/plan.md"

../bin/execute-design-archive.sh "$TOPIC"

ARCHIVE_BASE="$CLONE_WARS_HOME/archive/$RH/$TOPIC"
[[ -d "$ARCHIVE_BASE" ]] || { echo "FAIL: archive base missing" >&2; exit 1; }
n=$(ls "$ARCHIVE_BASE" | grep -c '^_execute-' || true)
[[ "$n" -eq 1 ]] || { echo "FAIL: expected exactly one _execute-* dir, got $n" >&2; exit 1; }
[[ ! -d "$TD/_execute" ]] || { echo "FAIL: source _execute/ still present" >&2; exit 1; }
pass "archive moves _execute → archive/_execute-<ts>"

# Refuses if _execute/ missing.
err=$(../bin/execute-design-archive.sh "$TOPIC" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: should refuse already-archived" >&2; exit 1; }
pass "archive refuses already-archived"
EOF
```

- [ ] **Step 13.2: Run — expect FAIL**

Run: `bash tests/test_execute_design_archive.sh`
Expected: `bash: ../bin/execute-design-archive.sh: No such file or directory`.

- [ ] **Step 13.3: Implement archive + teardown**

```bash
cat > bin/execute-design-archive.sh <<'EOF'
#!/usr/bin/env bash
# bin/execute-design-archive.sh — move _execute/ to archive.
# Usage: bin/execute-design-archive.sh <topic>

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/execute_design.sh"

[[ $# -eq 1 ]] || { echo "Usage: $0 <topic>" >&2; exit 2; }
TOPIC="$1"
cw_execute_design_assert_topic "$TOPIC"

TOPIC_DIR="$(cw_execute_design_topic_dir "$TOPIC")"
ART_DIR="$TOPIC_DIR/_execute"
[[ -d "$ART_DIR" ]] || { log_error "$ART_DIR missing — already archived?"; exit 1; }

ARCHIVE_BASE="$(cw_state_root)/archive/$(cw_repo_hash)/$TOPIC"
mkdir -p "$ARCHIVE_BASE"
TS=$(date -u +'%Y%m%dT%H%M%SZ')
mv "$ART_DIR" "$ARCHIVE_BASE/_execute-$TS"
rmdir "$TOPIC_DIR" 2>/dev/null || true

log_ok "archived: $ARCHIVE_BASE/_execute-$TS"
EOF
chmod +x bin/execute-design-archive.sh

cat > bin/execute-design-teardown.sh <<'EOF'
#!/usr/bin/env bash
# bin/execute-design-teardown.sh — kill cody pane via shared teardown.
# Usage: bin/execute-design-teardown.sh <topic>

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/execute_design.sh"

[[ $# -eq 1 ]] || { echo "Usage: $0 <topic>" >&2; exit 2; }
TOPIC="$1"
cw_execute_design_assert_topic "$TOPIC"

"$PLUGIN_ROOT/bin/teardown.sh" "$TOPIC"
EOF
chmod +x bin/execute-design-teardown.sh
```

- [ ] **Step 13.4: Run archive test — expect PASS**

Run: `bash tests/test_execute_design_archive.sh`
Expected: 2 pass lines.

- [ ] **Step 13.5: Commit**

```bash
git add bin/execute-design-archive.sh bin/execute-design-teardown.sh tests/test_execute_design_archive.sh
git commit -m "feat(execute-design): teardown + archive wrappers (task 13)"
```

---

## Task 14: commands/execute-design.md (slash directive)

The directive is the only piece that needs all sub-scripts present. It mirrors `commands/consult.md`'s structure: TaskCreate × N upfront, args-file pattern for the design-doc path, then sub-script invocations interleaved with task-status updates.

**Files:**
- Create: `commands/execute-design.md`

- [ ] **Step 14.1: Write the slash directive**

```bash
cat > commands/execute-design.md <<'EOF'
---
description: Audit a design doc, dispatch it to a Codex trooper for plan/implement/self-verify, then cross-verify and fix-loop until PASS or 5 rounds.
argument-hint: [<design-path>] [--no-branch] [--branch <name>] [--topic <slug>] [--max-rounds 5]
---

# /clone-wars:execute-design

Run a Codex-implements / Yoda-verifies pipeline on `$ARGUMENTS`. Master Yoda
audits the design doc; spawns one persistent Codex trooper (`cody-codex-<topic>`);
delegates plan + implementation + self-verification to the trooper using
superpowers skills; and cross-verifies after every codex self-verify pass,
sending fix bundles back until PASS or 5 rounds (then `AskUserQuestion`).

The cody pane stays attached for the entire run — `tmux select-pane` to watch.

Spec: `docs/superpowers/specs/2026-05-02-clone-wars-execute-design.md`

## Source defaulting

If `$ARGUMENTS` does not include a `.md` path, look for the most recent
`state/<repo-hash>/consult-*/synthesis.md` under `$CLONE_WARS_HOME` and prompt
the user via `AskUserQuestion` to confirm. If no synthesis.md is found and no
explicit path was given, refuse with a usage hint.

## Task list (TaskCreate × 8 BEFORE step 0)

| # | subject | activeForm |
|---|---|---|
| 0   | `0   Audit design doc [yoda]`               | `Auditing design doc` |
| 1.1 | `1.1 Spawn cody (codex) [yoda]`             | `Spawning cody` |
| 1.2 | `1.2 Plan [cody/codex]`                     | `Cody planning` |
| 1.3 | `1.3 Implement [cody/codex]`                | `Cody implementing` |
| 2.1 | `2.1 Self-verify [cody/codex]`              | `Cody self-verifying` |
| 2.2 | `2.2 Cross-verify [yoda]`                   | `Yoda cross-verifying` |
| 3   | `3   Fix loop (if needed) [yoda + cody]`    | `Running fix loop` |
| 4   | `4   Teardown + archive [yoda]`             | `Tearing down` |

## Steps

The user's `$ARGUMENTS` may contain shell metacharacters. Write it via the
Write tool, then invoke sub-scripts with the resolved values.

### Step 0 — Audit design doc

Set task `0` → `in_progress`.

1. Resolve args path:
   ```
   ARGS_DIR="${CLONE_WARS_HOME:-$HOME/.clone-wars}/_args"
   mkdir -p "$ARGS_DIR"; echo "$ARGS_DIR/execute-design.txt"
   ```
2. Write tool: `file_path` = the path printed; `content` = `$ARGUMENTS` exactly.
3. Parse `--source <path>`, `--topic <slug>`, `--no-branch`, `--branch <name>`,
   `--max-rounds <n>` (default 5) from the args file. The remaining positional
   token (if any) is the design-doc path.
4. If no design-doc path is given, find the most recent
   `state/$REPO_HASH/consult-*/synthesis.md` and offer it via
   `AskUserQuestion` (options: "Use this", "Cancel"). Cancel → exit 0.
5. Init:
   ```
   source "$CLAUDE_PLUGIN_ROOT/lib/state.sh"
   REPO_HASH=$(cw_repo_hash)
   TOPIC=$("$CLAUDE_PLUGIN_ROOT/bin/execute-design-init.sh" \
              ${NO_BRANCH:+--no-branch} \
              ${BRANCH_OVERRIDE:+--branch "$BRANCH_OVERRIDE"} \
              ${TOPIC_OVERRIDE:+--topic "$TOPIC_OVERRIDE"} \
              "$DESIGN_PATH")
   TOPIC_DIR="${CLONE_WARS_HOME:-$HOME/.clone-wars}/state/$REPO_HASH/$TOPIC"
   ART_DIR="$TOPIC_DIR/_execute"
   ```
6. Run audit and persist verdict:
   ```
   source "$CLAUDE_PLUGIN_ROOT/lib/execute_design.sh"
   AUDIT=$(cw_execute_design_audit_doc "$ART_DIR/design.md" 2>&1) && AUDIT_RC=0 || AUDIT_RC=$?
   printf '%s\n' "$AUDIT" > "$ART_DIR/design-audit.md"
   ```
7. If `AUDIT_RC != 0`: read the design doc yourself, weigh the flagged issues,
   and use `AskUserQuestion` (options: "Proceed anyway", "Abort and edit doc").
   Abort → run `bin/execute-design-archive.sh` and exit. Proceed → continue.

Set task `0` → `completed`.

### Step 1.1 — Spawn cody-codex

Set task `1.1` → `in_progress`.
```
"$CLAUDE_PLUGIN_ROOT/bin/spawn.sh" cody codex "$TOPIC"
```
Set task `1.1` → `completed`. If spawn fails, archive `_execute/` and exit.

### Step 1.2 — Plan

Set task `1.2` → `in_progress`.
```
"$CLAUDE_PLUGIN_ROOT/bin/execute-design-plan-send.sh" "$TOPIC"
"$CLAUDE_PLUGIN_ROOT/bin/execute-design-plan-wait.sh" "$TOPIC"
```
Read the last `PS=` line from `$ART_DIR/plan-cody.txt`:
- `PS=ok` → set task `1.2` → `completed`.
- `PS=failed`/`PS=timeout` → AskUserQuestion (Retry / Abort). Retry: `rm
  $ART_DIR/plan-cody.txt $ART_DIR/plan-cody.done` then re-run the two
  scripts. Abort: teardown + archive + exit.

**Yoda does not read `plan.md`.**

### Step 1.3 — Implement

Set task `1.3` → `in_progress`.
```
"$CLAUDE_PLUGIN_ROOT/bin/execute-design-implement-send.sh" "$TOPIC"
"$CLAUDE_PLUGIN_ROOT/bin/execute-design-implement-wait.sh" "$TOPIC"
```
Read `IS=` from `implement-cody.txt`:
- `IS=ok` → set task `1.3` → `completed`.
- `IS=failed`/`IS=timeout` → read last 30 lines of cody outbox; AskUserQuestion
  (Retry / Hand-off / Abort). Retry: same pattern as plan.

### Step 2 — Verify-fix loop

Initialize:
```
ROUND=1
MAX_ROUNDS="${MAX_ROUNDS_OVERRIDE:-5}"
```

Loop while `ROUND <= MAX_ROUNDS + 1`:

#### Step 2.1 — Self-verify (per round)

Set task `2.1` → `in_progress` (use the same task across rounds; only the
activeForm reflects round number).
```
"$CLAUDE_PLUGIN_ROOT/bin/execute-design-verify-send.sh" "$TOPIC" "$ROUND"
"$CLAUDE_PLUGIN_ROOT/bin/execute-design-verify-wait.sh" "$TOPIC" "$ROUND"
```
Read `VS=` from `verify-cody-$ROUND.txt`. On non-`ok` status, AskUserQuestion
the same way as the implement phase.

Set task `2.1` → `completed` for this round.

#### Step 2.2 — Cross-verify (per round)

Set task `2.2` → `in_progress`.

**Skill:** invoke `superpowers:verification-before-completion`.

Yoda's reads (capped):
- `$ART_DIR/verify-report-$ROUND.md`
- `$ART_DIR/test-output-$ROUND.log` (grep tail for pass/fail counts)
- `git log --oneline <branch-base>..HEAD`
- `git diff --stat <branch-base>..HEAD`
- Up to 3 spot-checks: pick the highest-stakes diff hunk per critical
  requirement and Read just that hunk.

Write the verdict to `$ART_DIR/cross-verify-$ROUND.md`:
- Top-line `VERDICT: PASS` or `VERDICT: FAIL`.
- If FAIL: bullet list of issues, each tagged `[bug]`, `[regression]`, or
  `[spec-gap]`, with (a) requirement reference, (b) evidence (file:line or
  commit), (c) suggested fix direction.

If `VERDICT: PASS` → set task `2.2` → `completed`, exit the loop, jump to
Step 4.

If `VERDICT: FAIL` and `ROUND > MAX_ROUNDS`:
- Write `$ART_DIR/RESUME.md` with the topic dir, branch name, latest
  cross-verify summary, and instructions for manual takeover.
- AskUserQuestion: "5 fix rounds exhausted. Continue (1 more round) /
  Hand off (preserve state) / Abort (teardown + archive)." Default: hand off.
- Hand off: log the topic dir + RESUME.md path, exit (do not teardown). Set
  task `3` → `completed` and task `4` → `completed` with note.
- Abort: teardown + archive, exit.
- Continue: increment `MAX_ROUNDS` by 1 and continue the loop.

If `VERDICT: FAIL` and `ROUND <= MAX_ROUNDS` → continue to Step 3.

#### Step 3 — Fix-prompt + dispatch

Set task `3` → `in_progress`.

Group issues from `cross-verify-$ROUND.md` by tag:
- `[bug]` and `[regression]` → bundle preamble names
  `superpowers:systematic-debugging`.
- `[spec-gap]` → bundle preamble names `superpowers:writing-plans` (replan)
  → then implement.

If the cross-verify mixes both, write **two** files:
- `$ART_DIR/fix-prompt-$ROUND-debug.md` (bugs/regressions)
- `$ART_DIR/fix-prompt-$ROUND-gap.md` (spec gaps)

If only one classification, write a single `$ART_DIR/fix-prompt-$ROUND.md`.

Each file's preamble (one short paragraph at the top) must:
- Name the required skill (`superpowers:systematic-debugging` or
  `superpowers:writing-plans`).
- Tell codex to commit per fix and re-run the full test suite after each.
- Forbid skipping any listed issue.

Then dispatch (in order — debug first if both):
```
# debug bundle (if any)
"$CLAUDE_PLUGIN_ROOT/bin/execute-design-fix-send.sh" "$TOPIC" "$ROUND" debug
# wait for done by re-running the verify-wait — but verify-wait
# expects its own state file. The fix-send doesn't update VS=; instead,
# we wait by polling the outbox for the next done event past the current
# OFFSET. Simplest path: re-run the verify cycle for round N+1.

# gap bundle (if any)
"$CLAUDE_PLUGIN_ROOT/bin/execute-design-fix-send.sh" "$TOPIC" "$ROUND" gap
```

Increment `ROUND`. Loop back to Step 2.1 (which dispatches verify-send for
the new round; codex's done event from the fix is consumed by the next
verify-wait).

### Step 4 — Teardown + archive

Set task `4` → `in_progress`.
```
"$CLAUDE_PLUGIN_ROOT/bin/execute-design-teardown.sh" "$TOPIC"
"$CLAUDE_PLUGIN_ROOT/bin/execute-design-archive.sh" "$TOPIC"
```

Print final summary to the user:
- Branch name (with commit count from `git log --oneline <base>..HEAD`).
- Final cross-verify verdict (PASS or hand-off note).
- Archive path.

Set task `4` → `completed`.

## Intervention patterns

### Abandoned run cleanup
If a previous run wedged (panes alive, state intact), tear down explicitly:
```
"$CLAUDE_PLUGIN_ROOT/bin/execute-design-teardown.sh" <topic>
"$CLAUDE_PLUGIN_ROOT/bin/execute-design-archive.sh" <topic>
```

### Manual takeover (after hand-off)
The cody pane stays alive after a 5-round hand-off. Attach:
```
tmux select-pane -t <pane_id>   # printed by spawn.sh
```
Use the cody session directly. RESUME.md in `$ART_DIR/` documents context.
EOF
```

- [ ] **Step 14.2: Verify the directive's static structure**

Run:
```bash
grep -q '/clone-wars:execute-design' commands/execute-design.md && echo TITLE_OK
grep -q 'Spec:.*2026-05-02-clone-wars-execute-design.md' commands/execute-design.md && echo SPEC_REF_OK
grep -q 'TaskCreate × 8 BEFORE' commands/execute-design.md && echo TASK_HEADER_OK
grep -q 'execute-design-init.sh' commands/execute-design.md && echo INIT_REF_OK
grep -q 'execute-design-verify-send.sh' commands/execute-design.md && echo VERIFY_SEND_REF_OK
grep -q 'execute-design-fix-send.sh' commands/execute-design.md && echo FIX_SEND_REF_OK
grep -q 'execute-design-teardown.sh' commands/execute-design.md && echo TEARDOWN_REF_OK
grep -q 'superpowers:writing-plans' commands/execute-design.md && echo SKILL_PLAN_REF_OK
grep -q 'superpowers:subagent-driven-development' commands/execute-design.md && echo SKILL_IMPL_REF_OK
grep -q 'superpowers:verification-before-completion' commands/execute-design.md && echo SKILL_VERIFY_REF_OK
grep -q 'superpowers:systematic-debugging' commands/execute-design.md && echo SKILL_DEBUG_REF_OK
```
Expected: all 11 OK lines.

- [ ] **Step 14.3: Commit**

```bash
git add commands/execute-design.md
git commit -m "feat(execute-design): slash directive (task 14)"
```

---

## Task 15: medic update + README + dogfood gate

**Files:**
- Modify: `bin/medic.sh`
- Modify: `tests/run.sh`
- Modify: `README.md`
- Modify: `CLAUDE.md`
- Create: `tests/test_execute_design_v060_dogfood.sh`

- [ ] **Step 15.1: Add execute_design.sh source check to medic**

Find the existing config-file check section in `bin/medic.sh` and append the
helper-source sanity (right after the `lib/consult.sh` source check if there
is one; otherwise after the deps section).

Locate the right anchor:
```bash
grep -n 'lib/consult.sh\|source.*lib/' bin/medic.sh
```

Then add a check that the new lib loads without error. Example:
```bash
# Anchor (search for): 'medic exit code summary' or similar trailing block.
# Insert just before the verdict-print section:
( source "$PLUGIN_ROOT/lib/state.sh" \
  && source "$PLUGIN_ROOT/lib/log.sh" \
  && source "$PLUGIN_ROOT/lib/consult.sh" \
  && source "$PLUGIN_ROOT/lib/execute_design.sh" \
  && cw_execute_design_topic_dir test-topic >/dev/null ) \
  && log_ok "execute_design helpers load clean" \
  || { log_warn "execute_design helpers FAILED to load"; status=1; }
```

(Adapt the variable names to match medic.sh's existing pattern — it uses
`status=1` or `WARN`/`OK` glyphs; do not invent a new pattern.)

- [ ] **Step 15.2: Run medic locally — expect it still says OK**

Run: `bash bin/medic.sh`
Expected: an additional `OK` line for `execute_design helpers load clean`,
overall verdict still `OK`.

- [ ] **Step 15.3: Add the v060 dogfood file (skipped from auto-run)**

```bash
cat > tests/test_execute_design_v060_dogfood.sh <<'EOF'
#!/usr/bin/env bash
# tests/test_execute_design_v060_dogfood.sh
# MANUAL release gate — exercises the full /clone-wars:execute-design pipeline
# end-to-end against a real Codex trooper. Skipped from tests/run.sh because
# it requires tmux + a running codex CLI + can take 20+ minutes.
#
# Run explicitly:
#   bash tests/test_execute_design_v060_dogfood.sh
set -euo pipefail
echo "Manual release gate. Steps:"
echo "  1. Pick a small design doc under docs/superpowers/specs/."
echo "  2. From a tmux session: /clone-wars:execute-design <design-path>"
echo "  3. Confirm: cody-codex pane spawns, plan.md is written, implementation"
echo "     commits land on feat/exec-<topic>, cross-verify reports PASS within"
echo "     5 rounds, archive happens cleanly."
echo "  4. Confirm: bash tests/run.sh stays green on the new branch."
echo
echo "Pass criteria documented in:"
echo "  docs/superpowers/specs/2026-05-02-clone-wars-execute-design.md §Success criteria"
exit 0
EOF
chmod +x tests/test_execute_design_v060_dogfood.sh
```

- [ ] **Step 15.4: Add the dogfood test to the skip-list**

Edit `tests/run.sh` and add a new `case` arm. Locate the existing
`test_consult_v050_dogfood.sh` arm and add right after:
```
    test_execute_design_v060_dogfood.sh)
      echo "=== $t === (SKIP — manual v0.6.0 dogfood, run explicitly)"
      continue ;;
```

- [ ] **Step 15.5: Run the full suite — expect everything green**

Run: `bash tests/run.sh`
Expected: existing tests all PASS, new tests
(`test_execute_design_helpers.sh`, `test_execute_design_init.sh`,
`test_execute_design_plan_send.sh`,
`test_execute_design_implement_send.sh`,
`test_execute_design_verify_send.sh`,
`test_execute_design_fix_send.sh`,
`test_execute_design_archive.sh`) all PASS, dogfood test SKIPPED.

- [ ] **Step 15.6: Update README.md command table**

Open README.md, find the slash-command table, and add a row for
`/clone-wars:execute-design`. Keep the description to one line:
```markdown
| `/clone-wars:execute-design [<design-path>]` | Codex implements + Yoda verifies a design doc. |
```

Then add a one-paragraph quickstart under whatever section currently
describes `/clone-wars:consult` workflow:

> **Implementing a design doc.** After `/clone-wars:consult` produces a
> synthesis, run `/clone-wars:execute-design` to hand the doc to a Codex
> trooper for plan-writing, implementation, and self-verification. Master
> Yoda audits the doc up front and cross-verifies after every codex pass,
> sending bundled fix prompts back until cross-verify reports PASS or 5
> rounds elapse (then prompts for hand-off).

- [ ] **Step 15.7: Update CLAUDE.md status checklist**

Find the existing status block (under `## Status`) and add a checked line:
```markdown
- [x] v0.6.0: execute-design — codex-implements + yoda-verifies pipeline
```

Place it immediately after the existing `- [x] v0.5.3:` line.

- [ ] **Step 15.8: Final commit**

```bash
git add bin/medic.sh tests/run.sh tests/test_execute_design_v060_dogfood.sh README.md CLAUDE.md
git commit -m "feat(execute-design): medic check + dogfood gate + docs (task 15)

Closes v0.6.0 implementation. Manual release gate:
  bash tests/test_execute_design_v060_dogfood.sh"
```

- [ ] **Step 15.9: Run the full test suite one more time before opening the PR**

Run: `bash tests/run.sh`
Expected: green.

---

## Self-review

**Spec coverage check** (`docs/superpowers/specs/2026-05-02-clone-wars-execute-design.md`):

| Spec section | Implemented in |
|---|---|
| Topic slug derivation | Task 1 (`derive_topic`) + Task 5 (init) |
| Source defaulting | Task 14 (slash directive Step 0) |
| Branch model + dirty-tree refusal | Task 3 (`branch_create`) + Task 5 (init) |
| State layout `_execute/` | Task 5 (init creates dir) + Tasks 6–13 (per-phase files) |
| Per-round suffixes | Tasks 10, 11, 12 (`-N` filename pattern) |
| Phase 0 audit | Task 2 (`audit_doc`) + Task 14 (directive runs + writes verdict) |
| Phase 1 plan (binds writing-plans) | Task 4 (prompt builder) + Tasks 6, 7 |
| Phase 2 implement (binds subagent-driven-development) | Task 4 + Tasks 8, 9 |
| Phase 3 self-verify (binds verification-before-completion + test-output capture) | Task 4 + Tasks 10, 11 |
| Phase 4 cross-verify (binds verification-before-completion, classifies issues) | Task 14 (directive runs the skill) |
| Phase 5 fix dispatch (skill routing) | Task 4 (prompt builder names file) + Task 12 (variant suffix) + Task 14 (directive writes preamble + classifies) |
| Round budget cap + RESUME.md | Task 14 (directive) |
| Phase 6 teardown + archive | Task 13 |
| Token budget table | Architecture is enforced by the directive's "Yoda does not read plan.md" instruction (Task 14) and by capped reads in Step 2.2 (Task 14) |
| Success criteria #3 (cross-verify catches ≥1 issue codex missed) | Validated only by Task 15 dogfood (manual gate) |

**Placeholder scan:** Each step contains either complete code blocks, exact
commands, or a single-purpose markdown body. No `TBD`, `implement later`, or
"add appropriate error handling" lines.

**Type/path consistency:** Status field naming (`PS=`, `IS=`, `VS=`) is
consistent across Tasks 6–11. State filenames (`plan-cody.txt`,
`implement-cody.txt`, `verify-cody-N.txt`) follow a single pattern. Phase
prompt builder signatures (`cw_execute_design_build_*_prompt`) match between
the helper definitions in Task 4 and their usages in Tasks 6, 8, 10, 12.
Branch name `feat/exec-<topic>` is consistent across the spec, Task 3, and
Task 14.

---

## Open questions for the implementer

These intentionally remain underspecified — the implementer (codex) decides:

1. **Audit failure UX.** The spec says "abort and re-run" is the lean default;
   the directive (Task 14) implements `Proceed anyway / Abort` via
   AskUserQuestion. If the implementer wants to add a third option ("open
   editor + pause"), that is fine but not required.
2. **Fix-loop wait protocol.** Task 14 Step 3 notes that the fix dispatch
   does not update `VS=`; the wait happens via the next round's verify-wait.
   That is the intended design (it keeps `VS=` per-round consistent), but the
   implementer may add a sentinel file (`fix-cody-N.done`) if they find the
   directive needs an explicit wait between fix-send and verify-send.
3. **Plan-doc canonical path.** The spec leaves open whether codex's
   writing-plans output should also persist under
   `docs/superpowers/plans/`. Current implementation (Task 4 prompt) writes
   to `_execute/plan.md` only. If the dogfood reveals plan persistence is
   useful, follow up with a v0.6.1 patch that symlinks or copies after the
   plan phase.
