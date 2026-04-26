# Clone Wars Hardening — Phase 1 (`v0.0.4`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land fixes #1–#5 from the hardening spec — spawn rollback on bootstrap failure, commander-name validation, model-in-`pane.json`, medic check for `pane-border-status`, shell-injection fence on `$ARGUMENTS` — and tag `v0.0.4`.

**Architecture:** Pure-bash + tmux runtime. No new dependencies. Each fix is testable at the lib-function level (or through the existing pure-bash test harness in `tests/`); integration smoke-tests stay manual against a live tmux session post-merge. Backward compatibility preserved for `pane.json` schema changes.

**Tech Stack:** bash 4.2+, tmux ≥ 3.0, pure-shell test harness (`tests/run.sh` discovers every `tests/test_*.sh`), `lib/log.sh` for stderr output.

---

## Spec reference

Living spec: `docs/superpowers/specs/2026-04-26-clone-wars-hardening-design.md` §Phase 1.

## Setup (before Task 1)

- [ ] **Step 0.1: Create the implementation branch**

```bash
cd /home/liupan/CC/clone-wars
git checkout main
git pull origin main
git checkout -b chore/v0.0.4-hardening-phase-1
```

All Task commits land on this branch. The hook policy blocks direct commits to `main`; everything goes through the branch + PR.

## File structure (Phase 1 changes)

| File | Status | Responsibility |
|---|---|---|
| `lib/ipc.sh` | modify | Extend `cw_state_archive` with optional suffix; add `cw_pane_meta_write`'s `model` field; add `cw_pane_meta_model` reader |
| `lib/argsfile.sh` | **NEW** | `cw_args_file_load <path>` — parse a one-line args file into shell tokens |
| `bin/spawn.sh` | modify | Reorder validation before tmux check; add commander regex; FAIL path archives state with `FAILED` suffix; add `--args-file` flag; consume `cw_pane_meta_model` |
| `bin/send.sh` | modify | Replace dir-name parser with `cw_pane_meta_model`; add `--args-file` flag |
| `bin/list.sh` | modify | Replace dir-name parser with `cw_pane_meta_model`; add `--args-file` flag |
| `bin/collect.sh` | modify | Replace dir-name parser with `cw_pane_meta_model`; add `--args-file` flag |
| `bin/teardown.sh` | modify | Replace dir-name parser with `cw_pane_meta_model`; add `--args-file` flag |
| `bin/medic.sh` | modify | Add `pane-border-status` WARN check |
| `commands/spawn.md`, `send.md`, `collect.md`, `list.md`, `teardown.md`, `medic.md` | modify | Switch from `$ARGUMENTS` inline to temp-file + `--args-file` |
| `tests/test_ipc_archive.sh` | **NEW** | Cover `cw_state_archive` suffix support + collision behavior |
| `tests/test_pane_meta.sh` | **NEW** | Cover `cw_pane_meta_write` model field + `cw_pane_meta_model` reader (with backward-compat fallback) |
| `tests/test_spawn_validation.sh` | **NEW** | Cover commander + topic regex via direct invocation of `bin/spawn.sh` (validation runs before tmux check) |
| `tests/test_argsfile.sh` | **NEW** | Cover `cw_args_file_load` parsing of various args-file contents |
| `.claude-plugin/plugin.json` | modify | Bump to `0.0.4` |
| `.claude-plugin/marketplace.json` | modify | Bump to `0.0.4` |

---

## Task 1 — `lib/ipc.sh`: `cw_state_archive` accepts an optional suffix

**Why first:** Task 2 depends on this helper. Pure-bash, fully testable, no tmux dependency.

**Files:**
- Modify: `/home/liupan/CC/clone-wars/lib/ipc.sh:37-47`
- Test: `/home/liupan/CC/clone-wars/tests/test_ipc_archive.sh` (new)

- [ ] **Step 1.1: Write the failing test**

Create `tests/test_ipc_archive.sh`:

```bash
#!/usr/bin/env bash
# tests/test_ipc_archive.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/state.sh
source ../lib/ipc.sh

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

# Simulate a trooper state dir: state/<repo-hash>/<topic>/<commander>-<model>/
ROOT="$CLONE_WARS_HOME/state/$(cw_repo_hash)/demo/rex-codex"
mkdir -p "$ROOT"
echo 'sentinel' > "$ROOT/identity.md"

# 1. Default suffix-less archive — current behavior preserved.
DST=$(cw_state_archive rex codex demo)
assert_file_exists "$DST" "default archive created"
assert_file_exists "$DST/identity.md" "files moved into archive"
[[ ! -d "$ROOT" ]] || { echo "FAIL: source dir still present" >&2; exit 1; }
[[ "$DST" =~ /demo/rex-codex-[0-9TZ]+$ ]] || { echo "FAIL: default suffix shape wrong: $DST" >&2; exit 1; }
pass "default archive shape and move semantics"

# 2. Suffix appended when supplied.
mkdir -p "$ROOT"
echo 'sentinel-2' > "$ROOT/identity.md"
DST2=$(cw_state_archive rex codex demo FAILED)
[[ "$DST2" =~ /demo/rex-codex-[0-9TZ]+-FAILED$ ]] || {
  echo "FAIL: suffix not appended: $DST2" >&2; exit 1; }
assert_file_exists "$DST2/identity.md" "suffix archive moved files"
pass "suffix appended"

# 3. Same-second collision is resolved by the counter loop.
mkdir -p "$ROOT"; echo 'a' > "$ROOT/identity.md"
DST_A=$(cw_state_archive rex codex demo)
mkdir -p "$ROOT"; echo 'b' > "$ROOT/identity.md"
DST_B=$(cw_state_archive rex codex demo)
[[ "$DST_A" != "$DST_B" ]] || { echo "FAIL: collision not resolved: both = $DST_A" >&2; exit 1; }
assert_file_exists "$DST_A/identity.md" "first archive intact"
assert_file_exists "$DST_B/identity.md" "second archive intact"
pass "collision resolution"

echo "  ALL: ok"
```

- [ ] **Step 1.2: Run the test to verify it fails**

```bash
cd /home/liupan/CC/clone-wars && bash tests/test_ipc_archive.sh
```

Expected: FAIL on test 2 (suffix not honored — current `cw_state_archive` ignores any 4th arg) and FAIL on test 3 (no collision resolution). Test 1 may already pass.

- [ ] **Step 1.3: Implement suffix + collision support in `cw_state_archive`**

Replace the function body in `lib/ipc.sh:37-47`:

