# Deploy Sub-Repo Redirect Implementation Plan (v0.10.0)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `/clone-wars:deploy` redirect into a sub-repo when the design doc declares a `**Target Sub-Project:** <slug>` header, with the trooper's pane / branch / state / provider auto-detection all happening inside the sub-repo. Make `/clone-wars:consult`'s design-doc walk ask for the header in hub repos.

**Architecture:** Two new `lib/deploy.sh` helpers (`cw_deploy_extract_target` + `cw_deploy_resolve_target`) parse the header and validate the sub-repo path. One audit gate (`target_subproject_when_invalid`) rejects malformed slugs. `bin/deploy-init.sh` writes the resolved cwd to `_deploy/target_cwd.txt` and uses it for branch-create + provider detect + state-path hashing (via a new `cw_repo_hash_for <cwd>` helper in `lib/state.sh`). `bin/spawn.sh` learns a `--cwd <abs-path>` flag for the trooper pane. `commands/deploy.md` reads `target_cwd.txt` and threads it through Step 1.1 spawn + Step 2 cross-verify (`git -C "$TARGET_CWD"`). `commands/consult.md` Step 8.5 calls a new `cw_consult_detect_hub` helper and asks the user via `AskUserQuestion`.

**Tech Stack:** bash 4.2+, file IPC (atomic tmp+rename writes via existing `cw_atomic_write`), tmux split-window `-c <cwd>`, `git -C <repo>` discipline (the conductor never `cd`s into the sub-repo).

**Spec:** `docs/superpowers/specs/2026-05-04-deploy-sub-repo-redirect-design.md` (committed `b9ab70e`)

---

## File Map

| File | Action | Notes |
|---|---|---|
| `lib/state.sh` | modify | Add `cw_repo_hash_for <cwd>`; refactor existing `cw_repo_hash` to delegate (Task 1) |
| `lib/deploy.sh` | modify | Add `cw_deploy_extract_target` (Task 2); add `cw_deploy_resolve_target` (Task 3); extend `cw_deploy_audit_doc` audit gate (Task 3) |
| `bin/spawn.sh` | modify | Add `--cwd <abs-path>` flag parsing + `tmux split-window -c` integration (Task 4) |
| `bin/deploy-init.sh` | modify | Wire detector + sub-repo branch + sub-repo provider + sub-repo-keyed state path (Task 5) |
| `bin/medic.sh` | modify | Probe smoke-tests `cw_deploy_resolve_target` (Task 6) |
| `commands/deploy.md` | modify | Step 0 reads target_cwd.txt; Step 1.1 spawn `--cwd`; Step 2 cross-verify uses `git -C` (Task 7) |
| `lib/consult.sh` | modify | Add `cw_consult_detect_hub <cwd>` (Task 9) |
| `commands/consult.md` | modify | Step 8.5 asks for Target Sub-Project header in hub mode (Task 10) |
| `bin/consult-design-doc.sh` | modify | Self-review gate validates header slug (Task 10) |
| `tests/test_state.sh` | modify | 3 new assertions for `cw_repo_hash_for` (Task 1) |
| `tests/test_deploy_helpers.sh` | modify | 5+4+3 new assertions across Tasks 2, 3 |
| `tests/test_spawn_validation.sh` | modify | 4 new `--cwd` assertions (Task 4) |
| `tests/test_deploy_init.sh` | modify | 2 new sub-repo-redirect assertions (Task 5) |
| `tests/test_medic.sh` | modify | 1 new probe assertion (Task 6) |
| `tests/test_deploy_directive_target.sh` | create | 4 static-wiring assertions (Task 8) |
| `tests/test_consult_detect_hub.sh` | create | 4 hub-detector assertions (Task 9) |
| `tests/test_consult_design_doc.sh` | modify | 2 new header-presence assertions (Task 10) |
| `tests/test_deploy_v07_dogfood.sh` | modify | Append v0.10 hub scenario (Task 11) |
| `CLAUDE.md` | modify | v0.10.0 status entry (Task 11) |

Total: 4 created tests, 14 modifications.

---

## Task 1: Add `cw_repo_hash_for <cwd>` helper

**Files:**
- Modify: `lib/state.sh` (refactor existing `cw_repo_hash`; add new `cw_repo_hash_for`)
- Modify: `tests/test_state.sh` (3 new assertions)

- [ ] **Step 1: Extend the failing test**

Read `tests/test_state.sh` to find the END. Append:

```bash

# --- cw_repo_hash_for ---
TMP_RH=$(mktemp -d); trap 'rm -rf "$TMP_RH" "${OLD_TRAP:-}"' EXIT
mkdir -p "$TMP_RH/dir-a" "$TMP_RH/dir-b"

# Case 1: explicit cwd produces deterministic hash
h1=$(cw_repo_hash_for "$TMP_RH/dir-a")
h2=$(cw_repo_hash_for "$TMP_RH/dir-a")
[[ "$h1" == "$h2" ]] || { echo "FAIL: cw_repo_hash_for must be deterministic (got '$h1' vs '$h2')" >&2; exit 1; }
[[ ${#h1} -eq 64 ]] || { echo "FAIL: cw_repo_hash_for must return 64-char SHA256 (got len ${#h1})" >&2; exit 1; }
pass "cw_repo_hash_for is deterministic + 64-char SHA256"

# Case 2: equivalence with cw_repo_hash when cwd matches $PWD
( cd "$TMP_RH/dir-a" && [[ "$(cw_repo_hash)" == "$(cw_repo_hash_for "$PWD")" ]] ) \
  || { echo "FAIL: cw_repo_hash and cw_repo_hash_for \$PWD must agree" >&2; exit 1; }
pass "cw_repo_hash equals cw_repo_hash_for \$PWD"

# Case 3: distinct cwds produce distinct hashes
h_a=$(cw_repo_hash_for "$TMP_RH/dir-a")
h_b=$(cw_repo_hash_for "$TMP_RH/dir-b")
[[ "$h_a" != "$h_b" ]] || { echo "FAIL: distinct cwds must hash differently" >&2; exit 1; }
pass "cw_repo_hash_for distinguishes different cwds"
```

- [ ] **Step 2: Run the test, confirm it FAILS**

```
cd /home/liupan/CC/clone-wars && bash tests/test_state.sh
```

Expected: existing PASS lines, then `cw_repo_hash_for: command not found`.

- [ ] **Step 3: Refactor `lib/state.sh`**

