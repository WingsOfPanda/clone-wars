# v0.13.0 Opencode Trooper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `opencode` + DeepSeek V4 Pro as the 4th Clone Wars trooper provider, validated by tracer-bullet and medic preflight, shipped across two stacked PRs.

**Architecture:** PR1 ships pure validation infrastructure (tracer-bullet + medic preflight helper) without touching `contracts.yaml` — discovers and pins the load-bearing TUI mechanics (paste-buffer keymap, ANSI bleed in `outbox.jsonl`, DeepSeek V4 Pro's JSONL event discipline). PR2 ships the contracts row, `--provider` deploy flag, `CLAUDE.md` scope amendment, version bump, and dogfood gate using PR1's measured timeouts.

**Tech Stack:** bash 4.2+, tmux 3.0+, opencode 1.14.39 + DeepSeek V4 Pro (`deepseek/deepseek-v4-pro`), file-based IPC under `~/.clone-wars/`, tests via `tests/run.sh` + `tests/lib/assert.sh`.

**Spec:** `docs/superpowers/specs/2026-05-06-opencode-trooper-design.md` (PR #55).

**Branch parentage:**
- This plan: `docs/v0.13.0-opencode-trooper-plan` (off `docs/v0.13.0-opencode-trooper-spec`)
- PR1 implementation: `feat/v0.13.0-opencode-tracer` (off `main` once spec + plan merge)
- PR2 implementation: `feat/v0.13.0-opencode-contracts` (off `main` once PR1 merges)

---

## Reconnaissance: opencode auto-approve mechanism (already done)

Discovered during plan authoring (curling `https://opencode.ai/config.json` schema):

- **Permission key:** `"permission"` at top-level (or nested under `mode.<mode>.permission`).
- **Values:** `"ask"` | `"allow"` | `"deny"` (string), OR an object with per-tool keys (`bash`, `edit`, `read`, `glob`, `grep`, `list`, `task`, `external_directory`, `todowrite`, `question`, `webfetch`).
- **Default:** `"ask"` (opencode default; pauses TUI for approval prompts).
- **Auto-approve config (simplest):** `{"permission": "allow"}` at top of `opencode.json`.
- **Config locations:**
  - Project-local: `<cwd>/opencode.json` — overrides user-global
  - User-global: `~/.config/opencode/opencode.json`

Medic preflight will detect the **top-level string form** (`"permission": "allow"`) only. Object form gets a "medic can't introspect per-tool permission objects; verify manually" warning. This is a deliberate simplification for v0.13.0 — promotion to full object validation deferred.

---

## File Structure

### PR1 — validation infrastructure

| File | Status | Purpose |
|---|---|---|
| `tracer/tracer-bullet-opencode.sh` | Create | End-to-end validation of opencode launch + paste-buffer + ready/done events with DeepSeek V4 Pro. 3 clean runs = pass. |
| `lib/opencode_preflight.sh` | Create | Testable helpers: `cw_opencode_config_path()` and `cw_opencode_permission_check()`. Sourced by medic.sh and the test fixture. |
| `bin/medic.sh` | Modify (~10 lines, after providers loop ~line 184) | Source `lib/opencode_preflight.sh`, call `cw_opencode_permission_check` when `opencode` is on PATH; emit WARN line if not allow. Verdict-neutral. |
| `tests/test_medic_opencode_preflight.sh` | Create | Source `lib/opencode_preflight.sh`; assert behavior across 4 config states (no config, `ask`, `allow`, object). |

### PR2 — shipping bits

| File | Status | Purpose |
|---|---|---|
| `config/contracts.yaml` | Modify (add row after `claude:` block) | opencode contract row with PR1-measured `ready_timeout_s` + `bootstrap_sleep_s`. |
| `tests/test_contracts_opencode.sh` | Create | Assert `cw_contract_*` helpers return expected values for the new row. |
| `bin/deploy-init.sh` | Modify (~10 lines in argv loop, lines 24-38) | Accept `--provider <name>`; pass through to `cw_deploy_detect_provider`. |
| `lib/deploy.sh` | Modify (`cw_deploy_detect_provider` early-return) | Honor optional 2nd arg as override. |
| `tests/test_deploy_provider_flag.sh` | Create | Assert override beats auto-detect. |
| `CLAUDE.md` | Modify (out-of-scope list + Status section) | Closed set 3→4 with carve-out justification; v0.13.0 status entries. |
| `docs/DESIGN.md` | Modify (provider table) | Add opencode row. |
| `.claude-plugin/plugin.json` | Modify | Version `0.12.2` → `0.13.0`. |
| `.claude-plugin/marketplace.json` | Modify | Version `0.12.2` → `0.13.0` (×2 occurrences: `plugins[0].version` + top-level `version`). |

---

# Phase 1 — PR1: tracer-bullet + medic preflight

## Task 1: Set up PR1 branch

**Files:** none yet (branch operation only)

- [ ] **Step 1.1: Verify spec + plan are merged to main, then branch**

```bash
git checkout main
git pull origin main
git log --oneline -3
# Expected: top commit includes the merged plan PR (and spec PR)
git checkout -b feat/v0.13.0-opencode-tracer
git status --short
# Expected: empty (clean tree)
```

If spec/plan PRs aren't merged yet: branch off `docs/v0.13.0-opencode-trooper-plan` instead and rebase onto main after the merge.

---

## Task 2: Tracer-bullet for opencode

**Files:**
- Create: `tracer/tracer-bullet-opencode.sh`

The opencode tracer mirrors `tracer/tracer-bullet.sh` but launches `opencode -m deepseek/deepseek-v4-pro` and times the cold-start so PR2 can pin the contracts.yaml values.

- [ ] **Step 2.1: Copy the codex tracer as starting scaffold**

```bash
cp tracer/tracer-bullet.sh tracer/tracer-bullet-opencode.sh
```

- [ ] **Step 2.2: Update header + provider configuration**

Edit `tracer/tracer-bullet-opencode.sh`. Replace the configuration block (lines ~17–24) with:

```bash
COMMANDER="rex"
MODEL="opencode"
TOPIC="tracer-opencode"

TASK_INPUT_FILE="/tmp/clone-wars-tracer-opencode-input.md"
READY_TIMEOUT_S=120   # generous; calibrate down via measurements below
DONE_TIMEOUT_S=180
BOOTSTRAP_SLEEP_S=15  # initial guess; calibrate down via measurements below
```

Update the file's docstring (top comment block) to describe opencode + DeepSeek V4 Pro. Replace the `bash tracer/tracer-bullet.sh` example in the docstring with `bash tracer/tracer-bullet-opencode.sh`.

- [ ] **Step 2.3: Replace the codex precondition with opencode**

Find the precondition line:
```bash
cw_have_cmd codex  || { log_error "codex binary not on PATH"; exit 1; }
```

Replace with:
```bash
cw_have_cmd opencode || { log_error "opencode binary not on PATH"; exit 1; }
```

- [ ] **Step 2.4: Replace the launch line**

Find the `tmux split-window -P -F` line (~line 117):
```bash
PANE_ID=$(tmux split-window -P -F '#{pane_id}' -h -c "$PLUGIN_ROOT" "codex --dangerously-bypass-approvals-and-sandbox")
```

Replace with:
```bash
PANE_ID=$(tmux split-window -P -F '#{pane_id}' -h -c "$PLUGIN_ROOT" "opencode -m deepseek/deepseek-v4-pro")
```

- [ ] **Step 2.5: Replace the codex-bootstrap sleep line with the variable**

Find the codex-specific bootstrap sleep (~line 132):
```bash
log_info "sleeping 8s for codex bootstrap"
sleep 8
```

Replace with:
```bash
log_info "sleeping ${BOOTSTRAP_SLEEP_S}s for opencode bootstrap"
sleep "$BOOTSTRAP_SLEEP_S"
```

- [ ] **Step 2.6: Make the script executable**

```bash
chmod +x tracer/tracer-bullet-opencode.sh
```

- [ ] **Step 2.7: First run — discover surprises**

```bash
# Must be inside a tmux session.
tmux info >/dev/null 2>&1 || { echo "Not in tmux; run 'tmux new -s opencode-tracer' first" >&2; exit 1; }
bash tracer/tracer-bullet-opencode.sh
```

Expected output ends with `Tracer Bullet — SUCCESS` and shows `Ready in: <N>s` and `Done in: <M>s`. Watch the opencode pane in tmux during the run.

If FAIL: read stderr + the captured pane content. Most likely surprises:
- **Identity injection didn't land** — the `tmux send-keys -t "$PANE_ID" -l` line may need replacing with `tmux load-buffer + paste-buffer`. Diagnostic: tmux capture-pane output shows a partial or garbled "Read $identity" line. Fix: replace the inject block with:
  ```bash
  tmux load-buffer - <<<"Read $identity and follow its instructions exactly."
  tmux paste-buffer -t "$PANE_ID"
  sleep 0.3
  tmux send-keys -t "$PANE_ID" Enter
  ```
- **Cold-start timeout** — opencode finished bootstrap after `READY_TIMEOUT_S`. Bump `BOOTSTRAP_SLEEP_S` and retry. Record final value in step 2.10.
- **DeepSeek V4 Pro emitted prose instead of JSONL** — the model didn't follow identity-template's safe-emission patterns. Fix: append a stronger model-specific addendum to the tracer's identity append-block (lines ~96–112) explicitly demonstrating Pattern A (`echo '{...}' >> outbox.jsonl`).
- **ANSI escape leak in outbox.jsonl** — `cat outbox` shows `\e[` sequences. Fix: identity addendum tells DeepSeek V4 Pro to use `printf '%s\n' '{...}'` (Pattern B) and to never use commands that write through a TTY filter.

- [ ] **Step 2.8: Second run (cache warm)**

```bash
bash tracer/tracer-bullet-opencode.sh
```

Expected: `Ready in:` value should be lower than first run (warm node-modules + auth cache).

- [ ] **Step 2.9: Third run (final validation)**

```bash
bash tracer/tracer-bullet-opencode.sh
```

Expected: SUCCESS. Three consecutive clean runs = tracer task done.

If any of the three runs fail: do NOT commit. Diagnose, fix, restart the count. The pass criterion is **3 consecutive clean runs**, not "3 of N runs".

- [ ] **Step 2.10: Record measured timings for PR2**

Note `Ready in: <N>s` from the third (warm) run; this calibrates PR2's `bootstrap_sleep_s` and `ready_timeout_s` values. Write the numbers into `docs/superpowers/plans/2026-05-06-opencode-trooper-plan.md` at the bottom under `## PR1 measurements (filled in during execution)` so PR2 has them. Example:

```
PR1 measurements (filled during tracer):
- ready_in_s_warm: 7
- done_in_s_warm: 22
- chosen_bootstrap_sleep_s: 10  # ready_in_s - 3 to leave margin
- chosen_ready_timeout_s: 60    # round up from 7s × 8x safety
```

- [ ] **Step 2.11: Commit the tracer**

```bash
git add tracer/tracer-bullet-opencode.sh
git commit -m "feat(tracer): add opencode + DeepSeek V4 Pro tracer-bullet

Mirrors tracer-bullet.sh; launches \`opencode -m deepseek/deepseek-v4-pro\`
and validates ready+done event flow. 3 consecutive clean runs locally
before merge.

Measurements (warm): ready=<N>s done=<M>s — used to pin contracts.yaml
in PR2.
"
```

---

## Task 3: opencode preflight helper

**Files:**
- Create: `lib/opencode_preflight.sh`
- Create: `tests/test_medic_opencode_preflight.sh`

Pure-bash helper that medic.sh can call without depending on jq/python. Fails closed (returns WARN) when in doubt.

- [ ] **Step 3.1: Write the failing test**

Create `tests/test_medic_opencode_preflight.sh`:

```bash
#!/usr/bin/env bash
# tests/test_medic_opencode_preflight.sh — v0.13.0 regression for opencode
# preflight helper. Drives lib/opencode_preflight.sh through 4 config states:
# missing, "ask", "allow", and object-form. Asserts the helper's stdout +
# return code in each.
set -euo pipefail
cd "$(dirname "$0")"
PLUGIN_ROOT=$(cd .. && pwd)
source lib/assert.sh
source "$PLUGIN_ROOT/lib/opencode_preflight.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# === Case 1: no config file at all ===
out=$(cw_opencode_permission_check "$TMP/missing.json" 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "rc on missing config"
assert_contains "$out" "no opencode.json found" "stderr message on missing"
pass "preflight: missing config -> rc=1, mentions 'no opencode.json found'"

# === Case 2: config with permission: ask (default) ===
cat > "$TMP/ask.json" <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "permission": "ask"
}
EOF
out=$(cw_opencode_permission_check "$TMP/ask.json" 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "rc on permission=ask"
assert_contains "$out" "permission is 'ask'" "stderr names the offending value"
pass "preflight: permission=ask -> rc=1, names value"

# === Case 3: config with permission: allow (auto-approve) ===
cat > "$TMP/allow.json" <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "permission": "allow"
}
EOF
out=$(cw_opencode_permission_check "$TMP/allow.json" 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "0" "rc on permission=allow"
pass "preflight: permission=allow -> rc=0 (clean)"

# === Case 4: config with permission as object — informational warn ===
cat > "$TMP/object.json" <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "permission": {
    "bash": "allow",
    "edit": "allow"
  }
}
EOF
out=$(cw_opencode_permission_check "$TMP/object.json" 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "2" "rc on permission object form"
assert_contains "$out" "object-form permission" "stderr mentions object form"
pass "preflight: object-form -> rc=2 (informational)"

# === Case 5: cw_opencode_config_path search order ===
# Project-local opencode.json wins over global.
mkdir -p "$TMP/repo" "$TMP/home/.config/opencode"
cat > "$TMP/repo/opencode.json"            <<<'{"permission":"allow"}'
cat > "$TMP/home/.config/opencode/opencode.json" <<<'{"permission":"ask"}'
HOME="$TMP/home" found=$(cd "$TMP/repo" && cw_opencode_config_path)
assert_eq "$found" "$TMP/repo/opencode.json" "project-local wins"
pass "preflight: project-local opencode.json takes precedence over user-global"

# Project-local missing -> falls through to user-global.
rm "$TMP/repo/opencode.json"
HOME="$TMP/home" found=$(cd "$TMP/repo" && cw_opencode_config_path)
assert_eq "$found" "$TMP/home/.config/opencode/opencode.json" "fallback to global"
pass "preflight: falls through to ~/.config/opencode/opencode.json when no project-local"

# Neither present -> empty + rc=1.
rm "$TMP/home/.config/opencode/opencode.json"
HOME="$TMP/home" out=$(cd "$TMP/repo" && cw_opencode_config_path) && rc=0 || rc=$?
assert_eq "$rc" "1" "rc when neither config exists"
assert_eq "$out" "" "empty stdout when no config"
pass "preflight: returns rc=1 + empty stdout when no config exists anywhere"
```

Make it executable:
```bash
chmod +x tests/test_medic_opencode_preflight.sh
```

- [ ] **Step 3.2: Run test to verify it fails**

```bash
bash tests/test_medic_opencode_preflight.sh
```

Expected: bash error, `lib/opencode_preflight.sh: No such file or directory`. The lib doesn't exist yet — that's the expected failure.

- [ ] **Step 3.3: Create the lib helper**

Create `lib/opencode_preflight.sh`:

```bash
# lib/opencode_preflight.sh — preflight check for opencode auto-approve config.
#
# Pure-bash, no jq/python deps. Detects the top-level "permission" key in
# opencode.json. The object form ({"permission":{...}}) is acknowledged but
# not introspected — return code 2 signals "informational only, verify
# manually". Sourced by bin/medic.sh and tests/test_medic_opencode_preflight.sh.
#
# Exported functions:
#   cw_opencode_config_path        -> stdout: path to effective opencode.json
#                                     (project-local first, then user-global)
#                                     rc=0 found, rc=1 none exist
#   cw_opencode_permission_check   -> stdout: nothing on success
#                                     stderr: warn line on non-allow
#                                     rc=0 permission=allow (clean)
#                                     rc=1 missing config OR permission!=allow string
#                                     rc=2 object form (informational warn)

cw_opencode_config_path() {
  local project_cfg="$PWD/opencode.json"
  local global_cfg="${HOME}/.config/opencode/opencode.json"
  if [[ -f "$project_cfg" ]]; then
    printf '%s\n' "$project_cfg"
    return 0
  fi
  if [[ -f "$global_cfg" ]]; then
    printf '%s\n' "$global_cfg"
    return 0
  fi
  return 1
}

cw_opencode_permission_check() {
  local cfg="${1:-}"
  if [[ -z "$cfg" ]]; then
    cfg=$(cw_opencode_config_path) || cfg=""
  fi
  if [[ -z "$cfg" || ! -f "$cfg" ]]; then
    echo "no opencode.json found at \$PWD/opencode.json or \$HOME/.config/opencode/opencode.json" >&2
    return 1
  fi
  # Top-level "permission": "<value>" — string form. Object form is matched
  # by the object-detector below.
  local string_match
  string_match=$(grep -E '^\s*"permission"\s*:\s*"[a-z]+"' "$cfg" 2>/dev/null | head -1)
  if [[ -n "$string_match" ]]; then
    if [[ "$string_match" =~ \"permission\"[[:space:]]*:[[:space:]]*\"allow\" ]]; then
      return 0
    fi
    # ask, deny, or any other string value
    local val
    val=$(printf '%s' "$string_match" | sed -E 's/.*"permission"[[:space:]]*:[[:space:]]*"([a-z]+)".*/\1/')
    echo "opencode.json: permission is '$val' (need 'allow' for trooper auto-approve)" >&2
    echo "  config: $cfg" >&2
    return 1
  fi
  # Object form: "permission": { ... }
  if grep -qE '^\s*"permission"\s*:\s*\{' "$cfg" 2>/dev/null; then
    echo "opencode.json: object-form permission detected; medic does not introspect per-tool keys" >&2
    echo "  config: $cfg — verify all relevant tools (bash/edit/...) are 'allow' manually" >&2
    return 2
  fi
  echo "opencode.json: no top-level 'permission' key (defaults to 'ask')" >&2
  echo "  config: $cfg" >&2
  return 1
}
```

- [ ] **Step 3.4: Run test to verify it passes**

```bash
bash tests/test_medic_opencode_preflight.sh
```

Expected: 6 `PASS:` lines, exit code 0. If any case fails, fix the helper to satisfy the test's assertion.

- [ ] **Step 3.5: Run full test suite to confirm no regression**

```bash
bash tests/run.sh
```

Expected: every existing test still passes + the new test_medic_opencode_preflight.sh shows ok.

- [ ] **Step 3.6: Commit**

```bash
git add lib/opencode_preflight.sh tests/test_medic_opencode_preflight.sh
git commit -m "feat(medic): opencode auto-approve preflight helper

Pure-bash check (no jq/python deps): looks for project-local opencode.json
first, then user-global. Detects top-level \"permission\": \"allow\" string;
object-form returns informational rc=2 since medic doesn't introspect
per-tool keys.

Tests cover 4 config states + path-resolution precedence.
"
```

---

## Task 4: Wire preflight into medic.sh

**Files:**
- Modify: `bin/medic.sh` — source the preflight lib + call check from the providers loop

- [ ] **Step 4.1: Source the preflight lib at the top of medic.sh**

Edit `bin/medic.sh`. Find the existing source block (lines 12–16):

```bash
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deps.sh"
source "$PLUGIN_ROOT/lib/contracts.sh"
source "$PLUGIN_ROOT/lib/argsfile.sh"
```

Add the preflight source line:

```bash
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deps.sh"
source "$PLUGIN_ROOT/lib/contracts.sh"
source "$PLUGIN_ROOT/lib/argsfile.sh"
source "$PLUGIN_ROOT/lib/opencode_preflight.sh"
```

- [ ] **Step 4.2: Add the preflight call inside the providers loop**

Find the providers loop block (lines 162–184). The `done < <(cw_contracts_providers)` line marks its end. AFTER the loop closes (after the `else` branch on lines 181–184), but BEFORE the blank `echo` at line 186, insert:

```bash
# 5b. opencode auto-approve preflight (warn-only in v0.13.0).
# Runs only when opencode is on PATH AND has a contracts.yaml row (so users
# without opencode aren't nagged).
if cw_have_cmd opencode 2>/dev/null \
   && cw_contracts_exists \
   && cw_contracts_providers 2>/dev/null | grep -qx 'opencode'; then
  if ! cw_opencode_permission_check >/dev/null 2>&1; then
    rc_pf=$?
    msg=$(cw_opencode_permission_check 2>&1 >/dev/null)
    case "$rc_pf" in
      1) log_warn "  opencode auto-approve: $msg"
         warn=1 ;;
      2) log_warn "  opencode auto-approve: $msg (non-fatal)"
         warn=1 ;;
    esac
  else
    log_ok "  opencode auto-approve: 'permission: allow' detected"
  fi
fi
```

The check is gated on `cw_contracts_providers | grep -qx 'opencode'` so it only runs once PR2 has added the contracts row. PR1 alone is no-op for users (the helper exists + is tested but doesn't actively warn yet).

- [ ] **Step 4.3: Verify the medic smoke test still loads (it doesn't call preflight)**

```bash
bash bin/medic.sh
```

Expected: existing OK/WARN output, no new lines (because PR1 hasn't added opencode to contracts.yaml). Verdict unchanged.

- [ ] **Step 4.4: Add a focused medic-integration assertion to the preflight test**

Append to `tests/test_medic_opencode_preflight.sh` (before the `pass` finalizer):

```bash
# === Case 6: medic.sh sources lib/opencode_preflight.sh cleanly ===
out=$( bash -c "source $PLUGIN_ROOT/lib/log.sh; source $PLUGIN_ROOT/lib/opencode_preflight.sh; type cw_opencode_permission_check >/dev/null && echo SOURCED" 2>&1)
assert_contains "$out" "SOURCED" "lib sources cleanly under set -uo pipefail"
pass "preflight: lib/opencode_preflight.sh sources cleanly"
```

- [ ] **Step 4.5: Re-run the test**

```bash
bash tests/test_medic_opencode_preflight.sh
```

Expected: 7 PASS lines, exit 0.

- [ ] **Step 4.6: Run the full suite**

```bash
bash tests/run.sh
```

Expected: all green.

- [ ] **Step 4.7: Commit**

```bash
git add bin/medic.sh tests/test_medic_opencode_preflight.sh
git commit -m "feat(medic): wire opencode preflight into providers loop

Gated on cw_have_cmd opencode AND opencode being in contracts.yaml so
users without the provider aren't nagged. WARN-only — verdict unchanged.

PR1 adds the wiring but it's no-op until PR2 adds the contracts row.
"
```

---

## Task 5: Ship PR1

- [ ] **Step 5.1: Run the full suite once more**

```bash
bash tests/run.sh
```

Expected: every test ok.

- [ ] **Step 5.2: Final tracer-bullet sanity (one fresh run)**

```bash
# Inside tmux:
bash tracer/tracer-bullet-opencode.sh
```

Expected: SUCCESS. If not, do NOT push — re-diagnose.

- [ ] **Step 5.3: Push branch + open PR1**

```bash
git push -u origin feat/v0.13.0-opencode-tracer
gh pr create --title "feat(v0.13.0): tracer-bullet + medic preflight for opencode" \
  --body "$(cat <<'EOF'
## Summary

- Adds `tracer/tracer-bullet-opencode.sh` — validated 3x locally with `opencode -m deepseek/deepseek-v4-pro`
- Adds `lib/opencode_preflight.sh` — pure-bash auto-approve config detector (no jq/python)
- Wires preflight into `bin/medic.sh` (warn-only, gated on opencode being in contracts.yaml)
- Adds `tests/test_medic_opencode_preflight.sh` (7 cases)

## Spec
`docs/superpowers/specs/2026-05-06-opencode-trooper-design.md`

## Test plan
- [x] 3 consecutive clean tracer runs locally
- [x] `bash tests/run.sh` green
- [x] `bash bin/medic.sh` verdict unchanged on local machine

## Measurements (for PR2)
- ready_in_s (warm): <fill from tracer log>
- done_in_s (warm):  <fill from tracer log>
- chosen bootstrap_sleep_s: <fill>
- chosen ready_timeout_s: <fill>

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

After merge: pull main, branch for PR2.

---

# Phase 2 — PR2: contracts row + --provider + scope amendment + dogfood

## Task 6: Set up PR2 branch

- [ ] **Step 6.1: Pull main and branch**

```bash
git checkout main
git pull origin main
git log --oneline -3
# Expected: top commit is the merged PR1 (feat(v0.13.0): tracer + preflight)
git checkout -b feat/v0.13.0-opencode-contracts
```

---

## Task 7: contracts.yaml opencode row

**Files:**
- Modify: `config/contracts.yaml`
- Create: `tests/test_contracts_opencode.sh`

- [ ] **Step 7.1: Write the failing test**

Create `tests/test_contracts_opencode.sh`:

```bash
#!/usr/bin/env bash
# tests/test_contracts_opencode.sh — v0.13.0 regression for opencode
# contract row. Asserts cw_contract_* helpers return expected values.
set -euo pipefail
cd "$(dirname "$0")"
PLUGIN_ROOT=$(cd .. && pwd)
source lib/assert.sh

# Stage a state root with the shipped contracts.yaml so the helpers
# read from the in-tree file (medic copies on first run; here we copy
# directly to keep the test hermetic).
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"
mkdir -p "$CLONE_WARS_HOME"
cp "$PLUGIN_ROOT/config/contracts.yaml" "$CLONE_WARS_HOME/contracts.yaml"

source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/contracts.sh"

# === Provider enumeration includes opencode ===
providers=$(cw_contracts_providers | sort | tr '\n' ',' | sed 's/,$//')
assert_contains "$providers" "opencode" "opencode listed by cw_contracts_providers"
pass "contracts: opencode appears in cw_contracts_providers output"

# === Binary ===
bin=$(cw_contract_binary opencode)
assert_eq "$bin" "opencode" "cw_contract_binary opencode"
pass "contracts: cw_contract_binary opencode == opencode"

# === Default mode ===
mode=$(cw_contract_default_mode opencode)
assert_eq "$mode" "full" "cw_contract_default_mode opencode"
pass "contracts: cw_contract_default_mode opencode == full"

# === Mode args (full) ===
args=$(cw_contract_mode_args opencode full | tr '\n' '|')
assert_eq "$args" "-m|deepseek/deepseek-v4-pro|" "cw_contract_mode_args opencode full"
pass "contracts: cw_contract_mode_args opencode full == -m deepseek/deepseek-v4-pro"

# === Ready timeout (calibrated from PR1 tracer; see plan §PR1 measurements) ===
rt=$(cw_contract_ready_timeout opencode)
# Accept any positive integer >= 30 (lets the calibrated value vary by
# machine without breaking the test). Tracer-pinned exact value was 60.
[[ "$rt" =~ ^[0-9]+$ ]] && (( rt >= 30 )) \
  || { echo "FAIL: ready_timeout_s expected >=30 integer, got '$rt'" >&2; exit 1; }
pass "contracts: cw_contract_ready_timeout opencode is sane (got $rt)"

# === Bootstrap sleep ===
bs=$(cw_contract_bootstrap_sleep opencode)
[[ "$bs" =~ ^[0-9]+$ ]] && (( bs >= 5 )) \
  || { echo "FAIL: bootstrap_sleep_s expected >=5 integer, got '$bs'" >&2; exit 1; }
pass "contracts: cw_contract_bootstrap_sleep opencode is sane (got $bs)"
```

```bash
chmod +x tests/test_contracts_opencode.sh
bash tests/test_contracts_opencode.sh
```

Expected: FAIL — "opencode listed by cw_contracts_providers" assertion. The row doesn't exist yet.

- [ ] **Step 7.2: Add the opencode row to contracts.yaml**

Edit `config/contracts.yaml`. AFTER the `claude:` block (which currently ends at line 50), BEFORE the `consult:` block, insert:

```yaml

opencode:
  binary: opencode
  modes:
    full:      [-m, deepseek/deepseek-v4-pro]
    read-only: [-m, deepseek/deepseek-v4-pro]   # opencode has no permission flag; same row
  default_mode: full
  ready_timeout_s: 60       # tracer-bullet measured ~7s warm; 60 leaves 8x safety margin
  bootstrap_sleep_s: 10     # tracer-bullet measured ~7s warm cold-start; 10 leaves margin
  identity_injection: send-keys-paste
```

Substitute the `60` and `10` with the actual values from PR1's tracer measurements (see PR1's commit message + the plan's "PR1 measurements" appendix).

- [ ] **Step 7.3: Run the test — should pass**

```bash
bash tests/test_contracts_opencode.sh
```

Expected: 6 PASS lines, exit 0.

- [ ] **Step 7.4: Run the full suite**

```bash
bash tests/run.sh
```

Expected: all green. The new test plus all existing tests pass.

- [ ] **Step 7.5: Commit**

```bash
git add config/contracts.yaml tests/test_contracts_opencode.sh
git commit -m "feat(contracts): add opencode (DeepSeek V4 Pro) provider row

Pinned launch: opencode -m deepseek/deepseek-v4-pro. Timeouts calibrated
from PR1's tracer-bullet measurements (~7s warm cold-start).
"
```

---

## Task 8: --provider flag for /clone-wars:deploy

**Files:**
- Modify: `lib/deploy.sh` — `cw_deploy_detect_provider` accepts optional override
- Modify: `bin/deploy-init.sh` — accept `--provider <name>` argv flag
- Create: `tests/test_deploy_provider_flag.sh`

- [ ] **Step 8.1: Write the failing test**

Create `tests/test_deploy_provider_flag.sh`:

```bash
#!/usr/bin/env bash
# tests/test_deploy_provider_flag.sh — v0.13.0 regression: --provider
# override beats cw_deploy_detect_provider's default.
set -euo pipefail
cd "$(dirname "$0")"
PLUGIN_ROOT=$(cd .. && pwd)
source lib/assert.sh

source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/consult.sh"
source "$PLUGIN_ROOT/lib/deploy.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# === Case 1: no override, no plugin marker -> codex (default) ===
mkdir -p "$TMP/plain"
detected=$(cw_deploy_detect_provider "$TMP/plain")
assert_eq "$detected" "codex" "default detection for plain repo"
pass "detect: plain repo -> codex"

# === Case 2: no override, plugin marker -> claude ===
mkdir -p "$TMP/plug/.claude-plugin"
echo '{}' > "$TMP/plug/.claude-plugin/plugin.json"
detected=$(cw_deploy_detect_provider "$TMP/plug")
assert_eq "$detected" "claude" "plugin repo -> claude"
pass "detect: plugin repo -> claude"

# === Case 3: override beats default ===
detected=$(cw_deploy_detect_provider "$TMP/plain" "opencode")
assert_eq "$detected" "opencode" "override beats default"
pass "detect: override beats default"

# === Case 4: override beats plugin-marker too ===
detected=$(cw_deploy_detect_provider "$TMP/plug" "opencode")
assert_eq "$detected" "opencode" "override beats plugin-marker"
pass "detect: override beats plugin-marker"

# === Case 5: empty-string override is no-op (auto-detect runs) ===
detected=$(cw_deploy_detect_provider "$TMP/plug" "")
assert_eq "$detected" "claude" "empty override = no override"
pass "detect: empty-string override is treated as no override"
```

```bash
chmod +x tests/test_deploy_provider_flag.sh
bash tests/test_deploy_provider_flag.sh
```

Expected: FAIL — `cw_deploy_detect_provider` ignores second arg.

- [ ] **Step 8.2: Add override branch to cw_deploy_detect_provider**

Open `lib/deploy.sh`. Find `cw_deploy_detect_provider` (search for `cw_deploy_detect_provider()` — the function definition). The function currently takes one positional arg (cwd). AT THE TOP of the function body, AFTER the line that captures the cwd, BEFORE any other logic, insert the override-shortcut block:

```bash
cw_deploy_detect_provider() {
  local cwd="${1:-$PWD}"
  local override="${2:-}"
  if [[ -n "$override" ]]; then
    printf '%s\n' "$override"
    return 0
  fi
  # ... existing auto-detect logic (unchanged) ...
}
```

If the existing function uses different variable names or structure, adapt the override block to match. Keep the override at the top so it short-circuits before any FS access.

- [ ] **Step 8.3: Run the test — should pass**

```bash
bash tests/test_deploy_provider_flag.sh
```

Expected: 5 PASS lines, exit 0. If a "default detection" case fails because the existing function's defaults changed, fix the test's expected value to match (don't change function defaults).

- [ ] **Step 8.4: Wire --provider into bin/deploy-init.sh**

Edit `bin/deploy-init.sh`. Find the argv parsing while-loop (around lines 27–38). After the `--topic` case but before the `--)` case, add a `--provider` case:

```bash
NO_BRANCH=0
BRANCH_OVERRIDE=""
TOPIC_OVERRIDE=""
PROVIDER_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-branch)  NO_BRANCH=1; shift ;;
    --branch)     [[ -n "${2:-}" ]] || { echo "--branch requires a value" >&2; exit 2; }
                  BRANCH_OVERRIDE="$2"; shift 2 ;;
    --topic)      [[ -n "${2:-}" ]] || { echo "--topic requires a value" >&2; exit 2; }
                  TOPIC_OVERRIDE="$2"; shift 2 ;;
    --provider)   [[ -n "${2:-}" ]] || { echo "--provider requires a value" >&2; exit 2; }
                  PROVIDER_OVERRIDE="$2"; shift 2 ;;
    --) shift; break ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *)  break ;;
  esac