```bash
# cw_state_archive <commander> <model> <topic> [<suffix>]
# Move a trooper's state dir to archive/<repo-hash>/<topic>/<commander>-<model>-<ts>[-<suffix>]/.
# Counter loop appends -2, -3, ... if the path exists (handles same-second collisions).
cw_state_archive() {
  local commander="$1" model="$2" topic="$3" suffix="${4:-}"
  local src dst base ts n
  src=$(cw_trooper_dir "$commander" "$model" "$topic")
  [[ -d "$src" ]] || return 0
  ts=$(date -u +"%Y%m%dT%H%M%SZ")
  base="$(cw_state_root)/archive/$(cw_repo_hash)/$topic/${commander}-${model}-${ts}"
  [[ -n "$suffix" ]] && base="${base}-${suffix}"
  dst="$base"
  n=2
  while [[ -e "$dst" ]]; do
    dst="${base}-${n}"
    n=$((n + 1))
  done
  mkdir -p "$(dirname "$dst")"
  mv "$src" "$dst"
  printf '%s\n' "$dst"
}
```

- [ ] **Step 1.4: Run the test to verify it passes**

```bash
cd /home/liupan/CC/clone-wars && bash tests/test_ipc_archive.sh
```

Expected: All three `PASS:` lines, then `ALL: ok`.

- [ ] **Step 1.5: Run the full test suite to verify no regressions**

```bash
cd /home/liupan/CC/clone-wars && bash tests/run.sh
```

Expected: every `test_*.sh: ok`, exit 0. (Auto-discovery picks up the new `test_ipc_archive.sh`.)

- [ ] **Step 1.6: Commit**

```bash
cd /home/liupan/CC/clone-wars
git add lib/ipc.sh tests/test_ipc_archive.sh
git commit -m "$(cat <<'EOF'
feat(ipc): cw_state_archive accepts optional suffix + handles collisions

Adds an optional 4th positional arg (suffix) appended to the archive
directory name with a hyphen. Used by the upcoming spawn-rollback
path to mark FAILED archives distinctly from clean teardowns.

Also adds a counter loop (-2, -3, ...) so same-second teardown→spawn→
teardown cycles never produce nested archives via mv-into-existing-dir
semantics.
EOF
)"
```

---

## Task 2 — `bin/spawn.sh`: rollback state dir on bootstrap failure (#1)

**Why second:** Builds on Task 1's `cw_state_archive` suffix support.

**Files:**
- Modify: `/home/liupan/CC/clone-wars/bin/spawn.sh:148-156` (FAIL path)

This task has no automated test — the failure path requires a real tmux session + a misbehaving provider, which the test harness can't synthesize cleanly. Smoke-tested manually post-merge (see Step 2.3).

- [ ] **Step 2.1: Patch the FAIL branch in `bin/spawn.sh`**

Current code (lines 148-156):

```bash
log_info "waiting for {ready} in outbox (timeout ${READY_TIMEOUT}s)"
if ! cw_outbox_wait "$COMMANDER" "$MODEL" "$TOPIC" ready "$READY_TIMEOUT" >/dev/null; then
  log_error "$COMMANDER timed out on {ready}"
  log_error "outbox:"; cw_outbox_dump "$COMMANDER" "$MODEL" "$TOPIC" >&2
  log_error "pane content (last 25 lines, captured BEFORE kill):"
  tmux capture-pane -p -t "$PANE" 2>/dev/null | tail -n 25 >&2 || true
  cw_pane_kill_now "$PANE"
  exit 1
fi
```

Replace with:

```bash
log_info "waiting for {ready} in outbox (timeout ${READY_TIMEOUT}s)"
if ! cw_outbox_wait "$COMMANDER" "$MODEL" "$TOPIC" ready "$READY_TIMEOUT" >/dev/null; then
  log_error "$COMMANDER timed out on {ready}"
  log_error "outbox:"; cw_outbox_dump "$COMMANDER" "$MODEL" "$TOPIC" >&2
  log_error "pane content (last 25 lines, captured BEFORE kill):"
  tmux capture-pane -p -t "$PANE" 2>/dev/null | tail -n 25 >&2 || true
  cw_pane_kill_now "$PANE"
  failed_archive=$(cw_state_archive "$COMMANDER" "$MODEL" "$TOPIC" FAILED)
  log_error "state archived to: $failed_archive"
  exit 1
fi
```

- [ ] **Step 2.2: Lint-pass the change**

```bash
cd /home/liupan/CC/clone-wars && bash -n bin/spawn.sh && echo "syntax OK"
```

Expected: `syntax OK`.

- [ ] **Step 2.3: Manual smoke test (post-commit, in tmux session)**

After commit, validate end-to-end:

```bash
# In a tmux session, deliberately point at a non-existent provider.
# Edit ~/.clone-wars/contracts.yaml — under codex:, set binary: codex-doesnotexist
# OR temporarily mv codex out of PATH.
bash bin/spawn.sh rex codex rollback-test
# Expect: spawn fails with "ready timeout", state archived to
# ~/.clone-wars/archive/<hash>/rollback-test/rex-codex-<ts>-FAILED/
# Then verify the next call succeeds:
bash bin/spawn.sh rex codex rollback-test
# Expect: not blocked by "commander already deployed".
# Cleanup:
bash bin/teardown.sh rollback-test
# Restore contracts.yaml.
```

This is documentation, not an automated step. Note in the PR description.

- [ ] **Step 2.4: Commit**

```bash
cd /home/liupan/CC/clone-wars
git add bin/spawn.sh
git commit -m "$(cat <<'EOF'
fix(spawn): roll back state dir on bootstrap failure (#1)

When spawn times out waiting for {ready}, it now archives the half-built
state dir to archive/.../<commander>-<model>-<ts>-FAILED/ instead of
leaving it in place. The -FAILED suffix distinguishes it from clean
teardown archives and frees the state slot so a retry isn't blocked by
"commander already deployed".

Manual smoke: spawn against a missing-binary provider, observe
[FAIL] with archive path, then re-spawn — succeeds without manual
teardown.
EOF
)"
```

---

## Task 3 — `bin/spawn.sh`: input validation order + commander regex (#2)

**Why third:** Independent of Tasks 1–2; reorder is a small refactor that makes Task 6 simpler too.

**Files:**
- Modify: `/home/liupan/CC/clone-wars/bin/spawn.sh:59-82` (validation block)
- Test: `/home/liupan/CC/clone-wars/tests/test_spawn_validation.sh` (new)

- [ ] **Step 3.1: Write the failing test**

Create `tests/test_spawn_validation.sh`:

