# Clone Wars — Marketplace Shell (v0.0.1-pre1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship an installable marketplace-shell version of the `clone-wars` plugin (v0.0.1-pre1) — manifests, lib helpers, config defaults, README, and a fully-working `/clone-wars:medic`. The five runtime commands ship as stubs that print a "pending tracer-bullet validation" message; their working implementations are scoped to a separate plan (Plan B) gated on tracer-bullet results.

**Architecture:** Pure shell + tmux. Plugin manifests live in `.claude-plugin/`. Real executable shell scripts live under `bin/` (one per command). Lib helpers in `lib/` provide state-dir resolution (`$CLONE_WARS_HOME`), dependency detection, and minimal contracts.yaml parsing — sourced by `bin/*.sh`. Config defaults shipped in `config/` and copied to `$CLONE_WARS_HOME` on first medic run. Slash-command files in `commands/<verb>.md` are **thin instruction documents** that direct Claude to invoke the matching `${CLAUDE_PLUGIN_ROOT}/bin/<verb>.sh` via the Bash tool and report the output — they are NOT bash scripts. (This matches the convention used by every shipped Claude Code plugin: `hookify`, `claude-hud`, `claude-mem` — slash commands are markdown directives, not extractable scripts.) Tests are pure-bash scripts in `tests/` that exercise `bin/*.sh` directly; a tiny assertion helper lives in `tests/lib/assert.sh`.