done
```

Then find the spot where `cw_deploy_detect_provider` is called within deploy-init.sh (search the file). Pass `$PROVIDER_OVERRIDE` as the second arg:

```bash
PROVIDER=$(cw_deploy_detect_provider "$TARGET_CWD" "$PROVIDER_OVERRIDE")
```

If deploy-init.sh does NOT currently call `cw_deploy_detect_provider` (the directive `commands/deploy.md` does it instead), add a write to a state file that the directive reads. Specifically, after `printf '%s\n' "$TARGET_CWD" | cw_atomic_write "$ART_DIR/target_cwd.txt"`, add:

```bash
# v0.13.0: when --provider <name> is passed, persist it so the directive's
# Step 0 auto-detect block reads it as the override.
if [[ -n "$PROVIDER_OVERRIDE" ]]; then
  printf '%s\n' "$PROVIDER_OVERRIDE" | cw_atomic_write "$ART_DIR/provider_override.txt" \
    || { log_error "failed to write provider_override.txt"; exit 1; }
fi
```

Choose whichever insertion point matches the existing flow. (The directive then reads `$ART_DIR/provider_override.txt` BEFORE calling `cw_deploy_detect_provider` and passes its contents as the second arg.)

- [ ] **Step 8.5: If the directive needs an update, edit `commands/deploy.md`**

Find the spot in `commands/deploy.md` (the slash-command directive) where `cw_deploy_detect_provider` is invoked (likely Step 0 or Step 1.1). Replace the bare invocation with one that honors `provider_override.txt`:

```
PROVIDER_OVERRIDE=""
[[ -f "$ART_DIR/provider_override.txt" ]] && PROVIDER_OVERRIDE=$(cat "$ART_DIR/provider_override.txt")
PROVIDER=$(cw_deploy_detect_provider "$TARGET_CWD" "$PROVIDER_OVERRIDE")
```

If `commands/deploy.md` already abstracts provider detection through some other helper, route the override through that helper instead. Verify with `grep -n cw_deploy_detect_provider commands/deploy.md`.

- [ ] **Step 8.6: Run all tests**

```bash
bash tests/run.sh
```

Expected: all green.

- [ ] **Step 8.7: Commit**

```bash
git add lib/deploy.sh bin/deploy-init.sh commands/deploy.md tests/test_deploy_provider_flag.sh
git commit -m "feat(deploy): add --provider flag override