```bash
#!/usr/bin/env bash
# tests/test_spawn_validation.sh
# Validates that bin/spawn.sh rejects malformed commander/topic args
# BEFORE attempting any tmux or provider operation. Runs outside a tmux
# session intentionally so any tmux call would error out differently.
set -uo pipefail   # NOT -e: we expect non-zero exits
cd "$(dirname "$0")"
source lib/assert.sh

SPAWN=../bin/spawn.sh
unset TMUX   # ensure NOT inside a tmux session — validation must precede this check

# 1. Bad commander chars are rejected with exit 2 (usage error).
out=$(bash "$SPAWN" 'evil|payload' codex demo 2>&1); code=$?
assert_eq "$code" "2" "bad commander exits 2"
assert_contains "$out" "commander" "error mentions commander"
pass "bad commander chars"

# 2. Empty commander rejected.
out=$(bash "$SPAWN" '' codex demo 2>&1); code=$?
[[ "$code" -ne 0 ]] || { echo "FAIL: empty commander accepted" >&2; exit 1; }
pass "empty commander rejected"

# 3. Over-length commander rejected.
LONG=$(printf 'a%.0s' {1..40})   # 40 chars > 32 limit
out=$(bash "$SPAWN" "$LONG" codex demo 2>&1); code=$?
assert_eq "$code" "2" "over-length commander exits 2"
pass "over-length commander rejected"

# 4. Bad topic still rejected (existing behavior preserved).
out=$(bash "$SPAWN" rex codex 'BAD TOPIC' 2>&1); code=$?
assert_eq "$code" "2" "bad topic exits 2"
assert_contains "$out" "topic" "error mentions topic"
pass "bad topic rejected"

# 5. Valid commander+topic but no tmux → fails AFTER input validation, with the
#    tmux-specific error message (proves validation didn't accidentally pass through).
out=$(bash "$SPAWN" rex codex demo 2>&1); code=$?
[[ "$code" -ne 0 ]] || { echo "FAIL: spawn unexpectedly succeeded outside tmux" >&2; exit 1; }
assert_contains "$out" "tmux" "tmux-not-running error reaches stderr"
pass "valid args reach tmux check"

echo "  ALL: ok"
```

- [ ] **Step 3.2: Run the test to verify it fails**

```bash
cd /home/liupan/CC/clone-wars && bash tests/test_spawn_validation.sh
```

Expected: FAIL on test 1 (no commander regex today; bad chars proceed past validation and hit tmux check, producing different exit code/output).

- [ ] **Step 3.3: Reorder + add commander validation in `spawn.sh`**

Current validation block (lines 59-82) — replace:

```bash
# ------------------------------------------------------------ Validation

cw_in_tmux_session  || { log_error "must run inside a tmux session"; exit 1; }
cw_have_cmd tmux    || { log_error "tmux not on PATH"; exit 1; }
cw_tmux_version_ok  || { log_error "tmux >= 3.0 required"; exit 1; }

if ! [[ "$TOPIC" =~ ^[a-z0-9-]+$ ]] || (( ${#TOPIC} > 32 )); then
  log_error "topic must match [a-z0-9-]+ and be <= 32 chars; got: '$TOPIC'"
  exit 2
fi

if [[ "$COMMANDER" == "random" ]]; then
  COMMANDER=$(cw_commander_pick_random "$TOPIC") || {
    log_error "no available commander in pool for topic '$TOPIC'"
    exit 1
  }
  log_info "random pick: $COMMANDER"
fi

if cw_commander_in_use "$COMMANDER" "$TOPIC"; then
  log_error "$COMMANDER is already deployed on $TOPIC; pick another commander"
  log_error "  or run: /clone-wars:teardown $COMMANDER $TOPIC"
  exit 1
fi
```

Replace with (input validation moved BEFORE tmux check; commander regex added; `random` resolved AFTER syntactic validation but BEFORE in-use check):

```bash
# ------------------------------------------------------------ Input validation
# Run this FIRST so malformed args fail fast without depending on tmux/state.
# Both regexes match: lowercase, digits, hyphens; 1-32 chars.
if ! [[ "$TOPIC" =~ ^[a-z0-9-]+$ ]] || (( ${#TOPIC} > 32 )); then
  log_error "topic must match [a-z0-9-]+ and be <= 32 chars; got: '$TOPIC'"
  exit 2
fi
# 'random' is a sentinel — let it through; it's resolved against the pool below.
if [[ "$COMMANDER" != "random" ]]; then
  if ! [[ "$COMMANDER" =~ ^[a-z0-9-]+$ ]] || (( ${#COMMANDER} > 32 )) || [[ -z "$COMMANDER" ]]; then
    log_error "commander must match [a-z0-9-]+ and be <= 32 chars (or 'random'); got: '$COMMANDER'"
    exit 2
  fi
fi

# ------------------------------------------------------------ Environment validation

cw_in_tmux_session  || { log_error "must run inside a tmux session"; exit 1; }
cw_have_cmd tmux    || { log_error "tmux not on PATH"; exit 1; }
cw_tmux_version_ok  || { log_error "tmux >= 3.0 required"; exit 1; }

if [[ "$COMMANDER" == "random" ]]; then
  COMMANDER=$(cw_commander_pick_random "$TOPIC") || {
    log_error "no available commander in pool for topic '$TOPIC'"
    exit 1
  }
  log_info "random pick: $COMMANDER"
fi

if cw_commander_in_use "$COMMANDER" "$TOPIC"; then
  log_error "$COMMANDER is already deployed on $TOPIC; pick another commander"
  log_error "  or run: /clone-wars:teardown $COMMANDER $TOPIC"
  exit 1
fi
```

- [ ] **Step 3.4: Run the new test to verify it passes**

```bash
cd /home/liupan/CC/clone-wars && bash tests/test_spawn_validation.sh
```

Expected: All 5 `PASS:` lines, then `ALL: ok`.

- [ ] **Step 3.5: Run the full suite**

```bash
cd /home/liupan/CC/clone-wars && bash tests/run.sh
```

Expected: every test passes.

- [ ] **Step 3.6: Commit**

```bash
cd /home/liupan/CC/clone-wars
git add bin/spawn.sh tests/test_spawn_validation.sh
git commit -m "$(cat <<'EOF'
fix(spawn): validate commander chars + reorder input checks (#2)

Adds the same regex enforcement to commander that topic already had:
^[a-z0-9-]+$, <= 32 chars. 'random' stays a valid sentinel resolved
against the pool. Pool membership stays advisory.

Reorders validation: input syntax first (no tmux/state needed), then
environment (tmux running, version, etc.). Lets us unit-test the
input-validation behavior without standing up a tmux session, and
gives the user the failure they care about first.

Closes the path where 'evil|payload' (or any shell-special chars)
would propagate into sed, log messages, and state-dir paths.
EOF
)"
```