Read `lib/state.sh` to find `cw_repo_hash` (around line 13). Replace its body with a delegation to the new helper. INSERT the new helper above (or below, doesn't matter — keep adjacent for cohesion):

```bash
# cw_repo_hash_for <cwd>
# Same hashing rule as cw_repo_hash but takes an explicit cwd. Used by
# /clone-wars:deploy when the trooper redirects into a sub-repo and the
# state path must key off the sub-repo (not the conductor's cwd).
cw_repo_hash_for() {
  local cwd="${1:-}"
  [[ -n "$cwd" ]] || { echo "cw_repo_hash_for: missing cwd arg" >&2; return 2; }
  local p
  p=$(realpath "$cwd" 2>/dev/null || readlink -f "$cwd" 2>/dev/null || printf '%s' "$cwd")
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$p" | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$p" | shasum -a 256 | awk '{print $1}'
  else
    echo "cw_repo_hash_for: no sha256 tool (sha256sum or shasum) found" >&2
    return 1
  fi
}

cw_repo_hash() {
  cw_repo_hash_for "$PWD"
}
```

- [ ] **Step 4: Run the test, confirm it PASSES**

```
cd /home/liupan/CC/clone-wars && bash tests/test_state.sh
```

Expected: all existing PASS lines + 3 new PASS lines, ends green.

- [ ] **Step 5: Commit**

```
cd /home/liupan/CC/clone-wars
git add lib/state.sh tests/test_state.sh
git commit -m "feat(state): add cw_repo_hash_for <cwd> helper"
```

---

## Task 2: Add `cw_deploy_extract_target` helper

**Files:**
- Modify: `lib/deploy.sh` (insert helper after the existing turn prompt builders, around line 230)
- Modify: `tests/test_deploy_helpers.sh` (5 new assertions)

- [ ] **Step 1: Extend the failing test**

Append to `tests/test_deploy_helpers.sh`:

```bash

# --- cw_deploy_extract_target ---
TMP_ET=$(mktemp -d); trap 'rm -rf "$TMP_ET" "${TMP_DETECT:-}"' EXIT

# Case 1: no header → empty + rc=0
echo "# Spec
no header here.

## Goal
foo
" > "$TMP_ET/no-header.md"
out=$(cw_deploy_extract_target "$TMP_ET/no-header.md") && rc=0 || rc=$?
[[ "$rc" -eq 0 ]] || { echo "FAIL: no-header should rc=0 (got $rc)" >&2; exit 1; }
[[ -z "$out" ]] || { echo "FAIL: no-header should print empty (got '$out')" >&2; exit 1; }
pass "extract_target returns empty + rc=0 when no header"

# Case 2: valid header → slug + rc=0
echo "# Spec

**Target Sub-Project:** ARS-Perfusion

## Goal
foo
" > "$TMP_ET/valid.md"
out=$(cw_deploy_extract_target "$TMP_ET/valid.md")
[[ "$out" == "ARS-Perfusion" ]] || { echo "FAIL: expected 'ARS-Perfusion' (got '$out')" >&2; exit 1; }
pass "extract_target returns slug for valid header"

# Case 3: malformed (slug with /) → rc=1
echo "# Spec

**Target Sub-Project:** ../escape

## Goal
foo
" > "$TMP_ET/malformed.md"
err=$(cw_deploy_extract_target "$TMP_ET/malformed.md" 2>&1) && rc=0 || rc=$?
[[ "$rc" -eq 1 ]] || { echo "FAIL: malformed slug should rc=1 (got $rc)" >&2; exit 1; }
echo "$err" | grep -qi 'invalid\|malformed\|slug' \
  || { echo "FAIL: malformed error message unclear: $err" >&2; exit 1; }
pass "extract_target rc=1 + clear error on malformed slug"

# Case 4: missing arg → rc=2
err=$(cw_deploy_extract_target 2>&1) && rc=0 || rc=$?
[[ "$rc" -eq 2 ]] || { echo "FAIL: no arg should rc=2 (got $rc)" >&2; exit 1; }
pass "extract_target rc=2 on missing arg"

# Case 5: tolerates leading whitespace + double space after colon
echo "# Spec

   **Target Sub-Project:**   web-frontend

## Goal
foo
" > "$TMP_ET/whitespace.md"
out=$(cw_deploy_extract_target "$TMP_ET/whitespace.md")
[[ "$out" == "web-frontend" ]] || { echo "FAIL: whitespace-tolerance failed (got '$out')" >&2; exit 1; }
pass "extract_target tolerates leading/trailing whitespace"
```

- [ ] **Step 2: Run the test, confirm it FAILS**

```
cd /home/liupan/CC/clone-wars && bash tests/test_deploy_helpers.sh
```

Expected: existing PASS, then `cw_deploy_extract_target: command not found`.

- [ ] **Step 3: Add the helper to `lib/deploy.sh`**

Read `lib/deploy.sh` to find the END (after `cw_deploy_detect_provider`, around line 230). Append:

```bash

# cw_deploy_extract_target <design-path>
# Extracts the slug from a `**Target Sub-Project:** <slug>` header line.
# Slug must match ^[A-Za-z0-9._-]+$ — rejects path-traversal attempts
# (`../escape`) and other invalid forms.
# - No header in doc → prints empty + rc=0
# - Valid header → prints slug + rc=0
# - Header present but slug invalid → rc=1 + log_error
# - Missing/unreadable doc OR no arg → rc=2
cw_deploy_extract_target() {
  local doc="${1:-}"
  [[ -n "$doc" ]] || { log_error "cw_deploy_extract_target: missing design-path arg"; return 2; }
  [[ -f "$doc" && -r "$doc" ]] || { log_error "cw_deploy_extract_target: doc unreadable: $doc"; return 2; }
  local line
  line=$(grep -m1 -E '^[[:space:]]*\*\*Target Sub-Project:\*\*[[:space:]]+' "$doc" || true)
  if [[ -z "$line" ]]; then
    return 0  # no header → empty stdout
  fi
  local slug
  slug=$(printf '%s' "$line" | sed -E 's/^[[:space:]]*\*\*Target Sub-Project:\*\*[[:space:]]+([^[:space:]]+).*/\1/')
  if [[ ! "$slug" =~ ^[A-Za-z0-9._-]+$ ]]; then
    log_error "cw_deploy_extract_target: invalid slug '$slug' (must match ^[A-Za-z0-9._-]+$)"
    return 1
  fi
  printf '%s\n' "$slug"
}
```

- [ ] **Step 4: Run the test, confirm it PASSES**

```
cd /home/liupan/CC/clone-wars && bash tests/test_deploy_helpers.sh
```

Expected: all existing PASS + 5 new PASS lines.

- [ ] **Step 5: Commit**

```
cd /home/liupan/CC/clone-wars
git add lib/deploy.sh tests/test_deploy_helpers.sh
git commit -m "feat(deploy): add cw_deploy_extract_target helper"
```

---

## Task 3: Add `cw_deploy_resolve_target` helper + audit gate

**Files:**
- Modify: `lib/deploy.sh` (add `cw_deploy_resolve_target`; extend `cw_deploy_audit_doc`)
- Modify: `tests/test_deploy_helpers.sh` (4 + 3 = 7 new assertions)

- [ ] **Step 1: Extend the failing test (resolver assertions)**

Append to `tests/test_deploy_helpers.sh`:

```bash

# --- cw_deploy_resolve_target ---
TMP_RT=$(mktemp -d); trap 'rm -rf "$TMP_RT" "$TMP_ET" "${TMP_DETECT:-}"' EXIT

# Build a hub-style fixture: hub/ has .git; hub/sub-a/ has .git; hub/sub-b/ exists but no .git.
mkdir -p "$TMP_RT/hub/.git" "$TMP_RT/hub/sub-a/.git" "$TMP_RT/hub/sub-b"

# Case 1: no header → returns conductor-cwd verbatim
echo "# spec, no header" > "$TMP_RT/no-header.md"
out=$(cw_deploy_resolve_target "$TMP_RT/no-header.md" "$TMP_RT/hub")
[[ "$out" == "$TMP_RT/hub" ]] || { echo "FAIL: no-header should return cwd verbatim (got '$out')" >&2; exit 1; }
pass "resolve_target returns cwd verbatim when no header"

# Case 2: header + valid sub-repo → returns sub-repo path
echo "# spec

**Target Sub-Project:** sub-a
" > "$TMP_RT/valid.md"
out=$(cw_deploy_resolve_target "$TMP_RT/valid.md" "$TMP_RT/hub")
[[ "$out" == "$TMP_RT/hub/sub-a" ]] || { echo "FAIL: valid header should return sub-repo path (got '$out')" >&2; exit 1; }
pass "resolve_target returns sub-repo path when header valid"

# Case 3: header + missing sub-repo → rc=1
echo "# spec

**Target Sub-Project:** sub-missing
" > "$TMP_RT/missing.md"
err=$(cw_deploy_resolve_target "$TMP_RT/missing.md" "$TMP_RT/hub" 2>&1) && rc=0 || rc=$?
[[ "$rc" -eq 1 ]] || { echo "FAIL: missing sub-repo should rc=1 (got $rc)" >&2; exit 1; }
echo "$err" | grep -qi 'not found\|missing' \
  || { echo "FAIL: missing-sub-repo error message unclear: $err" >&2; exit 1; }
pass "resolve_target rc=1 when sub-repo dir missing"

# Case 4: header + sub-repo dir exists but no .git → rc=1
echo "# spec

**Target Sub-Project:** sub-b
" > "$TMP_RT/no-git.md"
err=$(cw_deploy_resolve_target "$TMP_RT/no-git.md" "$TMP_RT/hub" 2>&1) && rc=0 || rc=$?
[[ "$rc" -eq 1 ]] || { echo "FAIL: no-.git sub-repo should rc=1 (got $rc)" >&2; exit 1; }
echo "$err" | grep -qi 'not a git repo' \
  || { echo "FAIL: no-.git error message unclear: $err" >&2; exit 1; }
pass "resolve_target rc=1 when sub-repo exists but not a git repo"
```

- [ ] **Step 2: Extend the failing test (audit-gate assertions)**

Append:

```bash

# --- audit gate target_subproject_when_invalid ---
TMP_AG=$(mktemp -d); trap 'rm -rf "$TMP_AG" "$TMP_RT" "$TMP_ET" "${TMP_DETECT:-}"' EXIT

# Case 1: invalid slug (path traversal) → audit RC=1 with the new ISSUE
cat > "$TMP_AG/invalid.md" <<'EOF'
# Spec

**Target Sub-Project:** ../escape

## Goal
foo
## Architecture
foo
## Testing
foo
## Success
foo
EOF
out=$(cw_deploy_audit_doc "$TMP_AG/invalid.md") && rc=0 || rc=$?
[[ "$rc" -eq 1 ]] || { echo "FAIL: invalid header should audit FAIL (got $rc)" >&2; exit 1; }
echo "$out" | grep -q 'ISSUE=target_subproject_when_invalid' \
  || { echo "FAIL: audit must emit target_subproject_when_invalid ISSUE; got: $out" >&2; exit 1; }
pass "audit emits target_subproject_when_invalid for malformed slug"

# Case 2: valid header → audit PASS
cat > "$TMP_AG/valid.md" <<'EOF'
# Spec

**Target Sub-Project:** ARS-Perfusion

## Goal
foo
## Architecture
foo
## Testing
foo
## Success
foo
EOF
out=$(cw_deploy_audit_doc "$TMP_AG/valid.md") && rc=0 || rc=$?
[[ "$rc" -eq 0 ]] || { echo "FAIL: valid header should PASS (got $rc; out: $out)" >&2; exit 1; }
pass "audit PASSes for valid Target Sub-Project header"

# Case 3: no header → audit PASS (single-repo case unchanged)
cat > "$TMP_AG/none.md" <<'EOF'
# Spec

## Goal
foo
## Architecture
foo
## Testing
foo
## Success
foo
EOF
out=$(cw_deploy_audit_doc "$TMP_AG/none.md") && rc=0 || rc=$?
[[ "$rc" -eq 0 ]] || { echo "FAIL: no-header should PASS (got $rc; out: $out)" >&2; exit 1; }
pass "audit PASSes when no Target Sub-Project header (single-repo case)"
```

- [ ] **Step 3: Run the test, confirm it FAILS**

```
cd /home/liupan/CC/clone-wars && bash tests/test_deploy_helpers.sh
```

Expected: existing + 5-from-Task-2 PASS, then resolver/audit assertions fail.

- [ ] **Step 4: Add `cw_deploy_resolve_target` to `lib/deploy.sh`**

Append in `lib/deploy.sh` after `cw_deploy_extract_target`:

```bash

# cw_deploy_resolve_target <design-path> <conductor-cwd>
# Resolves the target cwd for a /clone-wars:deploy invocation:
#   - If design-doc has no Target Sub-Project header → returns <conductor-cwd>.
#   - If header present + <conductor-cwd>/<slug>/.git/ exists → returns <conductor-cwd>/<slug>.
#   - If header present + <conductor-cwd>/<slug> missing → rc=1 + log_error.
#   - If header present + <conductor-cwd>/<slug> exists but no .git → rc=1 + log_error.
# rc=2 on missing args.
cw_deploy_resolve_target() {
  local doc="${1:-}" cwd="${2:-}"
  [[ -n "$doc" ]] || { log_error "cw_deploy_resolve_target: missing design-path arg"; return 2; }
  [[ -n "$cwd" ]] || { log_error "cw_deploy_resolve_target: missing cwd arg"; return 2; }
  local slug
  slug=$(cw_deploy_extract_target "$doc") || return $?
  if [[ -z "$slug" ]]; then
    printf '%s\n' "$cwd"
    return 0
  fi
  local sub="$cwd/$slug"
  if [[ ! -d "$sub" ]]; then
    log_error "target sub-project '$slug' not found at $sub (no directory; check spelling or that the sub-repo is checked out)"
    return 1
  fi
  if [[ ! -d "$sub/.git" && ! -f "$sub/.git" ]]; then
    log_error "target sub-project '$slug' is a directory but not a git repo (no .git/ at $sub)"
    return 1
  fi
  printf '%s\n' "$sub"
}
```

(Note: `[[ -f "$sub/.git" ]]` covers the git-worktree case where `.git` is a file pointing at the gitdir.)

- [ ] **Step 5: Extend `cw_deploy_audit_doc` with the new gate**

Read `lib/deploy.sh` to find `cw_deploy_audit_doc` (around line 46). Add ONE new line to the issues block (after the existing `to_be_determined_marker` check, before the `if (( fail == 0 ))` summary):

```bash
  # Target Sub-Project header: if present, slug must be valid (matches ^[A-Za-z0-9._-]+$).
  # Use cw_deploy_extract_target which returns rc=1 on invalid slug.
  if grep -qE '^[[:space:]]*\*\*Target Sub-Project:\*\*[[:space:]]+' "$doc"; then
    cw_deploy_extract_target "$doc" >/dev/null 2>&1 \
      || { issues+=("target_subproject_when_invalid"); fail=1; }
  fi
```

Place this BEFORE the `if (( fail == 0 ))` block.

- [ ] **Step 6: Run the test, confirm it PASSES**

```
cd /home/liupan/CC/clone-wars && bash tests/test_deploy_helpers.sh
```

Expected: existing + 5 (Task 2) + 4 (resolver) + 3 (audit gate) = 12 new PASS lines total.

- [ ] **Step 7: Commit**

```
cd /home/liupan/CC/clone-wars
git add lib/deploy.sh tests/test_deploy_helpers.sh
git commit -m "feat(deploy): add cw_deploy_resolve_target + audit gate for header"
```

---

## Task 4: Add `--cwd <abs-path>` flag to `bin/spawn.sh`

**Files:**
- Modify: `bin/spawn.sh` (add flag parsing + tmux integration)
- Modify: `tests/test_spawn_validation.sh` (4 new assertions)

- [ ] **Step 1: Extend the failing test**

Read `tests/test_spawn_validation.sh` to find the END. Append:

```bash

# --- --cwd flag (v0.10) ---
TMP_CWD=$(mktemp -d); trap 'rm -rf "$TMP_CWD"' EXIT
mkdir -p "$TMP_CWD/sub"

# Case 1: --cwd <existing-abs-path> accepted (static-wiring)
grep -q '\-\-cwd' ../bin/spawn.sh \
  || { echo "FAIL: spawn.sh must parse --cwd flag" >&2; exit 1; }
grep -qE 'split-window.*-c[ ]+"?\$' ../bin/spawn.sh \
  || { echo "FAIL: spawn.sh must pass -c <cwd> to tmux split-window" >&2; exit 1; }
pass "spawn.sh wires --cwd into tmux split-window -c"

# Case 2: --cwd <missing-path> rejected
err=$(../bin/spawn.sh cody codex some-topic --cwd "$TMP_CWD/does-not-exist" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: --cwd <missing> should rc!=0 (got $rc)" >&2; exit 1; }
echo "$err" | grep -qi 'cwd.*not exist\|cwd.*does not exist\|cwd.*not a dir' \
  || { echo "FAIL: --cwd missing-path error unclear: $err" >&2; exit 1; }
pass "spawn rejects --cwd <missing-path>"

# Case 3: --cwd without value rejected
err=$(../bin/spawn.sh cody codex some-topic --cwd 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: --cwd without value should rc!=0 (got $rc)" >&2; exit 1; }
pass "spawn rejects bare --cwd without value"

# Case 4: --cwd with relative path rejected (must be absolute)
err=$(../bin/spawn.sh cody codex some-topic --cwd "relative/path" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: --cwd <relative> should rc!=0 (got $rc)" >&2; exit 1; }
echo "$err" | grep -qi 'absolute' \
  || { echo "FAIL: --cwd relative-path error should mention 'absolute'; got: $err" >&2; exit 1; }
pass "spawn rejects relative --cwd path"
```

- [ ] **Step 2: Run the test, confirm it FAILS**

```
cd /home/liupan/CC/clone-wars && bash tests/test_spawn_validation.sh
```

Expected: first new assertion fails (`spawn.sh must parse --cwd flag`).

- [ ] **Step 3: Add `--cwd` parsing to `bin/spawn.sh`**

Read `bin/spawn.sh` lines 58-72 (the argv parser block). The current shape is:

```bash
COMMANDER="$1"; MODEL="$2"; TOPIC="$3"; shift 3
MODE=""
INITIAL_PROMPT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)        MODE="$2"; shift 2 ;;
    --mode=*)      MODE="${1#*=}"; shift ;;
    ... (other cases)
  esac
done
```

Add a new local var `SPAWN_CWD=""` after `INITIAL_PROMPT=""`, and add new case-arms for `--cwd` / `--cwd=*` mirroring `--mode`:

```bash
COMMANDER="$1"; MODEL="$2"; TOPIC="$3"; shift 3
MODE=""
INITIAL_PROMPT=""
SPAWN_CWD=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)        MODE="$2"; shift 2 ;;
    --mode=*)      MODE="${1#*=}"; shift ;;
    --cwd)         [[ -n "${2:-}" ]] || { echo "--cwd requires a value" >&2; exit 2; }
                   SPAWN_CWD="$2"; shift 2 ;;
    --cwd=*)       SPAWN_CWD="${1#*=}"; shift ;;
    --*)           echo "unknown flag: $1" >&2; exit 2 ;;
    *)             INITIAL_PROMPT="$1"; shift ;;
  esac
done
```

(Adapt the merge to match the existing case-block exactly — read the current code first.)

Then add validation immediately after the parser block:

```bash
if [[ -n "$SPAWN_CWD" ]]; then
  [[ "$SPAWN_CWD" == /* ]] || { log_error "spawn --cwd must be an absolute path: $SPAWN_CWD"; exit 1; }
  [[ -d "$SPAWN_CWD" ]] || { log_error "spawn --cwd target does not exist: $SPAWN_CWD"; exit 1; }
fi
```

- [ ] **Step 4: Update the tmux split-window call**

Read `bin/spawn.sh` to find the `tmux split-window` invocation. The current shape is roughly:

```bash
PANE_ID=$(tmux split-window -P -F '#{pane_id}' "$SPLIT_DIR" -t "$BASE_PANE")
```

Modify it to inject `-c "$SPAWN_CWD"` when SPAWN_CWD is set. The `tmux split-window -c <start-dir>` flag tells tmux to launch the new pane with that working dir. Replace the invocation with:

```bash
SPLIT_ARGS=(-P -F '#{pane_id}' "$SPLIT_DIR" -t "$BASE_PANE")
if [[ -n "$SPAWN_CWD" ]]; then
  SPLIT_ARGS+=(-c "$SPAWN_CWD")
fi
PANE_ID=$(tmux split-window "${SPLIT_ARGS[@]}")
```

(Adjust the existing tmux call to match the codebase's actual style — read the surrounding lines first to confirm what flags are present.)

- [ ] **Step 5: Update spawn.sh's usage line**

Find the Usage block (around line 46) and add `--cwd <abs-path>` to the synopsis + a description in the flag list:

```
Usage: $0 <commander|random> <model> <topic> [--mode full|read-only] [--cwd <abs-path>] [initial-prompt]
  ...
  --cwd <abs-path>  — start the trooper pane in the given absolute directory
                      (default: inherit conductor's cwd). Used by /clone-wars:deploy
                      when the design doc declares **Target Sub-Project**.
```

- [ ] **Step 6: Run the test, confirm it PASSES**

```
cd /home/liupan/CC/clone-wars && bash tests/test_spawn_validation.sh
```

Expected: existing PASS + 4 new PASS lines.

- [ ] **Step 7: Commit**

```
cd /home/liupan/CC/clone-wars
git add bin/spawn.sh tests/test_spawn_validation.sh
git commit -m "feat(spawn): add --cwd <abs-path> flag for sub-repo deploys"
```

---

## Task 5: Wire detector into `bin/deploy-init.sh`

**Files:**
- Modify: `bin/deploy-init.sh` (resolve target → state path uses sub-repo hash → branch in sub-repo → provider against sub-repo → write target_cwd.txt)
- Modify: `tests/test_deploy_init.sh` (2 new sub-repo-redirect assertions)

- [ ] **Step 1: Extend the failing test**

Append to `tests/test_deploy_init.sh`:

```bash

# --- v0.10: sub-repo redirect ---
TMP_HUB=$(mktemp -d)
trap 'rm -rf "$TMP_HUB" "${TMP_AP_CODEX:-}" "${TMP_AP_CLAUDE:-}"' EXIT
export CLONE_WARS_HOME="$TMP_HUB/cw"

# Build hub fixture: hub/ has .git; hub/sub-a/ has .git + .claude-plugin/plugin.json (forces claude detect).
mkdir -p "$TMP_HUB/hub/sub-a/.claude-plugin"
touch "$TMP_HUB/hub/sub-a/.claude-plugin/plugin.json"
( cd "$TMP_HUB/hub" && git init -q . && git config user.email t@t && git config user.name t \
    && git commit -q --allow-empty -m hub-init )
( cd "$TMP_HUB/hub/sub-a" && git init -q . && git config user.email t@t && git config user.name t \
    && git commit -q --allow-empty -m sub-init )

cat > "$TMP_HUB/spec.md" <<'EOF'
# Hub Spec

**Target Sub-Project:** sub-a

## Goal
foo
## Architecture
foo
## Testing
foo
## Success
foo
EOF

BIN_INIT="$(cd .. && pwd)/bin/deploy-init.sh"
TOPIC=$( cd "$TMP_HUB/hub" && bash "$BIN_INIT" --no-branch --topic v10-redirect "$TMP_HUB/spec.md" 2>/dev/null | tail -1 )
[[ -n "$TOPIC" ]] || { echo "FAIL: deploy-init produced no topic" >&2; exit 1; }

SUB_HASH=$(bash -c 'source ../lib/state.sh; cw_repo_hash_for "'"$TMP_HUB/hub/sub-a"'"')
ART="$CLONE_WARS_HOME/state/$SUB_HASH/$TOPIC/_deploy"
[[ -f "$ART/target_cwd.txt" ]] \
  || { echo "FAIL: hub case missing target_cwd.txt at $ART" >&2; exit 1; }
[[ "$(cat "$ART/target_cwd.txt")" == "$TMP_HUB/hub/sub-a" ]] \
  || { echo "FAIL: target_cwd.txt should be sub-a path (got '$(cat "$ART/target_cwd.txt")')" >&2; exit 1; }
[[ "$(cat "$ART/auto_provider.txt")" == "claude" ]] \
  || { echo "FAIL: auto_provider should be 'claude' (sub-repo has plugin.json); got '$(cat "$ART/auto_provider.txt")'" >&2; exit 1; }
pass "deploy-init redirects state + provider into sub-repo when header present"

# Case 2: header points at missing sub-repo → rc!=0 + auto-rollback
cat > "$TMP_HUB/spec-bad.md" <<'EOF'
# Hub Spec

**Target Sub-Project:** sub-missing

## Goal
foo
## Architecture
foo
## Testing
foo
## Success
foo
EOF

err=$( cd "$TMP_HUB/hub" && bash "$BIN_INIT" --no-branch --topic v10-bad "$TMP_HUB/spec-bad.md" 2>&1 ) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: missing sub-repo should rc!=0 (got $rc; out: $err)" >&2; exit 1; }
echo "$err" | grep -qi 'not found\|missing' \
  || { echo "FAIL: missing-sub-repo error message unclear: $err" >&2; exit 1; }
# Auto-rollback: ART_DIR should NOT exist after the failure.
ART_BAD="$CLONE_WARS_HOME/state/$SUB_HASH/v10-bad/_deploy"
[[ ! -d "$ART_BAD" ]] || { echo "FAIL: missing-sub-repo case left orphan ART_DIR at $ART_BAD" >&2; exit 1; }
pass "deploy-init rejects + auto-rollbacks when header points at missing sub-repo"
```

- [ ] **Step 2: Run the test, confirm it FAILS**

```
cd /home/liupan/CC/clone-wars && bash tests/test_deploy_init.sh
```

Expected: existing PASS, then `missing target_cwd.txt`.

- [ ] **Step 3: Update `bin/deploy-init.sh`**

Read `bin/deploy-init.sh` end-to-end. The current Auto-detect block (around line 81-92) computes `AUTO_PROVIDER` against `cw_repo_root`. Two changes:

1. **Compute TARGET_CWD before computing ART_DIR.** The current shape derives `ART_DIR` from `cw_repo_hash` (cwd-based) very early; we need to change that to use `cw_repo_hash_for "$TARGET_CWD"`.

2. **Branch-create runs against `git -C "$TARGET_CWD"`.** Currently `cw_deploy_branch_create` calls bare `git checkout -b`; we need a small change to `cw_deploy_branch_create` to take an optional cwd arg.

Sketch the changes (read the actual file to nail the exact line edits):

a. Source order is fine — `lib/deploy.sh` already provides the new helpers (Tasks 2, 3) and `lib/state.sh` provides `cw_repo_hash_for` (Task 1).

b. Insert immediately AFTER design-path validation (and BEFORE `ART_DIR` is computed):

```bash
# v0.10: resolve target cwd before computing ART_DIR (sub-repo redirect).
TARGET_CWD=$(cw_deploy_resolve_target "$DESIGN_PATH" "$(cw_repo_root)") || {
  log_error "could not resolve target cwd"; exit 1;
}
```

c. Replace any `ART_DIR=$(cw_deploy_art_dir "$TOPIC")` (or equivalent that uses bare `cw_repo_hash`) with one that uses sub-repo hash. The cleanest path: extend `cw_deploy_art_dir` to take an optional cwd arg, OR compute ART_DIR inline:

```bash
ART_DIR="$(cw_state_root)/state/$(cw_repo_hash_for "$TARGET_CWD")/$TOPIC/_deploy"
```

d. The branch-create call should pass `TARGET_CWD`:

```bash
( cd "$TARGET_CWD" && cw_deploy_branch_create "$TOPIC" "$BRANCH_OVERRIDE" )
```

(A subshell `cd` is OK here because branch-create is purely a git operation, not a long-lived process. Alternative: extend `cw_deploy_branch_create` to take a cwd arg. Pick whichever is cleaner.)

e. Provider auto-detect changes from `cw_deploy_detect_provider "$(cw_repo_root)"` to `cw_deploy_detect_provider "$TARGET_CWD"`.

f. Atomic-write `target_cwd.txt`:

```bash
printf '%s\n' "$TARGET_CWD" | cw_atomic_write "$ART_DIR/target_cwd.txt" \
  || { log_error "failed to write target_cwd.txt"; exit 1; }
```

g. Update the log_info block to mention target if it differs from cwd:

```bash
log_info "  target:     $TARGET_CWD"
```

- [ ] **Step 4: Run the test, confirm it PASSES**

```
cd /home/liupan/CC/clone-wars && bash tests/test_deploy_init.sh
```

Expected: existing PASS + 2 new PASS lines.

- [ ] **Step 5: Commit**

```
cd /home/liupan/CC/clone-wars
git add bin/deploy-init.sh tests/test_deploy_init.sh
git commit -m "feat(deploy): wire sub-repo redirect into deploy-init"
```

---

## Task 6: Update `bin/medic.sh` deploy-helpers-load probe

**Files:**
- Modify: `bin/medic.sh` (add resolve_target call to the probe chain)
- Modify: `tests/test_medic.sh` (no functional change but assert the probe still passes)

- [ ] **Step 1: Locate the existing probe**

```
cd /home/liupan/CC/clone-wars && grep -nE 'cw_deploy_build_turn_prompt_round1|cw_deploy_detect_provider' bin/medic.sh
```

- [ ] **Step 2: Add the new chain element**

Read `bin/medic.sh` and modify the existing `4d` probe block. Append `&& cw_deploy_resolve_target /tmp/non-existent-spec.md /tmp >/dev/null 2>&1 || true` won't work because non-existent doc returns rc=2.

Use this instead — write a temporary spec on the fly:

Actually, simpler: pass `/dev/null` as the doc. `cw_deploy_extract_target` reads the file; `/dev/null` is empty so it returns empty + rc=0 (no header), and `cw_deploy_resolve_target` returns the cwd verbatim. Clean smoke test:

```bash
# 4d. deploy helpers source-load sanity (turn-based deploy + provider/target detect).
if ( source "$PLUGIN_ROOT/lib/state.sh" \
     && source "$PLUGIN_ROOT/lib/log.sh" \
     && source "$PLUGIN_ROOT/lib/consult.sh" \
     && source "$PLUGIN_ROOT/lib/deploy.sh" \
     && cw_deploy_build_turn_prompt_round1 /a /b /c >/dev/null \
     && cw_deploy_detect_provider /tmp >/dev/null \
     && cw_deploy_resolve_target /dev/null /tmp >/dev/null ) 2>/dev/null; then
  log_ok "deploy helpers load clean"
else
  log_warn "deploy helpers FAILED to load"
  warn=1
fi
```

- [ ] **Step 3: Run medic to verify the extended probe**

```
cd /home/liupan/CC/clone-wars && bash bin/medic.sh 2>&1 | grep -i 'deploy helpers'
```

Expected: `[ OK ]  deploy helpers load clean`.

- [ ] **Step 4: Run the medic test to confirm no regression**

```
cd /home/liupan/CC/clone-wars && bash tests/test_medic.sh
```

Expected: same PASS count as before. The "probe still clean" assertion already exists from v0.9; it implicitly covers the new chain element.

- [ ] **Step 5: Update the explanatory comment in test_medic.sh**

Find the existing `pass "medic deploy-helpers probe still clean after refactor"` assertion. Add a comment ABOVE it noting that the v0.10 probe now smoke-tests `cw_deploy_resolve_target` too.

- [ ] **Step 6: Commit**

```
cd /home/liupan/CC/clone-wars
git add bin/medic.sh tests/test_medic.sh
git commit -m "chore(medic): extend deploy-helpers probe to smoke-test resolve_target"
```

---

## Task 7: Rewrite `commands/deploy.md` (Step 0 export TARGET_CWD; Step 1.1 spawn --cwd; Step 2 git -C)

**Files:**
- Modify: `commands/deploy.md`

- [ ] **Step 1: Read the current directive**

```
cd /home/liupan/CC/clone-wars && cat commands/deploy.md
```

- [ ] **Step 2: Add TARGET_CWD export to Step 0**

Find the existing block that reads `auto_provider.txt` (sub-step 8 from v0.9). INSERT a new sub-step 7.5 (or extend sub-step 8) to read `target_cwd.txt`:

```markdown
   Read the target cwd resolved by deploy-init.sh:
   ```
   TARGET_CWD=$(cat "$ART_DIR/target_cwd.txt")
   log_info "trooper target cwd: $TARGET_CWD"
   ```
   For single-repo deploys (no Target Sub-Project header in the design doc),
   `$TARGET_CWD` equals the conductor's cwd. For hub deploys with a header,
   `$TARGET_CWD` is the absolute path to the named sub-repo.
```

- [ ] **Step 3: Update Step 1.1 to pass --cwd to spawn.sh**

Find the existing Step 1.1 spawn line:

```
"$CLAUDE_PLUGIN_ROOT/bin/spawn.sh" cody "$PROVIDER" "$TOPIC"
```

Replace with:

```
"$CLAUDE_PLUGIN_ROOT/bin/spawn.sh" cody "$PROVIDER" "$TOPIC" --cwd "$TARGET_CWD"
```

- [ ] **Step 4: Update Step 2 cross-verify to use `git -C`**

Find Step 2's cross-verify reads (the existing prose says e.g. `git log --oneline "$BRANCH_BASE..HEAD"`). Replace EVERY bare `git log` / `git diff` / `git rev-parse` with the `git -C "$TARGET_CWD" ...` form. Specifically:

- `git log --oneline "$BRANCH_BASE..HEAD"` → `git -C "$TARGET_CWD" log --oneline "$BRANCH_BASE..HEAD"`
- `git diff --stat "$BRANCH_BASE..HEAD"` → `git -C "$TARGET_CWD" diff --stat "$BRANCH_BASE..HEAD"`
- `git rev-parse HEAD > "$ART_DIR/branch-base.sha"` → `git -C "$TARGET_CWD" rev-parse HEAD > "$ART_DIR/branch-base.sha"`

If any spot-check Read instruction uses a relative path, change to absolute `$TARGET_CWD/<path>`.

- [ ] **Step 5: Update env-var section / state-file docs**

Find the env-vars section (added in v0.8.0). Add a state-file note:

```markdown
## State files (per topic)

- `_deploy/target_cwd.txt` — absolute path to the trooper's working dir. Equal to the
  conductor's cwd in single-repo mode; equal to `<conductor-cwd>/<sub-repo>` when the
  design doc declares `**Target Sub-Project:** <sub-repo>`. Set by `bin/deploy-init.sh`,
  read by Step 0 + Step 1.1 + Step 2.
- `_deploy/auto_provider.txt` — what cw_deploy_detect_provider chose (codex/claude).
- `_deploy/provider.txt` — what was actually used (after any user override).
- `_deploy/turn-cody-N.txt` — per-round trooper-turn status (TS=ok/failed/timeout).
```

- [ ] **Step 6: Sweep for stale references**

```
cd /home/liupan/CC/clone-wars
grep -nE '^\s*git (log|diff|rev-parse|checkout)' commands/deploy.md
```

For every match, verify it's `git -C "$TARGET_CWD" ...`. Bare `git` calls = stale.

- [ ] **Step 7: Self-review**

- `grep -q 'target_cwd.txt' commands/deploy.md` → at least one match.
- `grep -q '\-\-cwd "?\$TARGET_CWD' commands/deploy.md` → at least one match (Step 1.1 spawn).
- `grep -qE 'git -C "?\$TARGET_CWD"?' commands/deploy.md` → at least one match (Step 2).

- [ ] **Step 8: Commit**

```
cd /home/liupan/CC/clone-wars
git add commands/deploy.md
git commit -m "feat(deploy): thread TARGET_CWD through Step 0/1.1/2"
```

---

## Task 8: Add `tests/test_deploy_directive_target.sh` static-wiring test

**Files:**
- Create: `tests/test_deploy_directive_target.sh`

- [ ] **Step 1: Create the test file**

```bash
#!/usr/bin/env bash
# tests/test_deploy_directive_target.sh — static-wiring assertions
# for the v0.10 sub-repo redirect directive flow.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

D=../commands/deploy.md

# Auto file (target) is read.
grep -q 'target_cwd.txt' "$D" \
  || { echo "FAIL: directive must reference target_cwd.txt" >&2; exit 1; }
pass "directive reads target_cwd.txt"

# TARGET_CWD is exported from Step 0.
grep -q 'TARGET_CWD=' "$D" \
  || { echo "FAIL: directive must set TARGET_CWD variable" >&2; exit 1; }
pass "directive sets TARGET_CWD"

# Step 1.1 spawn passes --cwd "$TARGET_CWD".
grep -qE 'spawn\.sh.*cody.*\-\-cwd[ ]+"?\$TARGET_CWD' "$D" \
  || { echo "FAIL: Step 1.1 spawn line must pass --cwd \$TARGET_CWD" >&2; exit 1; }
pass "directive's spawn line passes --cwd \$TARGET_CWD"

# Step 2 cross-verify uses git -C "$TARGET_CWD".
grep -qE 'git -C "?\$TARGET_CWD"?' "$D" \
  || { echo "FAIL: Step 2 cross-verify must use git -C \$TARGET_CWD" >&2; exit 1; }
pass "directive's cross-verify uses git -C \$TARGET_CWD"

# No leftover bare 'git checkout -b' / 'git log/diff' WITHOUT git -C in the directive.
if grep -nE '^\s*git (log|diff|checkout)' "$D" | grep -v 'git -C' >/tmp/_bare_git.$$; then
  if [[ -s /tmp/_bare_git.$$ ]]; then
    cat /tmp/_bare_git.$$ >&2
    rm -f /tmp/_bare_git.$$
    echo "FAIL: leftover bare git invocation in directive (must use git -C)" >&2; exit 1
  fi
fi
rm -f /tmp/_bare_git.$$
pass "no leftover bare git invocations in directive"

echo "ALL: ok"
```

```
chmod +x /home/liupan/CC/clone-wars/tests/test_deploy_directive_target.sh
```

- [ ] **Step 2: Run the test, confirm it PASSES (Task 7 already updated the directive)**

```
cd /home/liupan/CC/clone-wars && bash tests/test_deploy_directive_target.sh
```

Expected: 5 PASS lines, ends green.

- [ ] **Step 3: Run the full suite to confirm no regression**

```
cd /home/liupan/CC/clone-wars && bash tests/run.sh 2>&1 | tail -5
```

Expected: green (with the 1 known pre-existing failure unchanged).

- [ ] **Step 4: Commit**

```
cd /home/liupan/CC/clone-wars
git add tests/test_deploy_directive_target.sh
git commit -m "test(deploy): add static-wiring assertions for sub-repo-redirect directive"
```

---

## Task 9: Add `cw_consult_detect_hub` helper

**Files:**
- Modify: `lib/consult.sh` (add helper)
- Create: `tests/test_consult_detect_hub.sh` (4 cases)

- [ ] **Step 1: Create the failing test**

```bash
#!/usr/bin/env bash
# tests/test_consult_detect_hub.sh — coverage for cw_consult_detect_hub.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/log.sh
source ../lib/consult.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Case 1: hub fixture (parent + 2 child .git dirs) → rc=0 + lists 2 sub-repos.
mkdir -p "$TMP/hub/.git" "$TMP/hub/sub-a/.git" "$TMP/hub/sub-b/.git"
out=$(cw_consult_detect_hub "$TMP/hub") && rc=0 || rc=$?
[[ "$rc" -eq 0 ]] || { echo "FAIL: hub fixture should rc=0 (got $rc)" >&2; exit 1; }
echo "$out" | grep -q '^sub-a$' && echo "$out" | grep -q '^sub-b$' \
  || { echo "FAIL: hub fixture should list sub-a + sub-b (got: $out)" >&2; exit 1; }
pass "detect_hub returns sub-repos when hub structure present"

# Case 2: single-repo (parent .git only, no children) → rc=1 + empty.
mkdir -p "$TMP/single/.git" "$TMP/single/srcdir"
out=$(cw_consult_detect_hub "$TMP/single") && rc=0 || rc=$?
[[ "$rc" -eq 1 ]] || { echo "FAIL: single-repo should rc=1 (got $rc)" >&2; exit 1; }
[[ -z "$out" ]] || { echo "FAIL: single-repo should print empty (got: $out)" >&2; exit 1; }
pass "detect_hub returns rc=1 for single-repo cwd"

# Case 3: nested non-git child dirs → rc=1.
mkdir -p "$TMP/nested-no-git/.git" "$TMP/nested-no-git/childA" "$TMP/nested-no-git/childB"
out=$(cw_consult_detect_hub "$TMP/nested-no-git") && rc=0 || rc=$?
[[ "$rc" -eq 1 ]] || { echo "FAIL: nested-no-git should rc=1 (got $rc)" >&2; exit 1; }
pass "detect_hub returns rc=1 when children have no .git"

# Case 4: cwd is not a git repo (no .git in parent) → rc=1.
mkdir -p "$TMP/not-git/sub-a/.git"
out=$(cw_consult_detect_hub "$TMP/not-git") && rc=0 || rc=$?
[[ "$rc" -eq 1 ]] || { echo "FAIL: cwd-not-git should rc=1 (got $rc)" >&2; exit 1; }
pass "detect_hub returns rc=1 when cwd itself is not a git repo"

echo "ALL: ok"
```

```
chmod +x /home/liupan/CC/clone-wars/tests/test_consult_detect_hub.sh
```

- [ ] **Step 2: Run the test, confirm it FAILS**

```
cd /home/liupan/CC/clone-wars && bash tests/test_consult_detect_hub.sh
```

Expected: `cw_consult_detect_hub: command not found`.

- [ ] **Step 3: Add the helper to `lib/consult.sh`**

Append to `lib/consult.sh`:

```bash

# cw_consult_detect_hub <cwd>
# Returns 0 + prints names of immediate sub-repos (one per line) when:
#   <cwd> itself is a git repo (has .git/), AND
#   at least one immediate child of <cwd> contains a .git/ directory or file.
# Returns 1 (no output) otherwise.
cw_consult_detect_hub() {
  local cwd="${1:-}"
  [[ -n "$cwd" ]] || return 1
  [[ -d "$cwd/.git" || -f "$cwd/.git" ]] || return 1
  local found=0 child base
  for child in "$cwd"/*/; do
    [[ -d "$child" ]] || continue
    if [[ -d "$child/.git" || -f "$child/.git" ]]; then
      base="${child%/}"
      printf '%s\n' "${base##*/}"
      found=1
    fi
  done
  (( found == 1 )) && return 0 || return 1
}
```

- [ ] **Step 4: Run the test, confirm it PASSES**

```
cd /home/liupan/CC/clone-wars && bash tests/test_consult_detect_hub.sh
```

Expected: 4 PASS lines + `ALL: ok`.

- [ ] **Step 5: Commit**

```
cd /home/liupan/CC/clone-wars
git add lib/consult.sh tests/test_consult_detect_hub.sh
git commit -m "feat(consult): add cw_consult_detect_hub helper"
```

---

## Task 10: Update consult design-doc walk to ask for Target Sub-Project header + validation gate

**Files:**
- Modify: `commands/consult.md` (Step 8.5 hub-prompt)
- Modify: `bin/consult-design-doc.sh` (self-review gate validates header slug)
- Modify: `tests/test_consult_design_doc.sh` (2 new header-presence assertions)

- [ ] **Step 1: Read the current Step 8.5 in commands/consult.md**

```
cd /home/liupan/CC/clone-wars
grep -n 'Step 8.5\|design-doc walk\|design_doc' commands/consult.md | head -10
```

- [ ] **Step 2: Insert hub-prompt block at the START of Step 8.5**

Find the Step 8.5 heading in `commands/consult.md`. INSERT the following new sub-step BEFORE the Architecture section walk (which is the first existing sub-step inside Step 8.5):

```markdown
0. **Hub detection.** Before walking the Architecture section, check whether
   the conductor's cwd is a hub repo:

   ```
   source "$CLAUDE_PLUGIN_ROOT/lib/consult.sh"
   SUB_REPOS=$(cw_consult_detect_hub "$(pwd)") && IS_HUB=1 || IS_HUB=0
   ```

   If `IS_HUB=1`: AskUserQuestion with one option per detected sub-repo, plus
   a "Hub-level / multi-target / not applicable" option:

   ```
   question: "This looks like a hub repo (sub-repos: <SUB_REPOS comma-list>).
     Which sub-repo will implement this design — or is it hub-level?"
   options: <one per sub-repo> + "Hub-level / multi-target / not applicable"
   ```

   If user picks a sub-repo `<name>`: persist for later prepending:
   ```
   TARGET_HEADER="**Target Sub-Project:** $name"
   ```

   If user picks "Hub-level / multi-target / not applicable": leave
   `TARGET_HEADER` empty.

   When `bin/consult-design-doc.sh` assembles the final spec, prepend
   `TARGET_HEADER` (if non-empty) as the second non-blank line (right after
   the `# <title>` line) so audit can find it.
```

- [ ] **Step 3: Update `bin/consult-design-doc.sh` to accept and prepend the header**

Read `bin/consult-design-doc.sh` to find where the assembled doc is written. The assembly reads `<dd-dir>/architecture.md`, `components.md`, etc. and concatenates. Add a step that, BEFORE writing the final assembled file, checks for an env var `CW_CONSULT_TARGET_HEADER` (set by the directive) and prepends it.

Sketch (adapt to actual file shape):

```bash
# After assembling sections into $ASSEMBLED but before writing $OUT_PATH:
if [[ -n "${CW_CONSULT_TARGET_HEADER:-}" ]]; then
  # Validate the header slug before commit (defensive — directive should already validate).
  slug=$(printf '%s' "$CW_CONSULT_TARGET_HEADER" | sed -E 's/^\*\*Target Sub-Project:\*\*[[:space:]]+([^[:space:]]+).*/\1/')
  if [[ ! "$slug" =~ ^[A-Za-z0-9._-]+$ ]]; then
    log_error "consult-design-doc: invalid Target Sub-Project slug '$slug' from CW_CONSULT_TARGET_HEADER"
    exit 1
  fi
  # Prepend after the # <title> line. Find the title line, insert header on next blank line.
  sed -i '0,/^# /{/^# /a\
\
'"$CW_CONSULT_TARGET_HEADER"'
}' "$ASSEMBLED"
fi
```

(The exact `sed -i` pattern depends on the shape of the assembled doc — read the current code and adapt. Use `awk` if `sed` is gnarly.)

The directive (Step 8.5 sub-step 0 above) sets `CW_CONSULT_TARGET_HEADER` before invoking the bin script.

- [ ] **Step 4: Extend `tests/test_consult_design_doc.sh`**

Read the existing test file. Append two new assertions:

```bash

# v0.10: hub fixture + chosen sub-repo → assembled doc has Target Sub-Project header.
TMP_DD=$(mktemp -d); trap 'rm -rf "$TMP_DD" "${OLD_TMP:-}"' EXIT
# (Assemble the test's existing fixture-walking machinery here. This is a
# directive-flow test; it exercises the bin script directly.)

# Set CW_CONSULT_TARGET_HEADER and re-run consult-design-doc.sh assembly:
export CW_CONSULT_TARGET_HEADER="**Target Sub-Project:** ARS-Perfusion"
# ... (run the assembly with the existing fixture) ...
# Then assert the assembled doc's second non-blank line is the header:
second_line=$(awk 'NF{n++; if(n==2){print; exit}}' "$ASSEMBLED_PATH")
[[ "$second_line" == "**Target Sub-Project:** ARS-Perfusion" ]] \
  || { echo "FAIL: header not at second non-blank line; got '$second_line'" >&2; exit 1; }
pass "consult-design-doc prepends Target Sub-Project header when CW_CONSULT_TARGET_HEADER set"

# v0.10: empty CW_CONSULT_TARGET_HEADER → no header in output.
unset CW_CONSULT_TARGET_HEADER
# ... (re-run assembly) ...
grep -q 'Target Sub-Project' "$ASSEMBLED_PATH" \
  && { echo "FAIL: header should NOT be present when CW_CONSULT_TARGET_HEADER unset" >&2; exit 1; }
pass "consult-design-doc omits header when CW_CONSULT_TARGET_HEADER unset"
```

(Adapt the fixture invocation to match the existing test file's setup style — read it first.)

- [ ] **Step 5: Run the focused tests**

```
cd /home/liupan/CC/clone-wars
bash tests/test_consult_detect_hub.sh
bash tests/test_consult_design_doc.sh
```

Expected: each ends green.

- [ ] **Step 6: Commit**

```
cd /home/liupan/CC/clone-wars
git add commands/consult.md bin/consult-design-doc.sh tests/test_consult_design_doc.sh
git commit -m "feat(consult): ask for Target Sub-Project header in hub mode"
```

---

## Task 11: Manual dogfood gate update + final validation + CLAUDE.md status

**Files:**
- Modify: `tests/test_deploy_v07_dogfood.sh` (append v0.10 hub scenario)
- Modify: `CLAUDE.md` (status entry)

- [ ] **Step 1: Append v0.10 scenario to dogfood gate**

Read `tests/test_deploy_v07_dogfood.sh` to find the END (before the final `exit 0` or `echo "ALL: ok"` line). Append:

```bash
echo ""
echo "v0.10 sub-repo redirect scenarios:"
echo "  7. cd /home/liupan/ARS/ars_fleet (a hub repo). Author a fixture spec"
echo "     containing **Target Sub-Project:** ARS-Perfusion and the standard"
echo "     Goal/Architecture/Testing/Success sections. Run /clone-wars:deploy."
echo "     Confirm: trooper pane spawns with pwd=ars_fleet/ARS-Perfusion;"
echo "     branch feat/deploy-<topic> is created in the sub-repo (not the hub);"
echo "     state lives at <state-root>/state/<sub-repo-hash>/<topic>/_deploy/;"
echo "     target_cwd.txt content matches the sub-repo absolute path."
echo "  8. Re-run with **Target Sub-Project:** ARS-NonExistent. Confirm clean"
echo "     rc!=0 with 'not found' error and _deploy/ auto-rollback."
echo "  9. cd /home/liupan/ARS/ars_fleet. Run /clone-wars:consult --design-doc"
echo "     for any topic. Confirm Step 8.5 raises an AskUserQuestion listing"
echo "     the 8 ARS-* sub-repos. Pick one. Confirm assembled spec at"
echo "     docs/clone-wars/specs/...md has the **Target Sub-Project:** header"
echo "     as the second non-blank line."
echo ""
echo "If scenarios 7-9 pass, this gate is GREEN (also) for v0.10."
```

- [ ] **Step 2: Run the full test suite + verify medic**

```
cd /home/liupan/CC/clone-wars
bash tests/run.sh 2>&1 | tee /tmp/v10-final.log | tail -10
echo "EXIT=$?"
bash bin/medic.sh 2>&1 | tail -5
```

Expected:
- `tests/run.sh` exit 0 (or 1 with only the known pre-existing fail).
- Medic verdict OK; `[ OK ]  deploy helpers load clean` line present.

If ANY new test fails, investigate before committing.

- [ ] **Step 3: Update `CLAUDE.md` status checklist**

Read `CLAUDE.md`. Find the status section near the bottom. Find the existing v0.9.0 entries:

```markdown
- [x] v0.9.0: deploy auto-detects trooper provider ...
- [ ] v0.9.0 strict-dogfood pass on a real machine ...
```

Append IMMEDIATELY AFTER:

```markdown
- [x] v0.10.0: deploy sub-repo redirect — `**Target Sub-Project:** <name>` header in design doc redirects trooper pane / branch / state / provider auto-detect into `<conductor-cwd>/<name>/`; uses `git -C <sub-repo>` + `tmux split-window -c <sub-repo>` so the conductor never `cd`s; consult design-doc walk asks for the header in hub repos
- [ ] v0.10.0 strict-dogfood pass on a real machine (release gate — see tests/test_deploy_v07_dogfood.sh scenarios 7-9)
```

- [ ] **Step 4: Commit + final summary**

```
cd /home/liupan/CC/clone-wars
git add CLAUDE.md tests/test_deploy_v07_dogfood.sh
git commit -m "docs(claude): mark v0.10.0 deploy sub-repo redirect complete"
git log --oneline main..HEAD
```

Expected: 11 commits on the branch (one per task), all Conventional-Commits.

---

## Self-review notes

- **Spec coverage:**
  - `**Target Sub-Project:** <name>` header convention → Tasks 2, 3 (extract + audit)
  - `cw_deploy_extract_target` (5 cases) → Task 2
  - `cw_deploy_resolve_target` (4 cases) → Task 3
  - Audit gate `target_subproject_when_invalid` (3 cases) → Task 3
  - `cw_repo_hash_for <cwd>` (3 cases) → Task 1
  - `bin/spawn.sh --cwd <abs-path>` flag (4 cases) → Task 4
  - `bin/deploy-init.sh` writes `target_cwd.txt`, sub-repo branch, sub-repo provider, sub-repo-keyed state path (2 integration cases) → Task 5
  - `bin/medic.sh` probe extension → Task 6
  - `commands/deploy.md` Step 0 reads target, Step 1.1 spawns with --cwd, Step 2 uses git -C → Task 7
  - Static-wiring test for the directive → Task 8
  - `cw_consult_detect_hub` (4 cases) → Task 9
  - `commands/consult.md` Step 8.5 hub prompt + `bin/consult-design-doc.sh` validation gate (2 cases) → Task 10
  - Manual dogfood gate update + CLAUDE.md → Task 11

- **Type / name consistency:** `cw_deploy_extract_target`, `cw_deploy_resolve_target`, `cw_repo_hash_for`, `cw_consult_detect_hub`, `target_cwd.txt`, `$TARGET_CWD`, `--cwd`, `$CW_CONSULT_TARGET_HEADER`, `**Target Sub-Project:** <slug>` — used identically across all tasks.

- **No placeholders:** every step has explicit code. Task 5 (deploy-init wiring) and Task 7 (directive rewrite) are the largest; they include exact replacement snippets and the implementer is told to read the file first to nail line edits.

- **Task ordering safety:** Task 1 → 2 → 3 (lib helpers come first) → 4 (spawn flag) → 5 (deploy-init uses helpers + spawn flag implicitly) → 6 (medic uses helpers) → 7 (directive uses helpers + spawn flag + state files) → 8 (static-wiring test asserts directive content) → 9 → 10 (consult side, mostly independent of deploy side) → 11 (final validation). No task depends on a later task.