Lets users explicitly pick the trooper provider (e.g. opencode) instead
of relying on cw_deploy_detect_provider's repo-marker heuristic. Backward
compatible: empty override falls through to auto-detect.

Plumbing: deploy-init.sh writes ART_DIR/provider_override.txt when
--provider is passed; commands/deploy.md reads it and passes to
cw_deploy_detect_provider as the 2nd arg.
"
```

---

## Task 9: CLAUDE.md scope amendment + Status

**Files:**
- Modify: `CLAUDE.md` — out-of-scope list + Status section

- [ ] **Step 9.1: Update the closed-set boundary**

Find the line in `CLAUDE.md`:
```
- DeepSeek and arbitrary OpenAI-compat providers. Closed set: claude / codex / gemini.
```

Replace with:
```
- Generic OpenAI-compat providers (LM Studio, ollama, vLLM, DeepSeek-via-other-clients).
  Closed set: claude / codex / gemini / opencode (pinned to DeepSeek V4 Pro).
  Justification for opencode: model diversity beyond Western houses; pinned to one model
  to preserve "smaller than OMC" thesis. Generic open-set still rejected.
```

- [ ] **Step 9.2: Add v0.13.0 entries to the Status section**

Find the Status section. AFTER `- [ ] v0.12.0 strict-dogfood pass on a real machine ...` (or whatever the most recent v0.12.x item is), add:

```markdown
- [x] v0.13.0: opencode trooper (DeepSeek V4 Pro) — tracer + medic preflight + contracts row + --provider flag
- [ ] v0.13.0 strict-dogfood pass on a real machine (release gate — see tests/test_*opencode*.sh + manual spawn)
```

- [ ] **Step 9.3: Verify with grep**

```bash
grep -E "Closed set:" CLAUDE.md
# Expected: "Closed set: claude / codex / gemini / opencode (pinned to DeepSeek V4 Pro)."
grep -E "v0\.13\.0" CLAUDE.md
# Expected: 2 matches (the [x] line and the [ ] dogfood gate line)
```

- [ ] **Step 9.4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(claude): lift closed-set restriction for opencode + DeepSeek V4 Pro

Closed set 3 -> 4. Generic OpenAI-compat providers remain rejected.
Justification recorded inline. v0.13.0 status entries added.
"
```