---

## Task 4 — `lib/ipc.sh` + 4 bin scripts: persist `model` in `pane.json` (#3)

**Why fourth:** Touches the most files (1 lib + 4 bins), best done in isolation. Backward-compat preserved via dir-name fallback so any in-flight v0.0.3 troopers continue working.

**Files:**
- Modify: `/home/liupan/CC/clone-wars/lib/ipc.sh:128-143` (`cw_pane_meta_write` + `cw_pane_meta_read`; add `cw_pane_meta_model`)
- Modify: `/home/liupan/CC/clone-wars/bin/send.sh:30-45` (model resolution)
- Modify: `/home/liupan/CC/clone-wars/bin/list.sh:34-63` (model resolution per-trooper)
- Modify: `/home/liupan/CC/clone-wars/bin/collect.sh:32-43` (model resolution)
- Modify: `/home/liupan/CC/clone-wars/bin/teardown.sh:57-66, 113-123` (model resolution in both branches)
- Test: `/home/liupan/CC/clone-wars/tests/test_pane_meta.sh` (new)

- [ ] **Step 4.1: Write the failing test**

Create `tests/test_pane_meta.sh`:

```bash
#!/usr/bin/env bash
# tests/test_pane_meta.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/state.sh
source ../lib/ipc.sh

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

# 1. cw_pane_meta_write embeds the model field.
mkdir -p "$(cw_trooper_dir rex codex demo)"
cw_pane_meta_write rex codex demo '%42'
META=$(cw_pane_meta_path rex codex demo)
assert_file_exists "$META" "pane.json created"
grep -q '"pane_id":"%42"' "$META" || { echo "FAIL: pane_id missing" >&2; exit 1; }
grep -q '"model":"codex"' "$META" || { echo "FAIL: model field missing" >&2; exit 1; }
pass "pane_meta_write embeds model"

# 2. cw_pane_meta_model returns the model field when present.
got=$(cw_pane_meta_model rex codex demo)
assert_eq "$got" "codex" "reader returns embedded model"
pass "pane_meta_model returns embedded value"

# 3. Hyphenated model keys round-trip cleanly (the whole point of #3).
mkdir -p "$(cw_trooper_dir rex claude-haiku demo)"
cw_pane_meta_write rex claude-haiku demo '%99'
got=$(cw_pane_meta_model rex claude-haiku demo)
assert_eq "$got" "claude-haiku" "hyphenated model round-trips"
pass "hyphenated model"

# 4. Backward compat: pane.json without "model" field falls back to dir-name parse.
mkdir -p "$(cw_trooper_dir cody codex demo)"
META_OLD=$(cw_pane_meta_path cody codex demo)
printf '{"pane_id":"%%55","spawned_at":"2026-04-26T00:00:00Z"}\n' > "$META_OLD"
# Capture stderr to verify the deprecation warning fires (once).
out=$(cw_pane_meta_model cody codex demo 2>&1 1>/tmp/cw-meta-out)
val=$(cat /tmp/cw-meta-out); rm -f /tmp/cw-meta-out
assert_eq "$val" "codex" "fallback returns dir-parsed model"
assert_contains "$out" "deprecation" "fallback emits deprecation warning"
pass "backward-compat fallback"

# 5. Warning fires only ONCE per shell invocation.
out2=$(cw_pane_meta_model cody codex demo 2>&1 1>/dev/null)
[[ -z "$out2" ]] || { echo "FAIL: warning fired twice; out2='$out2'" >&2; exit 1; }
pass "fallback warning is one-shot"

echo "  ALL: ok"
```

- [ ] **Step 4.2: Run the test to verify it fails**

```bash
cd /home/liupan/CC/clone-wars && bash tests/test_pane_meta.sh
```

Expected: FAIL on test 1 (no `model` field today) — `cw_pane_meta_write` only writes `pane_id` + `spawned_at`.

- [ ] **Step 4.3: Update `lib/ipc.sh` (write `model`, add reader, add fallback)**

Replace `cw_pane_meta_write` and `cw_pane_meta_read` (lines 128-143) with:

```bash
# cw_pane_meta_write <commander> <model> <topic> <pane_id>
# Write pane.json. v0.0.4 adds "model" so consumers don't have to parse the
# state dir name (which broke for hyphenated model keys).
cw_pane_meta_write() {
  local commander="$1" model="$2" topic="$3" pane="$4"
  local meta; meta=$(cw_pane_meta_path "$commander" "$model" "$topic")
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  printf '{"pane_id":"%s","model":"%s","spawned_at":"%s"}\n' "$pane" "$model" "$ts" > "$meta"
}

# cw_pane_meta_read <commander> <model> <topic>
# Print the pane_id from pane.json, or empty + return 1 if missing.
cw_pane_meta_read() {
  local meta; meta=$(cw_pane_meta_path "$1" "$2" "$3")
  [[ -f "$meta" ]] || return 1
  awk -F'"' '/"pane_id"/ {print $4; exit}' "$meta"
}

# Internal one-shot guard so the fallback warning fires at most once per
# shell invocation (per fallback path), not once per trooper iterated.
_CW_PANE_META_FALLBACK_WARNED=""

# cw_pane_meta_model <commander> <model_hint> <topic>
# Return the model recorded in pane.json. Falls back to <model_hint> (the
# value derived from the state dir name by the caller) when pane.json
# pre-dates v0.0.4 and lacks the field; emits a one-time deprecation warning.
cw_pane_meta_model() {
  local commander="$1" model_hint="$2" topic="$3"
  local meta; meta=$(cw_pane_meta_path "$commander" "$model_hint" "$topic")
  if [[ -f "$meta" ]]; then
    local val
    val=$(awk -F'"' '/"model"/ {print $4; exit}' "$meta")
    if [[ -n "$val" ]]; then
      printf '%s\n' "$val"
      return 0
    fi
  fi
  if [[ -z "$_CW_PANE_META_FALLBACK_WARNED" ]]; then
    log_warn "pane.json predates v0.0.4 (no 'model' field); using dir-name parser as fallback. This is a deprecation notice and will be removed in a future version."
    _CW_PANE_META_FALLBACK_WARNED=1
  fi
  printf '%s\n' "$model_hint"
}
```

Note: `cw_pane_meta_model`'s second arg is a `model_hint` — the caller passes the dir-parsed value as a fallback so `cw_pane_meta_path` can locate the file, and the same value is returned if pane.json lacks `model`. This is by design: the function is meant to be a drop-in for the existing dir-parse pattern.

- [ ] **Step 4.4: Run the test to verify it passes**

```bash
cd /home/liupan/CC/clone-wars && bash tests/test_pane_meta.sh
```