**Tech Stack:** Bash 4.2+ (Linux + macOS), tmux 3.0+ at runtime (for Plan B; Plan A's medic only checks for it), no Node/Python deps in the runtime or tests, `awk`/`sed`/`grep` for YAML field extraction (no `yq` dependency).

---

## File Structure

```
clone-wars/
├── .claude-plugin/
│   ├── plugin.json                      ← NEW (Task 1)
│   └── marketplace.json                 ← NEW (Task 2)
├── bin/                                 ← NEW directory — real executable shell scripts
│   ├── medic.sh                         ← NEW (Task 16a) — full implementation
│   ├── spawn.sh                         ← NEW (Task 17a) — stub script
│   ├── send.sh                          ← NEW (Task 18a) — stub script
│   ├── collect.sh                       ← NEW (Task 18a) — stub script
│   ├── list.sh                          ← NEW (Task 18a) — stub script
│   └── teardown.sh                      ← NEW (Task 18a) — stub script
├── commands/                            ← thin instruction docs; Claude reads, not bash
│   ├── medic.md                         ← NEW (Task 16b)
│   ├── spawn.md                         ← NEW (Task 17b)
│   ├── send.md                          ← NEW (Task 18b)
│   ├── collect.md                       ← NEW (Task 18b)
│   ├── list.md                          ← NEW (Task 18b)
│   └── teardown.md                      ← NEW (Task 18b)
├── config/
│   ├── contracts.yaml                   ← NEW (Task 12)
│   ├── commanders.yaml                  ← NEW (Task 13)
│   ├── config.yaml                      ← NEW (Task 14)
│   └── identity-template.md             ← NEW (Task 15)
├── lib/
│   ├── log.sh                           ← NEW (Task 3) — info/warn/error/ok helpers
│   ├── state.sh                         ← NEW (Tasks 4–6) — $CLONE_WARS_HOME resolution
│   ├── deps.sh                          ← NEW (Tasks 7–9) — binary + version + tmux checks
│   └── contracts.sh                     ← NEW (Tasks 10–11) — provider enumeration from yaml
├── tests/
│   ├── lib/
│   │   └── assert.sh                    ← NEW (Task 3) — tiny assertion helper
│   ├── test_state.sh                    ← NEW (Tasks 4–6)
│   ├── test_deps.sh                     ← NEW (Tasks 7–9)
│   ├── test_contracts.sh                ← NEW (Tasks 10–11)
│   ├── test_medic.sh                    ← NEW (Task 16a)
│   └── run.sh                           ← NEW (Task 3) — test runner
├── README.md                            ← REWRITE (Task 19)
├── CLAUDE.md                            ← MINOR EDIT (Task 20) — update file tree
└── docs/DESIGN.md                       ← MINOR EDIT (Task 20) — six commands; --mode flag
```

`tracer/tracer-bullet.sh` is **not** touched by this plan. The tracer is Plan B's first task.

---

## Task 1: Plugin manifest

**Files:**
- Create: `.claude-plugin/plugin.json`

- [ ] **Step 1: Create the manifest**

```json
{
  "name": "clone-wars",
  "version": "0.0.1-pre1",
  "description": "Multi-model tmux pane orchestration for Claude Code — spawn codex/gemini/claude TUIs as attachable clone troopers",
  "author": {
    "name": "liupan",
    "email": "dragonrider.liupan@gmail.com"
  },
  "homepage": "https://github.com/WingsOfPanda/clone-wars",
  "repository": "https://github.com/WingsOfPanda/clone-wars",
  "license": "MIT",
  "keywords": [
    "claude-code",
    "plugin",
    "multi-agent",
    "orchestration",
    "tmux",
    "codex",
    "gemini"
  ]
}
```

- [ ] **Step 2: Validate JSON parses**

Run: `python3 -m json.tool .claude-plugin/plugin.json > /dev/null && echo OK`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add .claude-plugin/plugin.json
git commit -m "feat(manifest): add plugin.json for clone-wars v0.0.1-pre1"
```

---

## Task 2: Marketplace manifest

**Files:**
- Create: `.claude-plugin/marketplace.json`

- [ ] **Step 1: Create the manifest**

```json
{
  "$schema": "https://anthropic.com/claude-code/marketplace.schema.json",
  "name": "clone-wars",
  "description": "Multi-model tmux pane orchestration for Claude Code",
  "owner": {
    "name": "liupan",
    "email": "dragonrider.liupan@gmail.com"
  },
  "plugins": [
    {
      "name": "clone-wars",
      "description": "Spawn codex/gemini/claude TUIs as attachable tmux panes; orchestrate them via file-based IPC",
      "version": "0.0.1-pre1",
      "source": "./",
      "category": "orchestration",
      "homepage": "https://github.com/WingsOfPanda/clone-wars",
      "tags": [
        "multi-agent",
        "orchestration",
        "tmux",
        "delegation"
      ],
      "author": {
        "name": "liupan",
        "email": "dragonrider.liupan@gmail.com"
      }
    }
  ],
  "version": "0.0.1-pre1"
}
```

- [ ] **Step 2: Validate JSON parses**

Run: `python3 -m json.tool .claude-plugin/marketplace.json > /dev/null && echo OK`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add .claude-plugin/marketplace.json
git commit -m "feat(manifest): add marketplace.json for single-repo install path"
```

---

## Task 3: Test scaffolding + log helper

**Files:**
- Create: `tests/lib/assert.sh`
- Create: `tests/run.sh`
- Create: `lib/log.sh`

- [ ] **Step 1: Write the assertion helper**

```bash
# tests/lib/assert.sh — sourced by every test_*.sh
# Exits non-zero on first failure so tests fail fast.

assert_eq() {
  local actual="$1" expected="$2" msg="${3:-}"
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL: ${msg:-assert_eq}" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
    exit 1
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "FAIL: ${msg:-assert_contains}" >&2
    echo "  haystack: $haystack" >&2
    echo "  needle:   $needle" >&2
    exit 1
  fi
}

assert_exit() {
  local expected_code="$1"; shift
  local out
  out=$("$@" 2>&1); local code=$?
  if [[ "$code" -ne "$expected_code" ]]; then
    echo "FAIL: assert_exit expected $expected_code, got $code" >&2
    echo "  cmd: $*" >&2
    echo "  out: $out" >&2
    exit 1
  fi
}

assert_file_exists() {
  local path="$1" msg="${2:-}"
  if [[ ! -e "$path" ]]; then
    echo "FAIL: ${msg:-assert_file_exists}: $path missing" >&2
    exit 1
  fi
}

pass() { echo "  PASS: $*"; }
```

- [ ] **Step 2: Write the test runner**

```bash
#!/usr/bin/env bash
# tests/run.sh — discover and run every tests/test_*.sh; non-zero on any failure.
set -euo pipefail
cd "$(dirname "$0")"

fail=0
for t in test_*.sh; do
  echo "=== $t ==="
  if bash "$t"; then
    echo "  $t: ok"
  else
    echo "  $t: FAIL"
    fail=1
  fi
done

exit "$fail"
```

- [ ] **Step 3: Make runner executable**

Run: `chmod +x tests/run.sh`

- [ ] **Step 4: Write the log helper**

```bash
# lib/log.sh — colored status output for medic and friends.
# Sourced; exposes log_info, log_warn, log_error, log_ok.

if [[ -t 2 ]]; then
  _CW_RED=$'\033[31m'; _CW_GRN=$'\033[32m'; _CW_YEL=$'\033[33m'
  _CW_BLU=$'\033[34m'; _CW_RST=$'\033[0m'
else
  _CW_RED=''; _CW_GRN=''; _CW_YEL=''; _CW_BLU=''; _CW_RST=''
fi

log_info()  { printf '%s[INFO]%s  %s\n' "$_CW_BLU" "$_CW_RST" "$*" >&2; }
log_warn()  { printf '%s[WARN]%s  %s\n' "$_CW_YEL" "$_CW_RST" "$*" >&2; }
log_error() { printf '%s[FAIL]%s  %s\n' "$_CW_RED" "$_CW_RST" "$*" >&2; }
log_ok()    { printf '%s[ OK ]%s  %s\n' "$_CW_GRN" "$_CW_RST" "$*" >&2; }
```

- [ ] **Step 5: Smoke-test**

Run:
```bash
bash -c 'source lib/log.sh; log_info hi; log_warn warned; log_error broke; log_ok green'
```
Expected: four lines on stderr, one each of `[INFO]`, `[WARN]`, `[FAIL]`, `[ OK ]`.

- [ ] **Step 6: Commit**

```bash
git add tests/lib/assert.sh tests/run.sh lib/log.sh
git commit -m "feat(scaffolding): add test runner, assertion helpers, and log helper"
```

---

## Task 4: `lib/state.sh` — `cw_state_root`

**Files:**
- Create: `lib/state.sh` (new file, but extended in Tasks 5–6)
- Test: `tests/test_state.sh`

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# tests/test_state.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/state.sh

# 1. Default root is $HOME/.clone-wars when CLONE_WARS_HOME is unset.
unset CLONE_WARS_HOME
assert_eq "$(cw_state_root)" "$HOME/.clone-wars" "default root"
pass "default root"

# 2. Override via CLONE_WARS_HOME.
CLONE_WARS_HOME=/tmp/cw-test assert_eq "$(CLONE_WARS_HOME=/tmp/cw-test cw_state_root)" "/tmp/cw-test" "override"
pass "override root"
```

- [ ] **Step 2: Run test, verify FAIL**

Run: `bash tests/test_state.sh`
Expected: FAIL — `cw_state_root: command not found` or sourcing error (`lib/state.sh` doesn't exist yet).

- [ ] **Step 3: Implement `cw_state_root`**

```bash
# lib/state.sh — $CLONE_WARS_HOME resolution and state-dir layout helpers.
# Sourced. All paths are absolute.

cw_state_root() {
  printf '%s\n' "${CLONE_WARS_HOME:-$HOME/.clone-wars}"
}
```

- [ ] **Step 4: Run test, verify PASS**

Run: `bash tests/test_state.sh`
Expected: two `PASS` lines, exit 0.

- [ ] **Step 5: Commit**

```bash
git add lib/state.sh tests/test_state.sh
git commit -m "feat(state): cw_state_root resolves \$CLONE_WARS_HOME with sane default"
```

---

## Task 5: `lib/state.sh` — `cw_state_ensure`

**Files:**
- Modify: `lib/state.sh`
- Modify: `tests/test_state.sh`

- [ ] **Step 1: Append the failing test**

Append to `tests/test_state.sh`:
```bash
# 3. cw_state_ensure creates root + standard subdirs and is idempotent.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
CLONE_WARS_HOME="$TMP/cw" cw_state_ensure
assert_file_exists "$TMP/cw" "root created"
assert_file_exists "$TMP/cw/state" "state subdir"
assert_file_exists "$TMP/cw/archive" "archive subdir"
# Idempotent: second call doesn't error.
CLONE_WARS_HOME="$TMP/cw" cw_state_ensure
pass "ensure idempotent"
```

- [ ] **Step 2: Run test, verify FAIL**

Run: `bash tests/test_state.sh`
Expected: FAIL — `cw_state_ensure: command not found`.

- [ ] **Step 3: Implement `cw_state_ensure`**

Append to `lib/state.sh`:
```bash
cw_state_ensure() {
  local root; root=$(cw_state_root)
  mkdir -p "$root/state" "$root/archive"
}
```

- [ ] **Step 4: Run test, verify PASS**

Run: `bash tests/test_state.sh`
Expected: three `PASS` lines, exit 0.

- [ ] **Step 5: Commit**

```bash
git add lib/state.sh tests/test_state.sh
git commit -m "feat(state): cw_state_ensure creates root + state/ + archive/ idempotently"
```

---

## Task 6: `lib/state.sh` — `cw_repo_hash`

Pure function defined now since it's load-bearing for state paths and trivial to test. Used by spawn/list in Plan B; defining it here keeps `lib/state.sh` complete for v0.0.1-pre1.

**Files:**
- Modify: `lib/state.sh`
- Modify: `tests/test_state.sh`

- [ ] **Step 1: Append the failing test**

Append to `tests/test_state.sh`:
```bash
# 4. cw_repo_hash is sha256 of realpath(pwd), 64 hex chars.
H=$(cw_repo_hash)
[[ "${#H}" -eq 64 ]] || { echo "FAIL: hash length ${#H}, want 64" >&2; exit 1; }
[[ "$H" =~ ^[0-9a-f]{64}$ ]] || { echo "FAIL: hash not hex: $H" >&2; exit 1; }
pass "repo_hash hex64"

# 5. Same cwd → same hash; different cwd → different hash.
H2=$(cw_repo_hash)
assert_eq "$H" "$H2" "stable across calls"
pass "repo_hash stable"

(cd "$TMP" && H3=$(cw_repo_hash); [[ "$H3" != "$H" ]]) || { echo "FAIL: different cwd produced same hash" >&2; exit 1; }
pass "repo_hash differs by cwd"
```

- [ ] **Step 2: Run test, verify FAIL**

Run: `bash tests/test_state.sh`
Expected: FAIL — `cw_repo_hash: command not found`.

- [ ] **Step 3: Implement `cw_repo_hash` (handle macOS + Linux sha256)**

Append to `lib/state.sh`:
```bash
cw_repo_hash() {
  local p
  p=$(realpath "$PWD" 2>/dev/null || readlink -f "$PWD" 2>/dev/null || printf '%s' "$PWD")
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$p" | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$p" | shasum -a 256 | awk '{print $1}'
  else
    echo "cw_repo_hash: no sha256 tool (sha256sum or shasum) found" >&2
    return 1
  fi
}
```

- [ ] **Step 4: Run test, verify PASS**

Run: `bash tests/test_state.sh`
Expected: six `PASS` lines, exit 0.

- [ ] **Step 5: Commit**

```bash
git add lib/state.sh tests/test_state.sh
git commit -m "feat(state): cw_repo_hash via realpath + sha256 (cross-platform)"
```

---

## Task 7: `lib/deps.sh` — `cw_have_cmd`

**Files:**
- Create: `lib/deps.sh`
- Test: `tests/test_deps.sh`

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# tests/test_deps.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/deps.sh

# 1. cw_have_cmd returns 0 for sh and 1 for definitely-missing.
cw_have_cmd sh || { echo "FAIL: sh should be present" >&2; exit 1; }
pass "have sh"

! cw_have_cmd cw-definitely-not-a-binary-2026 || { echo "FAIL: bogus binary should be absent" >&2; exit 1; }
pass "missing bogus"
```

- [ ] **Step 2: Run test, verify FAIL**

Run: `bash tests/test_deps.sh`
Expected: FAIL — `lib/deps.sh: No such file or directory`.

- [ ] **Step 3: Implement `cw_have_cmd`**

```bash
# lib/deps.sh — binary presence + version + tmux env checks.
# Sourced. Returns 0/1 — does not exit; callers decide how to react.

cw_have_cmd() {
  command -v "$1" >/dev/null 2>&1
}
```

- [ ] **Step 4: Run test, verify PASS**

Run: `bash tests/test_deps.sh`
Expected: two `PASS` lines, exit 0.

- [ ] **Step 5: Commit**

```bash
git add lib/deps.sh tests/test_deps.sh
git commit -m "feat(deps): cw_have_cmd binary-presence check"
```

---

## Task 8: `lib/deps.sh` — `cw_check_tmux_version`

**Files:**
- Modify: `lib/deps.sh`
- Modify: `tests/test_deps.sh`

- [ ] **Step 1: Append the failing test**

Append to `tests/test_deps.sh`:
```bash
# 2. cw_tmux_version_ok requires tmux ≥ 3.0.
# We mock by overriding cw_tmux_version_string in subshells.

assert_tmux_ok() {
  local version="$1" expected_code="$2"
  ( cw_tmux_version_string() { printf '%s\n' "$version"; }
    cw_tmux_version_ok
    code=$?
    [[ "$code" -eq "$expected_code" ]] || { echo "FAIL: tmux=$version expected $expected_code got $code" >&2; exit 1; }
  )
}

assert_tmux_ok "tmux 3.0a"  0
assert_tmux_ok "tmux 3.4"   0
assert_tmux_ok "tmux 4.1"   0
assert_tmux_ok "tmux 2.9a"  1
assert_tmux_ok "tmux 1.8"   1
pass "tmux version gate ≥ 3.0"
```

- [ ] **Step 2: Run test, verify FAIL**

Run: `bash tests/test_deps.sh`
Expected: FAIL — `cw_tmux_version_ok: command not found`.

- [ ] **Step 3: Implement version gate**

Append to `lib/deps.sh`:
```bash
# Print the raw `tmux -V` line, e.g. "tmux 3.4". Overridable in tests.
cw_tmux_version_string() {
  cw_have_cmd tmux || return 1
  tmux -V 2>/dev/null
}

# Return 0 iff tmux ≥ 3.0.
cw_tmux_version_ok() {
  local v major
  v=$(cw_tmux_version_string) || return 1
  # Strip "tmux " prefix and any non-numeric suffix on the major.
  v=${v#tmux }
  major=${v%%.*}
  # Drop trailing letters from major (e.g. "3a" → "3"); but typical is "3.0a" so major is "3".
  major=${major//[^0-9]/}
  [[ -n "$major" && "$major" -ge 3 ]]
}
```

- [ ] **Step 4: Run test, verify PASS**

Run: `bash tests/test_deps.sh`
Expected: three `PASS` lines, exit 0.

- [ ] **Step 5: Commit**

```bash
git add lib/deps.sh tests/test_deps.sh
git commit -m "feat(deps): cw_tmux_version_ok gates on tmux >= 3.0"
```

---

## Task 9: `lib/deps.sh` — `cw_in_tmux_session`

**Files:**
- Modify: `lib/deps.sh`
- Modify: `tests/test_deps.sh`

- [ ] **Step 1: Append the failing test**

Append to `tests/test_deps.sh`:
```bash
# 3. cw_in_tmux_session is 0 iff $TMUX is set non-empty.
( unset TMUX; ! cw_in_tmux_session ) || { echo "FAIL: expected fail when TMUX unset" >&2; exit 1; }
pass "not in tmux"

( TMUX=/tmp/x,123,0 cw_in_tmux_session ) || { echo "FAIL: expected ok when TMUX set" >&2; exit 1; }
pass "in tmux"
```

- [ ] **Step 2: Run test, verify FAIL**

Run: `bash tests/test_deps.sh`
Expected: FAIL — `cw_in_tmux_session: command not found`.

- [ ] **Step 3: Implement**

Append to `lib/deps.sh`:
```bash
cw_in_tmux_session() {
  [[ -n "${TMUX:-}" ]]
}
```

- [ ] **Step 4: Run test, verify PASS**

Run: `bash tests/test_deps.sh`
Expected: five `PASS` lines, exit 0.

- [ ] **Step 5: Commit**

```bash
git add lib/deps.sh tests/test_deps.sh
git commit -m "feat(deps): cw_in_tmux_session checks \$TMUX"
```

---

## Task 10: `lib/contracts.sh` — locate the contracts file

**Files:**
- Create: `lib/contracts.sh`
- Test: `tests/test_contracts.sh`

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# tests/test_contracts.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/state.sh
source ../lib/contracts.sh

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

# 1. cw_contracts_path returns $CLONE_WARS_HOME/contracts.yaml regardless of file existence.
assert_eq "$(cw_contracts_path)" "$TMP/cw/contracts.yaml" "contracts path"
pass "contracts path"

# 2. cw_contracts_exists is non-zero before file is created, zero after.
! cw_contracts_exists || { echo "FAIL: should not exist yet" >&2; exit 1; }
mkdir -p "$TMP/cw"; touch "$TMP/cw/contracts.yaml"
cw_contracts_exists || { echo "FAIL: should exist after touch" >&2; exit 1; }
pass "contracts existence check"
```

- [ ] **Step 2: Run test, verify FAIL**

Run: `bash tests/test_contracts.sh`
Expected: FAIL — `lib/contracts.sh: No such file or directory`.

- [ ] **Step 3: Implement**

```bash
# lib/contracts.sh — read provider rows from $CLONE_WARS_HOME/contracts.yaml.
# Parser is awk/grep — no yq dependency. Only structures medic and Plan B need.
# Sourced. Depends on lib/state.sh.

cw_contracts_path() {
  printf '%s/contracts.yaml\n' "$(cw_state_root)"
}

cw_contracts_exists() {
  [[ -f "$(cw_contracts_path)" ]]
}
```

- [ ] **Step 4: Run test, verify PASS**

Run: `bash tests/test_contracts.sh`
Expected: two `PASS` lines, exit 0.

- [ ] **Step 5: Commit**

```bash
git add lib/contracts.sh tests/test_contracts.sh
git commit -m "feat(contracts): cw_contracts_path + cw_contracts_exists"
```

---

## Task 11: `lib/contracts.sh` — `cw_contracts_providers` + `cw_contract_binary`

Minimal yaml parsing — just enough for medic to enumerate providers and look up each one's `binary:` field. Full mode-resolution is deferred to Plan B.

**Files:**
- Modify: `lib/contracts.sh`
- Modify: `tests/test_contracts.sh`

- [ ] **Step 1: Append the failing test**

Append to `tests/test_contracts.sh`:
```bash
# 3. Provider enumeration + binary lookup against a fixture.
cat > "$TMP/cw/contracts.yaml" <<'YAML'
codex:
  binary: codex
  modes:
    full:      [--dangerously-bypass-approvals-and-sandbox]
    read-only: [--sandbox, read-only]
  default_mode: full
  ready_timeout_s: 30

gemini:
  binary: gemini
  modes:
    full:      [--approval-mode, yolo]
    read-only: [--approval-mode, default]
  default_mode: full
  ready_timeout_s: 30

claude:
  binary: claude
  modes:
    full:      [--dangerously-skip-permissions]
    read-only: []
  default_mode: full
  ready_timeout_s: 60
YAML

PROVS=$(cw_contracts_providers | tr '\n' ' ' | sed 's/ $//')
assert_eq "$PROVS" "codex gemini claude" "provider list in file order"
pass "providers enumerated"

assert_eq "$(cw_contract_binary codex)"  "codex"  "codex binary"
assert_eq "$(cw_contract_binary gemini)" "gemini" "gemini binary"
assert_eq "$(cw_contract_binary claude)" "claude" "claude binary"
pass "binary lookup"

# 4. Missing provider returns non-zero with empty stdout.
out=$(cw_contract_binary nope 2>/dev/null) || rc=$?
assert_eq "$out" "" "empty for missing"
[[ "${rc:-0}" -ne 0 ]] || { echo "FAIL: expected non-zero rc for missing provider" >&2; exit 1; }
pass "missing provider returns non-zero"
```

- [ ] **Step 2: Run test, verify FAIL**

Run: `bash tests/test_contracts.sh`
Expected: FAIL — `cw_contracts_providers: command not found`.

- [ ] **Step 3: Implement**

Append to `lib/contracts.sh`:
```bash
# List provider top-level keys in file order. A provider key is a non-indented
# line whose first non-whitespace token ends in a colon and isn't a comment.
cw_contracts_providers() {
  local path; path=$(cw_contracts_path)
  [[ -f "$path" ]] || return 1
  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/  { next }
    /^[A-Za-z][A-Za-z0-9_-]*:[[:space:]]*$/ {
      sub(/:[[:space:]]*$/, "", $0)
      print
    }
  ' "$path"
}

# Print the `binary:` field of <provider>, or empty + non-zero exit if not found.
cw_contract_binary() {
  local provider="$1" path bin
  path=$(cw_contracts_path)
  [[ -f "$path" ]] || return 1
  bin=$(awk -v p="$provider" '
    BEGIN { in_block = 0 }
    /^[A-Za-z][A-Za-z0-9_-]*:[[:space:]]*$/ {
      key = $0; sub(/:[[:space:]]*$/, "", key)
      in_block = (key == p)
      next
    }
    in_block && /^[[:space:]]+binary:[[:space:]]*/ {
      val = $0
      sub(/^[[:space:]]+binary:[[:space:]]*/, "", val)
      gsub(/^[ \t]+|[ \t\r]+$/, "", val)
      print val
      exit
    }
  ' "$path")
  [[ -n "$bin" ]] || return 1
  printf '%s\n' "$bin"
}
```

- [ ] **Step 4: Run test, verify PASS**

Run: `bash tests/test_contracts.sh`
Expected: five `PASS` lines, exit 0.

- [ ] **Step 5: Commit**

```bash
git add lib/contracts.sh tests/test_contracts.sh
git commit -m "feat(contracts): enumerate providers + lookup binary via awk"
```

---

## Task 12: `config/contracts.yaml` defaults

**Files:**
- Create: `config/contracts.yaml`

- [ ] **Step 1: Create the file**

```yaml
# config/contracts.yaml — shipped defaults; copied to $CLONE_WARS_HOME on first medic run.
# Each provider row has:
#   binary:           CLI executable name (must be on PATH)
#   modes:            map of mode-name -> args list passed to the CLI
#                     two modes are reserved: 'full' (yolo/bypass) and 'read-only'
#   default_mode:     mode used by /clone-wars:spawn when --mode is omitted
#   ready_timeout_s:  how long /clone-wars:spawn waits for the trooper's "ready"
#                     event in outbox.jsonl before giving up
#   identity_injection: how the conductor delivers identity.md to the pane
#                       (send-keys-paste = tmux load-buffer + paste-buffer + Enter)
#
# Modes that have no native equivalent on a given provider are shipped as best-effort
# (claude has no read-only sandbox today; gemini approximates via --approval-mode default).

codex:
  binary: codex
  modes:
    full:      [--dangerously-bypass-approvals-and-sandbox]
    read-only: [--sandbox, read-only]
  default_mode: full
  ready_timeout_s: 30
  identity_injection: send-keys-paste

gemini:
  binary: gemini
  modes:
    full:      [--approval-mode, yolo]
    read-only: [--approval-mode, default]   # best-effort; gemini has no true read-only
  default_mode: full
  ready_timeout_s: 30
  identity_injection: send-keys-paste

claude:
  binary: claude
  modes:
    full:      [--dangerously-skip-permissions]
    read-only: []                            # best-effort; claude TUI has no read-only flag
  default_mode: full
  ready_timeout_s: 60
  identity_injection: send-keys-paste
```

- [ ] **Step 2: Verify it's parseable by `lib/contracts.sh`**

Run:
```bash
TMP=$(mktemp -d); export CLONE_WARS_HOME="$TMP/cw"; mkdir -p "$TMP/cw"
cp config/contracts.yaml "$TMP/cw/contracts.yaml"
bash -c 'source lib/state.sh; source lib/contracts.sh; cw_contracts_providers'
```
Expected: three lines: `codex`, `gemini`, `claude`.

- [ ] **Step 3: Commit**

```bash
git add config/contracts.yaml
git commit -m "feat(config): ship default contracts.yaml with three providers + modes"
```

---

## Task 13: `config/commanders.yaml` defaults

**Files:**
- Create: `config/commanders.yaml`

- [ ] **Step 1: Create the file**

```yaml
# config/commanders.yaml — curated clone-trooper name pool; user-editable.
# /clone-wars:spawn random codex <topic> "..." picks an unused commander from this pool.
# Names are matched case-insensitively; conventionally lowercase at use site.
commanders:
  - rex
  - cody
  - wolffe
  - bly
  - fox
  - gree
  - ponds
  - bacara
  - neyo
  - doom
  - faie
  - hunter
  - wrecker
  - tech
  - crosshair
  - echo
  - fives
  - jesse
  - kix
  - tup
  - dogma
  - hardcase
  - thorn
  - thire
  - stone
  - bow
  - keeli
  - trauma
  - blackout
  - colt
  - havoc
  - vill
  - deviss
```

- [ ] **Step 2: Smoke-check YAML**

Run: `python3 -c 'import yaml,sys; yaml.safe_load(open("config/commanders.yaml")); print("OK")'`
Expected: `OK`. (Falls back gracefully if `pyyaml` isn't installed — skip step if so.)

- [ ] **Step 3: Commit**

```bash
git add config/commanders.yaml
git commit -m "feat(config): ship default commanders.yaml pool (~33 names)"
```

---

## Task 14: `config/config.yaml` defaults

**Files:**
- Create: `config/config.yaml`

- [ ] **Step 1: Create the file**

```yaml
# config/config.yaml — global Clone Wars defaults; user-editable.
# Path: $CLONE_WARS_HOME/config.yaml (default ~/.clone-wars/config.yaml).

split:
  primary:   right          # split direction for the first clone in a topic (right|left|up|down)
  secondary: down           # split direction for subsequent clones in the same topic
  layout:    main-vertical  # reapplied after 3+ panes (main-vertical|even-horizontal|even-vertical|tiled)

ready_timeout_default_s:   30   # spawn-time wait for {"event":"ready"} in outbox.jsonl
collect_timeout_default_s: 600  # collect-time wait for {"event":"done"|"error"}
```

- [ ] **Step 2: Commit**

```bash
git add config/config.yaml
git commit -m "feat(config): ship default config.yaml (split + layout + timeouts)"
```

---

## Task 15: `config/identity-template.md` defaults

**Files:**
- Create: `config/identity-template.md`

- [ ] **Step 1: Create the file** (verbatim from `docs/DESIGN.md` §Identity prompt template, with `{{vars}}` preserved for spawn-time substitution in Plan B)

```markdown
You are **{{commander}}**, a {{model}}-class clone trooper assigned to operation **{{topic}}**.

Your inbox: `{{state_dir}}/inbox.md`
Your outbox: `{{state_dir}}/outbox.jsonl`
Your status: `{{state_dir}}/status.json`

The conductor (your commanding officer in Claude Code) will write inbox.md and nudge you with
its path. **Do not begin until the inbox ends with `END_OF_INSTRUCTION`** — that sentinel
guarantees the message is complete and you're not reading mid-write.

Report progress via JSONL events appended to outbox.jsonl. Required event types:
- `{"event": "ack", "task_summary": "...", "ts": "<iso>"}` — acknowledge new inbox
- `{"event": "progress", "note": "...", "ts": "<iso>"}` — periodic updates
- `{"event": "done", "summary": "...", "artifacts": [...], "ts": "<iso>"}` — task complete
- `{"event": "error", "message": "...", "fatal": <bool>, "ts": "<iso>"}` — failure

After every event, update status.json with `{"state": "<state>", "updated": "<iso>", "last_event": "<event>"}`.

Stay in your pane between assignments — do **not** exit. After `done` or `error`, set status to
`idle` and wait for the next inbox.

When you receive your first inbox, output `{"event": "ack", ...}` first to confirm receipt before
beginning work.

*Roger that, Commander.*
```

- [ ] **Step 2: Commit**

```bash
git add config/identity-template.md
git commit -m "feat(config): ship default identity-template.md"
```

---

## Task 16a: `bin/medic.sh` — real executable script

The actual logic for `/clone-wars:medic` lives here as a real shell script. The slash-command
file in Task 16b is a thin instruction document that directs Claude to run this script.

**Files:**
- Create: `bin/medic.sh`
- Test: `tests/test_medic.sh`

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# tests/test_medic.sh — runs bin/medic.sh in a controlled $CLONE_WARS_HOME and inspects output.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

# Seed the state dir with shipped config so medic finds the files it needs.
mkdir -p "$CLONE_WARS_HOME"
cp ../config/contracts.yaml         "$CLONE_WARS_HOME/contracts.yaml"
cp ../config/commanders.yaml        "$CLONE_WARS_HOME/commanders.yaml"
cp ../config/identity-template.md   "$CLONE_WARS_HOME/identity-template.md"

# Run medic. Capture combined stdout+stderr; the exit code reflects medic's verdict.
out=$(bash ../bin/medic.sh 2>&1) || rc=$?
echo "--- medic output ---"
echo "$out"
echo "--- end ---"

# Test 1: tmux check appears in output.
assert_contains "$out" "tmux" "tmux check appears in output"
pass "tmux check present"

# Test 2: state-dir line shows the resolved CLONE_WARS_HOME.
assert_contains "$out" "$CLONE_WARS_HOME" "resolved state dir printed"
pass "state dir printed"

# Test 3: contracts.yaml line is mentioned.
assert_contains "$out" "contracts.yaml" "contracts.yaml line"
pass "contracts.yaml present"

# Test 4: at least one provider name appears.
[[ "$out" == *codex* || "$out" == *gemini* || "$out" == *claude* ]] \
  || { echo "FAIL: no provider mentioned" >&2; exit 1; }
pass "providers enumerated"

# Test 5: a Verdict line is present with either OK or FAIL.
[[ "$out" == *"Verdict:"* ]] || { echo "FAIL: no Verdict line" >&2; exit 1; }
pass "verdict line present"
```

- [ ] **Step 2: Run test, verify FAIL**

Run: `bash tests/test_medic.sh`
Expected: FAIL — `bin/medic.sh: No such file or directory`.

- [ ] **Step 3: Write `bin/medic.sh`**

```bash
#!/usr/bin/env bash
# bin/medic.sh — health check for Clone Wars.
# Invoked by /clone-wars:medic (commands/medic.md directs Claude to run this script).
# Prints a status table and exits 0 (OK) or 1 (FAIL).
set -uo pipefail

# Resolve the plugin root. When invoked by Claude Code, $CLAUDE_PLUGIN_ROOT points
# at the installed plugin. When run directly as bin/medic.sh, $BASH_SOURCE[0] is set,
# so we walk one level up from bin/.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deps.sh"
source "$PLUGIN_ROOT/lib/contracts.sh"

state_root=$(cw_state_root)
fail=0
warn=0
providers_ok=0
providers_total=0

echo
echo "Clone Wars — medic"
echo "  state root: $state_root"
echo

# 1. tmux presence + version
if cw_have_cmd tmux; then
  if cw_tmux_version_ok; then
    log_ok "tmux: $(cw_tmux_version_string)"
  else
    log_error "tmux: $(cw_tmux_version_string) — clone-wars requires >= 3.0"
    fail=1
  fi
else
  log_error "tmux: not on PATH (install: https://github.com/tmux/tmux)"
  fail=1
fi

# 2. inside a tmux session?
if cw_in_tmux_session; then
  log_ok "tmux session: \$TMUX is set"
else
  log_warn "tmux session: \$TMUX not set — \`tmux new -s clone-wars\` before spawning"
  warn=1
fi

# 3. state dir resolves and is writable
if cw_state_ensure 2>/dev/null && [[ -w "$state_root" ]]; then
  log_ok "state dir: $state_root (writable)"
else
  log_error "state dir: $state_root cannot be created or is not writable"
  fail=1
fi

# 4. config files present in state root (copy shipped defaults if missing)
for f in contracts.yaml commanders.yaml identity-template.md; do
  if [[ -f "$state_root/$f" ]]; then
    log_ok "config: $f"
  else
    if [[ -f "$PLUGIN_ROOT/config/$f" ]]; then
      if cp "$PLUGIN_ROOT/config/$f" "$state_root/$f" 2>/dev/null; then
        log_ok "config: $f (copied default into state dir)"
      else
        log_error "config: $f missing; copy from plugin defaults failed"
        fail=1
      fi
    else
      log_error "config: $f not in state dir and not shipped at $PLUGIN_ROOT/config/$f"
      fail=1
    fi
  fi
done

# 5. providers in contracts.yaml — WARN on missing, FAIL only when zero are healthy
echo
echo "Providers:"
if cw_contracts_exists; then
  while IFS= read -r prov; do
    [[ -z "$prov" ]] && continue
    providers_total=$((providers_total + 1))
    bin=$(cw_contract_binary "$prov" 2>/dev/null) || bin=""
    if [[ -z "$bin" ]]; then
      log_warn "  $prov: binary field missing in contracts.yaml"
      warn=1
      continue
    fi
    if cw_have_cmd "$bin"; then
      ver=$("$bin" --version 2>/dev/null | head -n1 || true)
      log_ok "  $prov ($bin): ${ver:-installed}"
      providers_ok=$((providers_ok + 1))
    else
      log_warn "  $prov ($bin): not on PATH — skip if you don't use this provider"
      warn=1
    fi
  done < <(cw_contracts_providers)
else
  log_error "contracts.yaml not found at $state_root/contracts.yaml"
  fail=1
fi

echo

# Verdict
if [[ "$fail" -ne 0 || "$providers_ok" -eq 0 ]]; then
  if [[ "$providers_ok" -eq 0 && "$providers_total" -gt 0 ]]; then
    log_error "no providers available; install at least one of: $(cw_contracts_providers | tr '\n' ' ')"
  fi
  echo "Verdict: FAIL — fix items above before spawning"
  exit 1
else
  echo "Verdict: OK — ready to spawn ($providers_ok/$providers_total providers available; $warn warnings)"
  exit 0
fi
```

- [ ] **Step 4: Make executable**

Run: `chmod +x bin/medic.sh`

- [ ] **Step 5: Run test, verify PASS**

Run: `bash tests/test_medic.sh`
Expected: medic output dump followed by five `PASS` lines, exit 0.

- [ ] **Step 6: Sanity-run against the live machine** (run from inside a tmux session for the relevant warn line)

Run:
```bash
CLONE_WARS_HOME=/tmp/cw-medic-smoke bash bin/medic.sh
```
Expected: a status table; verdict `OK — ready to spawn (N/M providers available; X warnings)`. Providers without a binary on PATH show WARN (not FAIL); verdict is OK iff at least one provider is healthy.

- [ ] **Step 7: Commit**

```bash
git add bin/medic.sh tests/test_medic.sh
git commit -m "feat(medic): bin/medic.sh — full health check with WARN-on-missing-provider"
```

---

## Task 16b: `commands/medic.md` — slash-command instruction document

The slash-command file is a thin markdown document that directs Claude to run `bin/medic.sh`
via the Bash tool and report the output. It is **not** itself a script.

**Files:**
- Create: `commands/medic.md`

- [ ] **Step 1: Write the command file**

```markdown
---
description: Health check for Clone Wars — verifies tmux, $CLONE_WARS_HOME, config files, and provider binaries
argument-hint: (no args)
allowed-tools: Bash
---

# /clone-wars:medic

Run the Clone Wars health check by invoking the medic script.

## Steps

1. Use the Bash tool to run:

   ```
   "${CLAUDE_PLUGIN_ROOT}/bin/medic.sh"
   ```

2. Show the script's output to the user verbatim — it is already formatted with status
   glyphs and a Verdict line.

3. If the verdict is `FAIL`, briefly summarize which checks failed and offer next steps:

   - **tmux missing or too old** → `apt install tmux` / `brew install tmux`; clone-wars
     requires tmux ≥ 3.0.
   - **`$TMUX` not set (warning)** → run `tmux new -s clone-wars` before spawning crews.
   - **state dir not writable** → check `$CLONE_WARS_HOME` (default `~/.clone-wars`); the
     parent directory must exist and be writable.
   - **config file missing** → reinstall the plugin: `/plugin install clone-wars@clone-wars`.
   - **all providers missing** → install at least one of `codex`, `gemini`, `claude`.

4. If the verdict is `OK`, no further action is needed; the user is ready to spawn troopers
   (once the runtime commands ship in v0.0.1 — until then, `/clone-wars:spawn` etc. print
   stub messages).
```

- [ ] **Step 2: Sanity check** (Claude reads this file at runtime; no automated test needed beyond visual inspection)

Run: `cat commands/medic.md`
Expected: the markdown above, with the frontmatter and four numbered steps.

- [ ] **Step 3: Commit**

```bash
git add commands/medic.md
git commit -m "feat(medic): commands/medic.md — slash-command directive for /clone-wars:medic"
```

---

## Task 17a: `bin/spawn.sh` stub script

The runtime stub for `/clone-wars:spawn` lives as a real script. It echoes the args it
received, prints a "runtime pending tracer-bullet" message, and exits 0. The slash-command
file in Task 17b directs Claude to invoke this script.

**Files:**
- Create: `bin/spawn.sh`

- [ ] **Step 1: Write the stub script**

```bash
#!/usr/bin/env bash
# bin/spawn.sh — STUB for v0.0.1-pre1.
# Real implementation lands in v0.0.1 after the tracer-bullet validates tmux/IPC mechanics.
# This stub exists so the marketplace shell is complete (Phase 1 of the marketplace-prep spec).
set -uo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"

cat <<EOF
/clone-wars:spawn — args received: $*

This command is a stub in v0.0.1-pre1. The runtime (tmux split-window, send-keys
identity injection, outbox polling for the "ready" event) lands in v0.0.1 after
the tracer-bullet validates the underlying mechanics on this machine.

In the meantime:
  - Run /clone-wars:medic to verify your environment.
  - Read docs/DESIGN.md §Slash commands for the spec of how this will behave.
  - Track progress in CLAUDE.md status checklist.
EOF

log_warn "spawn is a stub in v0.0.1-pre1; nothing was launched"
exit 0
```

- [ ] **Step 2: Make executable**

Run: `chmod +x bin/spawn.sh`

- [ ] **Step 3: Sanity-run**

Run: `bash bin/spawn.sh rex codex auth-review --mode read-only "test"`
Expected: a multi-line message echoing the args, a `[WARN]` line, exit 0.

- [ ] **Step 4: Commit**

```bash
git add bin/spawn.sh
git commit -m "feat(spawn): bin/spawn.sh stub for v0.0.1-pre1 (runtime pending tracer-bullet)"
```

---

## Task 17b: `commands/spawn.md` slash-command directive

**Files:**
- Create: `commands/spawn.md`

- [ ] **Step 1: Write the command file**

```markdown
---
description: Spawn a clone trooper as a tmux pane (RUNTIME PENDING — see roadmap)
argument-hint: <commander> <model> <topic> [--mode full|read-only] [initial-prompt]
allowed-tools: Bash
---

# /clone-wars:spawn

Spawn a clone trooper as a tmux pane.

**Note:** in v0.0.1-pre1 this command is a stub. The runtime ships in v0.0.1 after the
tracer-bullet validates tmux + IPC mechanics. The spec is in `docs/DESIGN.md` §Slash
commands → `/clone-wars-spawn`.

## Steps

1. Use the Bash tool to run, passing through `$ARGUMENTS`:

   ```
   "${CLAUDE_PLUGIN_ROOT}/bin/spawn.sh" $ARGUMENTS
   ```

2. Show the script's output to the user verbatim. It explains that the runtime is pending
   and points to `/clone-wars:medic` and `docs/DESIGN.md`.

3. If the user asks why this isn't working yet, summarize: "Clone Wars v0.0.1-pre1 ships the
   marketplace shell + medic. The runtime commands (spawn/send/collect/list/teardown) become
   real in v0.0.1 once the tracer-bullet validates tmux/IPC mechanics — see CLAUDE.md status."
```

- [ ] **Step 2: Commit**

```bash
git add commands/spawn.md
git commit -m "feat(spawn): commands/spawn.md slash-command directive"
```

---

## Task 18a: `bin/send.sh`, `bin/collect.sh`, `bin/list.sh`, `bin/teardown.sh` stub scripts

All four runtime commands ship as the same stub shape as Task 17a. Each is a real
executable shell script that prints a message specific to its command and exits 0.

**Files:**
- Create: `bin/send.sh`
- Create: `bin/collect.sh`
- Create: `bin/list.sh`
- Create: `bin/teardown.sh`

- [ ] **Step 1: Write `bin/send.sh`**

```bash
#!/usr/bin/env bash
# bin/send.sh — STUB for v0.0.1-pre1.
set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
cat <<EOF
/clone-wars:send — args received: $*

This command is a stub in v0.0.1-pre1. The runtime (write inbox.md, append
END_OF_INSTRUCTION, nudge the pane via tmux send-keys) lands in v0.0.1 after the
tracer-bullet validates the IPC mechanics. See docs/DESIGN.md §/clone-wars-send.
EOF
log_warn "send is a stub in v0.0.1-pre1"
exit 0
```

- [ ] **Step 2: Write `bin/collect.sh`**

```bash
#!/usr/bin/env bash
# bin/collect.sh — STUB for v0.0.1-pre1.
set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
cat <<EOF
/clone-wars:collect — args received: $*

This command is a stub in v0.0.1-pre1. The runtime (tail outbox.jsonl until
{event:done|error}, print summary) lands in v0.0.1 after the tracer-bullet
validates the IPC mechanics. See docs/DESIGN.md §/clone-wars-collect.
EOF
log_warn "collect is a stub in v0.0.1-pre1"
exit 0
```

- [ ] **Step 3: Write `bin/list.sh`**

```bash
#!/usr/bin/env bash
# bin/list.sh — STUB for v0.0.1-pre1.
set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
cat <<EOF
/clone-wars:list — args received: $*

This command is a stub in v0.0.1-pre1. The runtime (read pane.json from each
trooper state dir, cross-check tmux list-panes, render a status table) lands in
v0.0.1 after the tracer-bullet validates the IPC mechanics. See docs/DESIGN.md
§/clone-wars-list.
EOF
log_warn "list is a stub in v0.0.1-pre1"
exit 0
```

- [ ] **Step 4: Write `bin/teardown.sh`**

```bash
#!/usr/bin/env bash
# bin/teardown.sh — STUB for v0.0.1-pre1.
set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
cat <<EOF
/clone-wars:teardown — args received: $*

This command is a stub in v0.0.1-pre1. The runtime (tmux kill-pane, mv state to
archive) lands in v0.0.1 after the tracer-bullet validates the IPC mechanics.
See docs/DESIGN.md §/clone-wars-teardown.
EOF
log_warn "teardown is a stub in v0.0.1-pre1"
exit 0
```

- [ ] **Step 5: Make all executable**

Run: `chmod +x bin/send.sh bin/collect.sh bin/list.sh bin/teardown.sh`

- [ ] **Step 6: Sanity-run all four stubs**

Run:
```bash
for c in send collect list teardown; do
  echo "=== $c ==="
  bash "bin/$c.sh" example-arg
done
```
Expected: four multi-line stub messages, each followed by a `[WARN]` line, all exiting 0.

- [ ] **Step 7: Commit**

```bash
git add bin/send.sh bin/collect.sh bin/list.sh bin/teardown.sh
git commit -m "feat(commands): bin/{send,collect,list,teardown}.sh stubs for v0.0.1-pre1"
```

---

## Task 18b: `commands/{send,collect,list,teardown}.md` slash-command directives

**Files:**
- Create: `commands/send.md`
- Create: `commands/collect.md`
- Create: `commands/list.md`
- Create: `commands/teardown.md`

Each file follows the same shape as Task 17b: frontmatter + a single Steps section directing
Claude to invoke `${CLAUDE_PLUGIN_ROOT}/bin/<verb>.sh $ARGUMENTS` and report output.

- [ ] **Step 1: Write `commands/send.md`**

```markdown
---
description: Write to a trooper's inbox and nudge it (RUNTIME PENDING — see roadmap)
argument-hint: <commander> <topic> <message-or-@file>
allowed-tools: Bash
---

# /clone-wars:send

Write a message to a trooper's inbox and nudge the pane to read it.

**Note:** in v0.0.1-pre1 this command is a stub. The runtime ships in v0.0.1 after the
tracer-bullet validates tmux + IPC mechanics. Spec: `docs/DESIGN.md` §`/clone-wars-send`.

## Steps

1. Use the Bash tool to run:

   ```
   "${CLAUDE_PLUGIN_ROOT}/bin/send.sh" $ARGUMENTS
   ```

2. Show the script's output to the user verbatim.
```

- [ ] **Step 2: Write `commands/collect.md`**

```markdown
---
description: Block until a trooper reports done/error in outbox.jsonl (RUNTIME PENDING)
argument-hint: <commander> <topic> [--timeout <sec>]
allowed-tools: Bash
---

# /clone-wars:collect

Block until a trooper reports `done` or `error`, then print the summary.

**Note:** in v0.0.1-pre1 this command is a stub. The runtime ships in v0.0.1 after the
tracer-bullet validates tmux + IPC mechanics. Spec: `docs/DESIGN.md` §`/clone-wars-collect`.

## Steps

1. Use the Bash tool to run:

   ```
   "${CLAUDE_PLUGIN_ROOT}/bin/collect.sh" $ARGUMENTS
   ```

2. Show the script's output to the user verbatim.
```

- [ ] **Step 3: Write `commands/list.md`**

```markdown
---
description: Show active troopers (RUNTIME PENDING — see roadmap)
argument-hint: [<topic>]
allowed-tools: Bash
---

# /clone-wars:list

Show the active troopers (panes + state). With no argument, lists every active trooper
across every topic; with `<topic>` arg, scopes to that topic.

**Note:** in v0.0.1-pre1 this command is a stub. The runtime ships in v0.0.1 after the
tracer-bullet validates tmux + IPC mechanics. Spec: `docs/DESIGN.md` §`/clone-wars-list`.

## Steps

1. Use the Bash tool to run:

   ```
   "${CLAUDE_PLUGIN_ROOT}/bin/list.sh" $ARGUMENTS
   ```

2. Show the script's output to the user verbatim.
```

- [ ] **Step 4: Write `commands/teardown.md`**

```markdown
---
description: Kill panes and archive state (RUNTIME PENDING — see roadmap)
argument-hint: [<commander>] [<topic>] [--all]
allowed-tools: Bash
---

# /clone-wars:teardown

Kill clone-trooper panes and archive their state.

**Note:** in v0.0.1-pre1 this command is a stub. The runtime ships in v0.0.1 after the
tracer-bullet validates tmux + IPC mechanics. Spec: `docs/DESIGN.md` §`/clone-wars-teardown`.

## Steps

1. Use the Bash tool to run:

   ```
   "${CLAUDE_PLUGIN_ROOT}/bin/teardown.sh" $ARGUMENTS
   ```

2. Show the script's output to the user verbatim.
```

- [ ] **Step 5: Commit**

```bash
git add commands/send.md commands/collect.md commands/list.md commands/teardown.md
git commit -m "feat(commands): commands/{send,collect,list,teardown}.md slash-command directives"
```

---

## Task 19: README rewrite

**Files:**
- Modify: `README.md` (replace contents)

- [ ] **Step 1: Replace `README.md`**

```markdown
# Clone Wars

> **v0.0.1-pre1 — marketplace shell.** Plugin is installable; `/clone-wars:medic`
> works; the runtime commands (`spawn`/`send`/`collect`/`list`/`teardown`) ship
> as stubs and become real in v0.0.1 once the tracer-bullet validates the
> underlying tmux + IPC mechanics. See `CLAUDE.md` status checklist.

Multi-model tmux pane orchestration for Claude Code.

A Claude Code session orchestrates a crew of model TUIs — `codex`, `gemini`,
`claude` — as real, attachable tmux panes. Communication is file-based (inbox /
outbox / status), so panes survive conductor crashes and you can `tmux attach`
to any pane to watch the model think live.

Each pane is a clone trooper: `<commander>-<model>-<topic>` (e.g.
`rex-codex-auth-review`).

## Install

```
/plugin marketplace add WingsOfPanda/clone-wars
/plugin install clone-wars@clone-wars
```

## Quickstart

```
/clone-wars:medic
```

The medic command verifies that `tmux ≥ 3.0`, `$CLONE_WARS_HOME`, your config
files, and at least one provider binary are all healthy. Run it first.

The remaining commands are documented below; they print a "pending v0.0.1"
message until the tracer-bullet validates the runtime mechanics.

```
/clone-wars:spawn rex codex auth-review "review src/auth/oauth.py for token-refresh edge cases"
/clone-wars:collect rex auth-review
/clone-wars:teardown auth-review
```

## Why

Claude Code already renders Claude teammates as attachable tmux panes (via
`Agent + TeamCreate`). But when a teammate needs a different model — Codex for
heavy implementation, Gemini for long-context — it shells out to a hidden
subprocess. You lose visibility, conversational continuity, and the ability to
intervene live.

Clone Wars is the missing primitive: a Claude Code conductor spawns and
orchestrates real, interactive `codex` / `gemini` / `claude` TUIs as tmux panes
you can attach to. File-based IPC replaces in-process `SendMessage`. The
Admiral pays for visibility everywhere — including the layer doing the actual
work.

## Commands

| Command | Status | What it does |
|---|---|---|
| `/clone-wars:medic` | live | Health-check: tmux, `$CLONE_WARS_HOME`, configs, provider binaries |
| `/clone-wars:spawn <commander> <model> <topic> [--mode <full|read-only>] [prompt]` | stub | Spawn a trooper in a new tmux pane (in v0.0.1) |
| `/clone-wars:send <commander> <topic> <msg-or-@file>` | stub | Write to a trooper's inbox and nudge (in v0.0.1) |
| `/clone-wars:collect <commander> <topic> [--timeout s]` | stub | Block until trooper reports done/error (in v0.0.1) |
| `/clone-wars:list [<topic>]` | stub | Show active troopers (in v0.0.1) |
| `/clone-wars:teardown [<commander>] [<topic>] [--all]` | stub | Kill panes and archive state (in v0.0.1) |

Full command spec: `docs/DESIGN.md` §Slash commands.

## Configuration

State, archive, and config all live under `$CLONE_WARS_HOME`, defaulting to
`~/.clone-wars/`. Override with:

```bash
export CLONE_WARS_HOME=/path/to/wherever
```

Three config files live there (medic copies the shipped defaults on first run):

- `contracts.yaml` — provider binaries, mode args (`full` / `read-only`),
  ready timeouts. Edit to add custom provider variants or adjust default modes.
- `commanders.yaml` — clone-trooper name pool used by `random` keyword on spawn.
- `identity-template.md` — system prompt every trooper receives at spawn time.
- `config.yaml` — split direction, layout, default timeouts.

### Permission allowlist (optional)

To suppress permission prompts on every spawn, paste this into
`~/.claude/settings.local.json`:

```jsonc
{
  "permissions": {
    "allow": [
      "Bash(tmux:*)",
      "Bash(command -v *)",
      "Read(~/.clone-wars/**)",
      "Write(~/.clone-wars/**)",
      "Edit(~/.clone-wars/**)"
    ]
  }
}
```

This is optional — without it the plugin still works, you just see prompts on
first use.

## Troubleshooting

Run `/clone-wars:medic` first. It diagnoses the most common failures and prints
an `install:` hint per failed check.

| Symptom | Likely cause | Fix |
|---|---|---|
| medic says `\$TMUX not set` | not inside a tmux session | `tmux new -s clone-wars` |
| medic says `tmux: 2.x — requires >= 3.0` | tmux too old | upgrade tmux |
| spawn (in v0.0.1) prompts for permission on every tmux call | permission allowlist not added | paste the snippet above into `settings.local.json` |
| provider WARN'd but you don't use it | nothing to fix | medic verdict is OK as long as ≥1 provider is healthy |

For everything else: `docs/DESIGN.md` §Failure modes.

## License

MIT — see `LICENSE`.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs(readme): rewrite for v0.0.1-pre1 marketplace shell"
```

---

## Task 20: Update `CLAUDE.md` and `docs/DESIGN.md` for the six-commands + mode-flag deltas

**Files:**
- Modify: `CLAUDE.md` — file tree under "Repository layout"; the "Five slash commands" line.
- Modify: `docs/DESIGN.md` — "Five commands" → "Six commands"; add `--mode` flag to `/clone-wars-spawn`; add `$CLONE_WARS_HOME` note; cross-reference the marketplace-prep spec.

- [ ] **Step 1: Update `CLAUDE.md`'s repository layout to add `bin/` and list six command files**

In the file tree under `## Repository layout`, change the `commands/` block from:
```
├── commands/                  ← slash command definitions
│   ├── clone-wars-spawn.md
│   ├── clone-wars-send.md
│   ├── clone-wars-collect.md
│   ├── clone-wars-list.md
│   └── clone-wars-teardown.md
```

to:
```
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
```

Also update the prose paragraph that follows the file tree (the bullet list under "Most of those
directories are empty right now...") to mention the bin/+commands/ split: slash commands are
markdown directives that invoke the matching `bin/*.sh` via the Bash tool — they are not
themselves bash scripts.

- [ ] **Step 2: Update `docs/DESIGN.md` §Slash commands header**

Find the line `Five commands. No more until proven necessary.` and replace with:
```
Six commands. Five orchestration verbs (spawn/send/collect/list/teardown) plus medic
(health check). No more until proven necessary.
```

- [ ] **Step 3: Update `docs/DESIGN.md` `/clone-wars-spawn` signature to include `--mode`**

Find:
```
### `/clone-wars-spawn <commander> <model> <topic> [initial-prompt]`
```

Replace with:
```
### `/clone-wars-spawn <commander> <model> <topic> [--mode <full|read-only>] [initial-prompt]`
```

And append this paragraph to that section (after the existing bullets, before the next `###`):
```

`--mode` selects which arg set the contract row maps to (`full` = yolo / bypass;
`read-only` = sandboxed). Omitting it falls through to the row's `default_mode`.
See the marketplace-prep design spec (`docs/superpowers/specs/2026-04-25-clone-wars-marketplace-prep-design.md` §4)
for the contracts.yaml shape and per-provider mappings.
```

- [ ] **Step 4: Add `$CLONE_WARS_HOME` note to `docs/DESIGN.md` §State directory layout**

At the top of the §State directory layout code block (line that says `~/.clone-wars/`), prepend a comment line:
```
$CLONE_WARS_HOME/   # default ~/.clone-wars; override via env var
```

- [ ] **Step 5: Add `medic` as a sixth section in `docs/DESIGN.md` §Slash commands**

Insert a new subsection after `### `/clone-wars-teardown ...`` (and before the next H2 §File-IPC protocol):

```
### `/clone-wars-medic`

Health check — verifies the host can run Clone Wars. Checks tmux presence + version
(>= 3.0), `$CLONE_WARS_HOME` writability, presence of `contracts.yaml` + `commanders.yaml`
+ `identity-template.md` in the state root, and per-provider binary availability.

Missing providers are WARN, not FAIL — the plugin is usable as long as at least one
provider in `contracts.yaml` is healthy. Verdict is `OK — ready to spawn (N/M providers
available)` or `FAIL — fix items above`. Exit code mirrors the verdict (0/1).

Spec: `docs/superpowers/specs/2026-04-25-clone-wars-marketplace-prep-design.md` §6.
```

- [ ] **Step 6: Sanity-check the diffs**

Run: `git diff CLAUDE.md docs/DESIGN.md`
Expected: only the surgical changes from steps 1–5; no other lines touched.

- [ ] **Step 7: Commit**

```bash
git add CLAUDE.md docs/DESIGN.md
git commit -m "docs: thread --mode flag, six-commands count, \$CLONE_WARS_HOME, and medic into DESIGN/CLAUDE"
```

---

## Task 21: Run the full test suite

**Files:** none (verification step).

- [ ] **Step 1: Run all tests**

Run: `bash tests/run.sh`
Expected: every `tests/test_*.sh` reports `ok`, exit 0.

- [ ] **Step 2: Smoke-run medic against the live machine**

Run: `CLONE_WARS_HOME=/tmp/cw-final-smoke bash bin/medic.sh`
Expected: a status table; verdict `OK — ready to spawn (N/M providers available; X warnings)` where N is the count of providers actually installed locally (e.g. codex+claude on this machine; gemini WARN'd).

- [ ] **Step 3: Verify the plugin manifest installs cleanly**

(This step depends on a marketplace add round-trip; defer to step 4 below if the local Claude Code session can't add a marketplace from a local path. Keep a record of which fallback you used.)

If supported locally:
```
/plugin marketplace add file:///home/liupan/CC/clone-wars
/plugin install clone-wars@clone-wars
/clone-wars:medic
```
Expected: medic emits the same output as Step 2 above.

If not supported locally: the round-trip is exercised post-tag against the github URL in Task 22.

---

## Task 22: Tag v0.0.1-pre1

**Files:** none (git operation).

- [ ] **Step 1: Confirm clean working tree**

Run: `git status`
Expected: `nothing to commit, working tree clean`. If anything is dirty, commit or stash before tagging.

- [ ] **Step 2: Tag**

Run:
```bash
git tag -a v0.0.1-pre1 -m "v0.0.1-pre1: marketplace shell — manifests + medic + config + README; runtime commands stubbed pending tracer-bullet"
```

- [ ] **Step 3: Push tag (and main)**

Run:
```bash
git push origin main
git push origin v0.0.1-pre1
```
Expected: github shows the tag at `https://github.com/WingsOfPanda/clone-wars/releases/tag/v0.0.1-pre1`.

- [ ] **Step 4: End-to-end install round-trip**

From a fresh Claude Code session (or a different machine):
```
/plugin marketplace add WingsOfPanda/clone-wars
/plugin install clone-wars@clone-wars
/clone-wars:medic
```
Expected: medic runs and emits its status table + verdict. Confirm `/clone-wars:spawn` (and the other stubs) print their pending-runtime messages and exit cleanly.

---

## Spec coverage check

| Spec section | Phase 1 acceptance criterion | Plan task |
|---|---|---|
| §1 marketplace target / install path | 1 | Tasks 1–2 |
| §2 plugin identifier + namespace | 1, 2 | Tasks 1, 16a/b, 17a/b, 18a/b |
| §3 plugin → host permissions | (README docs) | Task 19 |
| §4 trooper modes (contracts.yaml shape) | 3 | Task 12 |
| §5 `$CLONE_WARS_HOME` resolution | 6 | Tasks 4–5; exercised by Task 16a |
| §6 medic | 4 | Tasks 7–11, 16a, 16b |
| §7 versioning | 7 | Tasks 1–2 (`0.0.1-pre1` strings); Task 22 (tag) |
| §8 README structure | 5 | Task 19 |
| §9 plugin.json shape | 1 | Task 1 |
| §10 marketplace.json shape | 1 | Task 2 |
| §11 file deltas | (all) | Tasks 1–22 |
| §12 out of scope | n/a | (deferred to Plan B) |

Phase 2 acceptance criteria (8–10) are explicitly out of scope; they belong to Plan B
(post-tracer-bullet).

---

## Out of scope for this plan

Per the spec's §Out of scope and the Phase 1/2 split:

- The tracer-bullet (`tracer/tracer-bullet.sh`).
- Real implementations of `spawn`, `send`, `collect`, `list`, `teardown`.
- Mode-flag → CLI-args resolution at spawn time (just the contracts.yaml shape ships now).
- The eight inconsistencies flagged on initial read of `docs/DESIGN.md` (resolved in Plan B
  with tracer evidence).
- Submission to `claude-plugins-official` (gated on v1.0).
- A README screencast/asciinema (gated on v0.1.0).
- A standalone `package.json` (no Node runtime; revisit if marketplace tooling demands it).
- Any `lib/tmux.sh` / `lib/ipc.sh` / `lib/commanders.sh` (Plan B introduces these alongside the
  runtime commands; keeping them out of Plan A keeps the surface tight and the lib helpers
  shipped here have a single, demonstrable consumer — medic — rather than dead code).