---

## Task 10: docs/DESIGN.md provider table

**Files:**
- Modify: `docs/DESIGN.md`

- [ ] **Step 10.1: Locate the provider table**

```bash
grep -n -A3 "^| Provider" docs/DESIGN.md | head -20
# Or whatever heading style is used; look for the table that lists
# claude/codex/gemini binaries + flags.
```

- [ ] **Step 10.2: Add the opencode row to the table**

After the row for `claude`, insert (matching column count + style):

```markdown
| opencode | DeepSeek V4 Pro | `opencode` | `-m deepseek/deepseek-v4-pro` | 60 | 10 | send-keys-paste |
```

(Adjust columns to match the table's actual headers — common headers: Provider | Model | Binary | Launch Args | ready_timeout_s | bootstrap_sleep_s | Identity Injection.)

- [ ] **Step 10.3: Commit**

```bash
git add docs/DESIGN.md
git commit -m "docs(design): add opencode/DeepSeek-V4-Pro to provider table"
```

---

## Task 11: Version bump to 0.13.0

**Files:**
- Modify: `.claude-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json`

- [ ] **Step 11.1: Update plugin.json**

Edit `.claude-plugin/plugin.json`. Change `"version": "0.12.2"` to `"version": "0.13.0"`.

- [ ] **Step 11.2: Update marketplace.json — both occurrences**

Edit `.claude-plugin/marketplace.json`. There are TWO `"version": "0.12.2"` occurrences (one inside `plugins[0]`, one at top level). Change both to `"0.13.0"`.

- [ ] **Step 11.3: Verify with grep**

```bash
grep -E '"version"\s*:\s*"' .claude-plugin/plugin.json .claude-plugin/marketplace.json
# Expected: every line shows "0.13.0"
```

- [ ] **Step 11.4: Commit**

```bash
git add .claude-plugin/plugin.json .claude-plugin/marketplace.json
git commit -m "chore(release): bump plugin to v0.13.0"
```

---

## Task 12: Dogfood gate + ship PR2

- [ ] **Step 12.1: Run the full test suite**

```bash
bash tests/run.sh
```

Expected: all green.

- [ ] **Step 12.2: Run medic against the final state**

```bash
bash bin/medic.sh
```

Expected output (representative):
```
Providers:
  ok  codex (codex): 0.x.y
  ok  gemini (gemini): ...
  ok  claude (claude): ...
  ok  opencode (opencode): 1.14.39
  warn  opencode auto-approve: ...   # if user's opencode.json doesn't have permission: allow
                                     # OR
  ok  opencode auto-approve: 'permission: allow' detected
Verdict: OK
```

If verdict is FAIL, fix before shipping.

- [ ] **Step 12.3: Manual dogfood — spawn opencode with a real prompt**

```bash
# Inside tmux, with opencode.json having "permission":"allow" set somewhere:
tmux new -s opencode-dogfood -d 2>/dev/null || true
tmux attach -t opencode-dogfood &
# Then in your active Claude Code session:
# /clone-wars:spawn rex opencode dogfood-13
```

After spawn returns, send a research prompt:
```
/clone-wars:send rex dogfood-13 "Summarize the spec at \
  docs/superpowers/specs/2026-05-06-opencode-trooper-design.md \
  in 5 bullet points. Write your output to \
  ~/.clone-wars/state/<repo-hash>/dogfood-13/rex-opencode/findings.md \
  before emitting the done event. END_OF_INSTRUCTION"
```

```
/clone-wars:collect rex dogfood-13
```

Expected:
- Outbox `~/.clone-wars/state/<repo-hash>/dogfood-13/rex-opencode/outbox.jsonl` shows valid JSONL with `{"event":"ack",...}` then `{"event":"done",...}`
- `findings.md` exists with 5 bullets summarizing the spec
- No ANSI escapes in `outbox.jsonl`

If anything fails, do NOT ship PR2. File the failure mode and triage.

- [ ] **Step 12.4: Tear down**

```
/clone-wars:teardown rex dogfood-13
```

- [ ] **Step 12.5: Update CLAUDE.md to check the dogfood gate**

Edit `CLAUDE.md`, find the v0.13.0 dogfood gate line:
```markdown
- [ ] v0.13.0 strict-dogfood pass on a real machine (release gate ...)
```
Change `[ ]` to `[x]`. Commit:

```bash
git add CLAUDE.md
git commit -m "chore(release): mark v0.13.0 dogfood gate complete"
```

- [ ] **Step 12.6: Push branch + open PR2**

```bash
git push -u origin feat/v0.13.0-opencode-contracts
gh pr create --title "feat(v0.13.0): opencode (DeepSeek V4 Pro) trooper provider" \
  --body "$(cat <<'EOF'
## Summary

- Adds `opencode` row to `config/contracts.yaml` (pinned to DeepSeek V4 Pro)
- Adds `--provider <name>` flag to `/clone-wars:deploy`
- Lifts CLAUDE.md closed-set restriction (3 -> 4 providers; generic OpenAI-compat still rejected)
- Bumps plugin version `0.12.2` -> `0.13.0`
- Manual dogfood gate passed locally

## Spec
`docs/superpowers/specs/2026-05-06-opencode-trooper-design.md`
## Plan
`docs/superpowers/plans/2026-05-06-opencode-trooper-plan.md`
## Stacked on
PR1 (`feat(v0.13.0): tracer-bullet + medic preflight for opencode`)

## Test plan
- [x] `bash tests/run.sh` green (new tests: test_contracts_opencode.sh, test_deploy_provider_flag.sh)
- [x] `bash bin/medic.sh` verdict OK (with opencode.json permission=allow set)
- [x] Manual `/clone-wars:spawn rex opencode dogfood-13` -> ack/done events, findings.md written, no ANSI bleed
- [x] CLAUDE.md grep gate: "Closed set: claude / codex / gemini / opencode" present

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

After merge: pull main, optionally delete feature branches.

---

## PR1 measurements (filled during execution)

```
ready_in_s_warm: <fill>
done_in_s_warm: <fill>
chosen_bootstrap_sleep_s: <fill>
chosen_ready_timeout_s: <fill>
identity_injection_method_validated: <fill>  # send-keys-l vs paste-buffer
ANSI_bleed_observed: <fill>                  # yes/no — if yes, identity addendum needed
JSONL_discipline_observed: <fill>            # clean / drift / required-pattern-A-only
```

---

## Self-Review Notes

Cross-checked against the spec sections:

- **Architecture** — covered by Tasks 2 (tracer) + 7 (contracts row).
- **Components §1 tracer** — Task 2.
- **Components §2 medic preflight** — Tasks 3-4.
- **Components §3 contracts.yaml** — Task 7.
- **Components §4-5 lib/contracts.sh + spawn.sh unchanged** — explicitly verified by tests in Tasks 7-8.
- **Components §6 docs** — Task 9 (CLAUDE.md) + Task 10 (DESIGN.md).
- **Components §7 --provider flag** — Task 8.
- **Data flow** — implicitly tested by the dogfood gate (Task 12.3).
- **Error handling** — `_spawn_bootstrap_fail` inheritance is verified by the dogfood gate; medic preflight is warn-only as spec'd; tracer-bullet failure mode is documented in Task 2.7.
- **Testing** — every spec testing item maps to a task: tracer (Task 2), preflight test (Task 3), contracts test (Task 7), --provider test (Task 8), CLAUDE.md grep (Task 9.3), dogfood gate (Task 12.3).
- **Out-of-scope amendments** (3-way consult, generic open-set, etc.) — preserved as documented in Task 9.1's CLAUDE.md edit.

The "PR1 measurements" appendix is populated during execution by the engineer running the tracer; this is the only intentional fill-in-during-execution artifact in the plan and is structurally bounded (filled before PR2 starts).