Expected: All 5 `PASS:` lines, then `ALL: ok`.

- [ ] **Step 4.5: Update `bin/send.sh` to use `cw_pane_meta_model`**

In `bin/send.sh`, replace lines 30-45:

```bash
# ------------------------------------------------------------ Resolve model

TOPIC_DIR="$(cw_state_root)/state/$(cw_repo_hash)/$TOPIC"
MODEL=""
if [[ -d "$TOPIC_DIR" ]]; then
  for d in "$TOPIC_DIR"/${COMMANDER}-*; do
    [[ -d "$d" ]] || continue
    MODEL="${d##*/${COMMANDER}-}"
    break
  done
fi
if [[ -z "$MODEL" ]]; then
  log_error "no trooper '$COMMANDER' on topic '$TOPIC' (state dir absent)"
  log_error "  spawn first: /clone-wars:spawn $COMMANDER <model> $TOPIC"
  exit 1
fi
```

with:

```bash
# ------------------------------------------------------------ Resolve model
# Locate the state dir (its name's last segment is the model hint), then
# read the canonical model from pane.json (v0.0.4+); fallback to hint for
# legacy state dirs.

TOPIC_DIR="$(cw_state_root)/state/$(cw_repo_hash)/$TOPIC"
MODEL_HINT=""
if [[ -d "$TOPIC_DIR" ]]; then
  for d in "$TOPIC_DIR"/${COMMANDER}-*; do
    [[ -d "$d" ]] || continue
    MODEL_HINT="${d##*/${COMMANDER}-}"
    break
  done
fi
if [[ -z "$MODEL_HINT" ]]; then
  log_error "no trooper '$COMMANDER' on topic '$TOPIC' (state dir absent)"
  log_error "  spawn first: /clone-wars:spawn $COMMANDER <model> $TOPIC"
  exit 1
fi
MODEL=$(cw_pane_meta_model "$COMMANDER" "$MODEL_HINT" "$TOPIC")
```

- [ ] **Step 4.6: Update `bin/collect.sh` similarly**

In `bin/collect.sh`, replace lines 32-43:

```bash
# ------------------------------------------------------------ Resolve model

TOPIC_DIR="$(cw_state_root)/state/$(cw_repo_hash)/$TOPIC"
MODEL=""
if [[ -d "$TOPIC_DIR" ]]; then
  for d in "$TOPIC_DIR"/${COMMANDER}-*; do
    [[ -d "$d" ]] || continue
    MODEL="${d##*/${COMMANDER}-}"
    break
  done
fi
[[ -n "$MODEL" ]] || { log_error "no trooper '$COMMANDER' on topic '$TOPIC'"; exit 1; }
```

with:

```bash
# ------------------------------------------------------------ Resolve model

TOPIC_DIR="$(cw_state_root)/state/$(cw_repo_hash)/$TOPIC"
MODEL_HINT=""
if [[ -d "$TOPIC_DIR" ]]; then
  for d in "$TOPIC_DIR"/${COMMANDER}-*; do
    [[ -d "$d" ]] || continue
    MODEL_HINT="${d##*/${COMMANDER}-}"
    break
  done
fi
[[ -n "$MODEL_HINT" ]] || { log_error "no trooper '$COMMANDER' on topic '$TOPIC'"; exit 1; }
MODEL=$(cw_pane_meta_model "$COMMANDER" "$MODEL_HINT" "$TOPIC")
```

- [ ] **Step 4.7: Update `bin/list.sh` (per-trooper inside the loop)**

In `bin/list.sh`, in the inner loop (line 38-62), the existing parsing is:

```bash
    name="${trooper_dir%/}"; name="${name##*/}"
    commander="${name%-*}"
    model="${name##*-}"
    pane=$(cw_pane_meta_read "$commander" "$model" "$topic" 2>/dev/null || echo '?')
```

Replace with:

```bash
    name="${trooper_dir%/}"; name="${name##*/}"
    commander="${name%-*}"
    model_hint="${name##*-}"
    model=$(cw_pane_meta_model "$commander" "$model_hint" "$topic")
    pane=$(cw_pane_meta_read "$commander" "$model" "$topic" 2>/dev/null || echo '?')
```

Note: `model` (not `model_hint`) is now used in the rest of the loop body — `cw_outbox_path "$commander" "$model" "$topic"`, the `printf` at the end. The local `model` shadows the dir-parse value with the canonical pane.json value when available.

- [ ] **Step 4.8: Update `bin/teardown.sh` (both branches)**

In `bin/teardown.sh:57-66` (the `teardown_topic` loop):

Current:

```bash
  for trooper_dir in "$topic_dir"/*/; do
    [[ -d "$trooper_dir" ]] || continue
    local name="${trooper_dir%/}"; name="${name##*/}"
    local commander="${name%-*}" model="${name##*-}"
    local pane; pane=$(cw_pane_meta_read "$commander" "$model" "$topic" 2>/dev/null || echo '')
```

Replace with:

```bash
  for trooper_dir in "$topic_dir"/*/; do
    [[ -d "$trooper_dir" ]] || continue
    local name="${trooper_dir%/}"; name="${name##*/}"
    local commander="${name%-*}" model_hint="${name##*-}"
    local model; model=$(cw_pane_meta_model "$commander" "$model_hint" "$topic")
    local pane; pane=$(cw_pane_meta_read "$commander" "$model" "$topic" 2>/dev/null || echo '')
```

In `bin/teardown.sh:113-123` (the 2-arg branch):

Current:

```bash
      for d in "$topic_dir"/${commander}-*/; do
        [[ -d "$d" ]] || continue
        name="${d%/}"; name="${name##*/}"
        model="${name##*-}"
        pane=$(cw_pane_meta_read "$commander" "$model" "$topic" 2>/dev/null || echo '')
```

Replace with:

```bash
      for d in "$topic_dir"/${commander}-*/; do
        [[ -d "$d" ]] || continue
        name="${d%/}"; name="${name##*/}"
        model_hint="${name##*-}"
        model=$(cw_pane_meta_model "$commander" "$model_hint" "$topic")
        pane=$(cw_pane_meta_read "$commander" "$model" "$topic" 2>/dev/null || echo '')
```

- [ ] **Step 4.9: Lint-pass every changed bin script**

```bash
cd /home/liupan/CC/clone-wars
for f in bin/spawn.sh bin/send.sh bin/collect.sh bin/list.sh bin/teardown.sh; do
  bash -n "$f" && echo "$f: syntax OK" || { echo "$f: SYNTAX ERROR"; exit 1; }
done
```

Expected: all 5 lines say `syntax OK`.

- [ ] **Step 4.10: Run the full test suite**

```bash
cd /home/liupan/CC/clone-wars && bash tests/run.sh
```

Expected: every test passes including the new `test_pane_meta.sh`.

- [ ] **Step 4.11: Commit**

```bash
cd /home/liupan/CC/clone-wars
git add lib/ipc.sh bin/send.sh bin/collect.sh bin/list.sh bin/teardown.sh tests/test_pane_meta.sh
git commit -m "$(cat <<'EOF'
fix(ipc): persist model in pane.json (#3)

cw_pane_meta_write now embeds "model" alongside pane_id + spawned_at.
Adds cw_pane_meta_model that reads the field with a one-time
deprecation warning fallback to the legacy dir-name parser.

send/collect/list/teardown all switched to cw_pane_meta_model so
hyphenated model keys (e.g. 'claude-haiku', 'codex-mini') round-trip
correctly. Backward compat preserved for in-flight v0.0.3 troopers.
EOF
)"
```

---

## Task 5 — `bin/medic.sh`: check `pane-border-status` (#4)

**Files:**
- Modify: `/home/liupan/CC/clone-wars/bin/medic.sh:53-66`

No new test file — the medic check is straightforward and the existing test surface is integration-level. Verified visually post-merge.

- [ ] **Step 5.1: Patch the medic block**

Current `bin/medic.sh:53-66`:

```bash
if cw_in_tmux_session && tmux info >/dev/null 2>&1; then
  pbf=$(tmux show-options -g pane-border-format 2>/dev/null)
  if [[ "$pbf" == *@cw_label* ]]; then
    log_ok "pane-border-format: @cw_label-aware (trooper names visible on pane borders)"
  else
    log_warn "pane-border-format doesn't read @cw_label; trooper names won't show on pane borders"
    log_warn "  fix: add to ~/.tmux.conf:"
    log_warn "    set -g pane-border-status top"
    log_warn "    set -g pane-border-format ' #{?@cw_label_fmt,#{@cw_label_fmt},#[fg=#{?@cw_color,#{@cw_color},default}#,bold]#{?@cw_label,#{@cw_label},#{pane_title}}#[default]} '"
    log_warn "  optional: focused trooper pane gets its commander's color outline"
    log_warn "    set-hook -g after-select-pane 'set-option -g pane-active-border-style \"fg=#{?@cw_color,#{@cw_color},green}\"'"
    warn=1
  fi
fi
```

Replace with:

```bash
if cw_in_tmux_session && tmux info >/dev/null 2>&1; then
  pbf=$(tmux show-options -g pane-border-format 2>/dev/null)
  pbs=$(tmux show-options -gv pane-border-status 2>/dev/null || true)
  fix_msg() {
    log_warn "  fix: add to ~/.tmux.conf:"
    log_warn "    set -g pane-border-status top"
    log_warn "    set -g pane-border-format ' #{?@cw_label_fmt,#{@cw_label_fmt},#[fg=#{?@cw_color,#{@cw_color},default}#,bold]#{?@cw_label,#{@cw_label},#{pane_title}}#[default]} '"
    log_warn "  optional: focused trooper pane gets its commander's color outline"
    log_warn "    set-hook -g after-select-pane 'set-option -g pane-active-border-style \"fg=#{?@cw_color,#{@cw_color},green}\"'"
  }
  if [[ "$pbs" != "top" && "$pbs" != "bottom" ]]; then
    log_warn "pane-border-status is '${pbs:-off}'; trooper labels won't render on pane borders"
    fix_msg
    warn=1
  elif [[ "$pbf" != *@cw_label* ]]; then
    log_warn "pane-border-format doesn't read @cw_label; trooper names won't show on pane borders"
    fix_msg
    warn=1
  else
    log_ok "pane-border: status=$pbs, format @cw_label-aware (trooper names visible)"
  fi
fi
```

Note: combines both checks. If both are wrong, `pane-border-status` is reported first (it's the upstream issue); fixing status alone may still leave format wrong, but they share the same fix message so the user sees the full snippet either way.

- [ ] **Step 5.2: Lint-pass**

```bash
cd /home/liupan/CC/clone-wars && bash -n bin/medic.sh && echo "syntax OK"
```

Expected: `syntax OK`.

- [ ] **Step 5.3: Run existing medic tests**

```bash
cd /home/liupan/CC/clone-wars && bash tests/run.sh
```

Expected: every test passes (including `test_medic.sh`, which doesn't exercise the tmux block — it exits early outside tmux).

- [ ] **Step 5.4: Manual verification (in tmux)**

```bash
# In a tmux session:
tmux set -g pane-border-status off
bash bin/medic.sh
# Expect: WARN line for pane-border-status with the fix snippet.

tmux set -g pane-border-status top
bash bin/medic.sh
# Expect: OK line "pane-border: status=top, format @cw_label-aware ..."
```

- [ ] **Step 5.5: Commit**

```bash
cd /home/liupan/CC/clone-wars
git add bin/medic.sh
git commit -m "$(cat <<'EOF'
fix(medic): check pane-border-status alongside format (#4)

Medic previously only WARNed when pane-border-format wasn't @cw_label-
aware, but ignored pane-border-status. A user with a correct format
but status=off saw no labels and a green OK from medic. Now we check
both: status must be top or bottom AND format must reference @cw_label.
Same fix message either way.
EOF
)"
```

---

## Task 6 — `lib/argsfile.sh` + `commands/*.md` + `bin/*.sh`: shell-injection fence (#5)

**Why last:** Touches the most files (1 new lib + 6 commands + 6 bin scripts). Doing it last avoids merge conflicts with prior tasks.

**Files:**
- Create: `/home/liupan/CC/clone-wars/lib/argsfile.sh`
- Modify: each of `bin/spawn.sh`, `bin/send.sh`, `bin/collect.sh`, `bin/list.sh`, `bin/teardown.sh`, `bin/medic.sh` (add `--args-file` parsing block at top of arg handling)
- Modify: each of `commands/spawn.md`, `commands/send.md`, `commands/collect.md`, `commands/list.md`, `commands/teardown.md`, `commands/medic.md` (switch from `$ARGUMENTS` inline to temp-file)
- Test: `/home/liupan/CC/clone-wars/tests/test_argsfile.sh` (new)

- [ ] **Step 6.1: Write the failing test**

Create `tests/test_argsfile.sh`:

```bash
#!/usr/bin/env bash
# tests/test_argsfile.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/argsfile.sh 2>/dev/null || true   # tolerate missing during pre-impl run

# 1. Empty file → no tokens.
TMP=$(mktemp); trap 'rm -f "$TMP" "$TMP".*' EXIT
mapfile -t TOKS < <(cw_args_file_load "$TMP")
assert_eq "${#TOKS[@]}" "0" "empty file → 0 tokens"
pass "empty file"

# 2. Simple whitespace-separated tokens.
echo 'rex codex demo' > "$TMP"
mapfile -t TOKS < <(cw_args_file_load "$TMP")
assert_eq "${#TOKS[@]}" "3" "3 tokens"
assert_eq "${TOKS[0]}" "rex"
assert_eq "${TOKS[1]}" "codex"
assert_eq "${TOKS[2]}" "demo"
pass "simple tokens"

# 3. Quoted multi-word arg stays one token.
echo 'rex codex demo "do the auth review please"' > "$TMP"
mapfile -t TOKS < <(cw_args_file_load "$TMP")
assert_eq "${#TOKS[@]}" "4" "4 tokens including the quoted phrase"
assert_eq "${TOKS[3]}" "do the auth review please" "quoted phrase preserved"
pass "quoted arg"

# 4. Adversarial: shell metacharacters in a literal token are NOT executed.
echo 'rex codex demo "; rm -rf /"' > "$TMP"
mapfile -t TOKS < <(cw_args_file_load "$TMP")
assert_eq "${#TOKS[@]}" "4" "4 tokens"
assert_eq "${TOKS[3]}" "; rm -rf /" "metacharacters preserved as literal text"
pass "metacharacters quoted-safe"

echo "  ALL: ok"
```

- [ ] **Step 6.2: Run the test to verify it fails**

```bash
cd /home/liupan/CC/clone-wars && bash tests/test_argsfile.sh
```

Expected: FAIL — `lib/argsfile.sh` doesn't exist yet. The `source ... || true` swallows the missing-file error but `cw_args_file_load` is undefined, so the first call exits with "command not found".

- [ ] **Step 6.3: Create `lib/argsfile.sh`**

```bash
# lib/argsfile.sh — shell-tokenize a one-line args file into stdout, one
# token per line. Supports double-quoted phrases preserved as a single token.
# Used by bin/*.sh when invoked via `--args-file <path>` from the command
# markdown directives — fences off shell injection from $ARGUMENTS.
#
# Parsing semantics: standard bash word-splitting via `read -ra` against
# the file's first line, EXCEPT we run it inside a controlled subshell with
# default IFS so shell metacharacters in the file are NOT re-interpreted —
# they survive as literal text inside their containing quoted token.

cw_args_file_load() {
  local path="$1"
  [[ -f "$path" ]] || return 1
  local line
  IFS= read -r line < "$path" || true
  [[ -n "$line" ]] || return 0
  # Use eval-with-printf trick: wrap each token in single quotes via xargs,
  # then declare into an array. xargs handles double-quoted phrases per its
  # standard parsing rules.
  local tokens=()
  while IFS= read -r tok; do
    tokens+=("$tok")
  done < <(printf '%s\n' "$line" | xargs -n1 printf '%s\n' 2>/dev/null)
  printf '%s\n' "${tokens[@]}"
}
```

Note on parser choice: `xargs -n1` honors POSIX shell quoting (single + double quotes) and prints one token per line. It does NOT execute the contents — a token like `"; rm -rf /"` becomes literal text `; rm -rf /` after quote-stripping. This is the standard "process arguments without shell expansion" trick.

- [ ] **Step 6.4: Run the test to verify it passes**

```bash
cd /home/liupan/CC/clone-wars && bash tests/test_argsfile.sh
```

Expected: All 4 `PASS:` lines, then `ALL: ok`.

- [ ] **Step 6.5: Add `--args-file` parsing block to each `bin/*.sh`**

Pattern: insert this block immediately AFTER the `source` lines and BEFORE the existing arg parser. Place once at the top of each script so the rest of arg parsing is unchanged.

For `bin/spawn.sh`, add after line 29 (`source "$PLUGIN_ROOT/lib/tmux.sh"`):

```bash
source "$PLUGIN_ROOT/lib/argsfile.sh"

# --args-file <path> — read tokens from <path> and replace positional args.
# Used by commands/*.md to fence off shell injection from $ARGUMENTS.
if [[ "${1:-}" == "--args-file" ]]; then
  [[ -n "${2:-}" ]] || { echo "--args-file requires a path" >&2; exit 2; }
  args_file="$2"
  shift 2
  mapfile -t _TOKENS < <(cw_args_file_load "$args_file")
  set -- "${_TOKENS[@]}" "$@"
fi
```

Repeat for `bin/send.sh`, `bin/collect.sh`, `bin/list.sh`, `bin/teardown.sh`, `bin/medic.sh` — same block, inserted after the last `source` line of each.

- [ ] **Step 6.6: Update each `commands/*.md` to use the temp-file flow**

For `commands/spawn.md`, replace the Steps section with:

```markdown
## Steps

1. Use the Bash tool to write `$ARGUMENTS` to a temp file and invoke spawn:

   ```
   ARGS_FILE=$(mktemp -t cw-args-XXXXXX) && \
     printf '%s\n' "$ARGUMENTS" > "$ARGS_FILE" && \
     "${CLAUDE_PLUGIN_ROOT}/bin/spawn.sh" --args-file "$ARGS_FILE"; \
     rc=$?; rm -f "$ARGS_FILE"; exit $rc
   ```

2. Show the script's output to the user verbatim — it reports the spawned pane id, state
   directory, and ready status.

3. If spawn FAILs, the script also dumps the trooper pane's last 25 lines and its outbox
   contents to stderr — surface those to the user so they can diagnose. Common causes:
   commander already deployed on this topic (run `/clone-wars:teardown <commander> <topic>`
   first), provider binary not on PATH, or the trooper TUI took longer than the
   `ready_timeout_s` from `contracts.yaml` (raise it for that provider).
```

Apply the analogous edit to `commands/send.md`, `commands/collect.md`, `commands/list.md`, `commands/teardown.md`, `commands/medic.md` — replace the `$ARGUMENTS`-inline invocation with the temp-file pattern, substituting the right verb. Keep all the existing "show output verbatim" / "if FAIL" guidance below the Bash invocation block.

- [ ] **Step 6.7: Lint-pass every bin script**

```bash
cd /home/liupan/CC/clone-wars
for f in bin/*.sh; do
  bash -n "$f" && echo "$f: syntax OK" || { echo "$f: SYNTAX ERROR"; exit 1; }
done
```

Expected: every script `syntax OK`.

- [ ] **Step 6.8: Run the full test suite**

```bash
cd /home/liupan/CC/clone-wars && bash tests/run.sh
```

Expected: every test passes including the new `test_argsfile.sh`.

- [ ] **Step 6.9: Manual smoke-test the temp-file path (in tmux)**

```bash
# In a tmux session:
ARGS=$(mktemp); printf '%s\n' 'rex codex argsmoke' > "$ARGS"
bash bin/spawn.sh --args-file "$ARGS"
# Expect: identical behavior to `bash bin/spawn.sh rex codex argsmoke`.
bash bin/teardown.sh argsmoke
rm -f "$ARGS"
```

- [ ] **Step 6.10: Commit**

```bash
cd /home/liupan/CC/clone-wars
git add lib/argsfile.sh bin/*.sh commands/*.md tests/test_argsfile.sh
git commit -m "$(cat <<'EOF'
fix(commands): fence off shell injection from \$ARGUMENTS (#5)

Each commands/*.md now writes \$ARGUMENTS to a mktemp'd file and
invokes the bin script with --args-file <path> instead of inlining
\$ARGUMENTS into the bash command line. The bin scripts read the file
via lib/argsfile.sh's cw_args_file_load (xargs-based, quote-aware,
no shell expansion).

A user typing /clone-wars:spawn rex codex demo \"; rm -rf /\" now
gets the literal string ; rm -rf / as the prompt argument, not
a chained shell command.

Backward compatible: bin scripts still accept positional args directly
when invoked from the CLI without --args-file.
EOF
)"
```

---

## Task 7 — Bump to `v0.0.4`

**Files:**
- Modify: `/home/liupan/CC/clone-wars/.claude-plugin/plugin.json:3`
- Modify: `/home/liupan/CC/clone-wars/.claude-plugin/marketplace.json:13,29`

- [ ] **Step 7.1: Update `plugin.json`**

In `.claude-plugin/plugin.json`, change `"version": "0.0.3"` → `"version": "0.0.4"`.

- [ ] **Step 7.2: Update `marketplace.json`**

In `.claude-plugin/marketplace.json`, change both `"version": "0.0.3"` occurrences (the per-plugin entry and the top-level marketplace version) to `"version": "0.0.4"`.

- [ ] **Step 7.3: Run the full test suite one last time**

```bash
cd /home/liupan/CC/clone-wars && bash tests/run.sh
```

Expected: every test passes.

- [ ] **Step 7.4: Commit**

```bash
cd /home/liupan/CC/clone-wars
git add .claude-plugin/plugin.json .claude-plugin/marketplace.json
git commit -m "$(cat <<'EOF'
chore: bump version 0.0.3 → 0.0.4 (Phase 1 hardening release)

Phase 1 of the hardening rollout per
docs/superpowers/specs/2026-04-26-clone-wars-hardening-design.md.

Includes:
- spawn rolls back state dir on bootstrap failure (#1)
- commander-name validation + reordered input checks (#2)
- model field persisted in pane.json (#3)
- medic checks pane-border-status alongside format (#4)
- shell-injection fence on \$ARGUMENTS via --args-file (#5)
EOF
)"
```

---

## Task 8 — Open the PR

**Files:** none (git/gh operations only).

- [ ] **Step 8.1: Push the branch**

```bash
cd /home/liupan/CC/clone-wars
git push -u origin chore/v0.0.4-hardening-phase-1
```

(Branch should have been created at the start of implementation — `git checkout -b chore/v0.0.4-hardening-phase-1` before Task 1's commit.)

- [ ] **Step 8.2: Open the PR with the standard body**

```bash
gh pr create --title "chore: v0.0.4 — Phase 1 hardening (fixes #1-#5)" --body "$(cat <<'EOF'
## Summary
Phase 1 of the hardening rollout per the locked spec at
\`docs/superpowers/specs/2026-04-26-clone-wars-hardening-design.md\`.

Fixes:
- **#1** Spawn rolls back state dir on bootstrap failure → archived with \`-FAILED\` suffix.
- **#2** Commander-name validation + input-check reorder (validation now runs before tmux check, enabling unit tests).
- **#3** \`pane.json\` persists \`model\` so hyphenated model keys round-trip; backward-compat fallback to dir-name parser with one-time deprecation warning.
- **#4** Medic checks \`pane-border-status\` alongside format.
- **#5** Shell-injection fence on \`$ARGUMENTS\` via temp-file + \`--args-file\` flag; bin scripts gain \`lib/argsfile.sh\` for shell-safe parsing.

Bumps to **v0.0.4**.

## Test plan
- [x] Unit suite: \`bash tests/run.sh\` — passes (4 test files added, 22+ tests).
- [ ] Manual smoke after merge + retag + \`/plugin update\`:
  - Spawn 3 troopers on a topic, verify \`pane.json\` contains \`"model"\` field.
  - Trigger a bootstrap failure (e.g. set \`codex.binary: codex-bogus\`), verify state archived as \`-FAILED\`, verify retry succeeds.
  - Run \`/clone-wars:spawn 'evil|payload' codex demo\` — verify rejected with exit 2 and clear error.
  - Run \`/clone-wars:medic\` with \`pane-border-status off\` — verify WARN.
  - Run \`/clone-wars:spawn rex codex demo \"; rm -rf /\"\` — verify the chained command does NOT execute.
- [ ] Existing in-flight v0.0.3 troopers (none expected, but pane.json without \`model\` field) → fallback warning fires once, then commands succeed.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 8.3: Surface the PR URL to the user**

The user will merge, retag (\`v0.0.4\`), and run \`/plugin update\`. Plan execution ends here — Phase 2 begins as a separate writing-plans cycle after Phase 1 is shipped.

---

## Self-review checklist

Before handing this plan off, verify:

- [x] **Spec coverage:** Each of #1–#5 has a dedicated task. Version bump and PR are explicit final tasks. ✓
- [x] **Placeholder scan:** No "TBD", "TODO", "implement later", or vague "add error handling" instructions. Every code step has the exact code; every command step has the exact invocation and expected output. ✓
- [x] **Type / signature consistency:**
  - `cw_state_archive` signature: `<commander> <model> <topic> [<suffix>]` — used identically in Task 1 (definition) and Task 2 (invocation). ✓
  - `cw_pane_meta_model` signature: `<commander> <model_hint> <topic>` — defined in Task 4.3, called identically in Task 4.5/4.6/4.7/4.8. ✓
  - `cw_args_file_load` signature: `<path>` — defined in Task 6.3, called identically in Task 6.5. ✓
- [x] **TDD discipline:** Every task that adds testable code has a failing-test step before the implementation step (Tasks 1, 3, 4, 6). Tasks without unit tests (2, 5) have explicit manual-smoke steps. ✓
- [x] **Frequent commits:** One commit per task. Engineer can stop after any commit and have working software. ✓
