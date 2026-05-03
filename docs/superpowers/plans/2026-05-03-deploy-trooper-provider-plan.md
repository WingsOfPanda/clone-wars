# Deploy Trooper Provider Auto-Detect Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Auto-detect the trooper provider for `/clone-wars:deploy` based on whether `.claude-plugin/plugin.json` exists at the repo root; codex auto-goes (cheap default), claude requires user consent (token-aware).

**Architecture:** Add one detector helper `cw_deploy_detect_provider` to `lib/deploy.sh`; wire it into `bin/deploy-init.sh` to write `_deploy/auto_provider.txt`; update `commands/deploy.md` Step 0 to read the auto file and `AskUserQuestion` when claude is detected, then write the final choice to `_deploy/provider.txt`; thread `$PROVIDER` through Step 1.1's spawn line. No CLI flag — confirmation dialog is the only override.

**Tech Stack:** bash 4.2+, file IPC (atomic tmp+rename writes), existing `lib/{state,log,deploy}.sh` patterns, `tests/lib/assert.sh`, `tests/run.sh`.

**Spec:** `docs/superpowers/specs/2026-05-03-deploy-trooper-provider-design.md` (committed `941ba84`)

---

## File Map

| File | Action | Notes |
|---|---|---|
| `lib/deploy.sh` | modify | Add `cw_deploy_detect_provider` (Task 1) |
| `bin/deploy-init.sh` | modify | Append detection + auto_provider.txt write (Task 2) |
| `bin/medic.sh` | modify | Probe extends to call new helper (Task 3) |
| `commands/deploy.md` | modify | Step 0 reads auto + confirms; Step 1.1 uses `$PROVIDER` (Task 4) |
| `tests/test_deploy_helpers.sh` | modify | 5 new assertions for the detector (Task 1) |
| `tests/test_deploy_init.sh` | modify | 2 new assertions for auto_provider.txt (Task 2) |
| `tests/test_medic.sh` | modify | 1 new assertion (probe still clean) (Task 3) |
| `tests/test_deploy_directive_provider.sh` | create | Static-wiring assertions (Task 5) |
| `tests/test_deploy_v07_dogfood.sh` | modify | Add provider-selection scenario (Task 6) |
| `CLAUDE.md` | modify | Status checklist tick (Task 7) |

Total: 1 created test, 9 modifications.

---

## Task 1: Add `cw_deploy_detect_provider` helper

**Files:**
- Modify: `lib/deploy.sh` (append new helper after the existing turn prompt builders, around line 211)
- Modify: `tests/test_deploy_helpers.sh` (extend with 5 new assertions)

- [ ] **Step 1: Extend the failing test**

Read `tests/test_deploy_helpers.sh` to find the END of the file (or before any final `echo "ALL: ok"` if present). Append:

```bash

# --- cw_deploy_detect_provider ---
TMP_DETECT=$(mktemp -d); trap 'rm -rf "$TMP_DETECT"' EXIT

# Case 1: file present → claude
mkdir -p "$TMP_DETECT/yes/.claude-plugin"
touch "$TMP_DETECT/yes/.claude-plugin/plugin.json"
out=$(cw_deploy_detect_provider "$TMP_DETECT/yes")
[[ "$out" == "claude" ]] \
  || { echo "FAIL: detect with plugin.json should return 'claude' (got '$out')" >&2; exit 1; }
pass "detect_provider returns 'claude' when .claude-plugin/plugin.json exists"

# Case 2: file absent → codex
mkdir -p "$TMP_DETECT/no"
out=$(cw_deploy_detect_provider "$TMP_DETECT/no")
[[ "$out" == "codex" ]] \
  || { echo "FAIL: detect without plugin.json should return 'codex' (got '$out')" >&2; exit 1; }
pass "detect_provider returns 'codex' when .claude-plugin/plugin.json absent"

# Case 3: directory present but no file → codex (presence test must be on file)
mkdir -p "$TMP_DETECT/dir-only/.claude-plugin"
out=$(cw_deploy_detect_provider "$TMP_DETECT/dir-only")
[[ "$out" == "codex" ]] \
  || { echo "FAIL: empty .claude-plugin/ dir should return 'codex' (got '$out')" >&2; exit 1; }
pass "detect_provider returns 'codex' when .claude-plugin/ exists but plugin.json doesn't"

# Case 4: missing repo-root → codex (graceful no-signal case)
out=$(cw_deploy_detect_provider "$TMP_DETECT/does-not-exist")
[[ "$out" == "codex" ]] \
  || { echo "FAIL: missing repo-root should return 'codex' (got '$out')" >&2; exit 1; }
pass "detect_provider returns 'codex' when repo-root doesn't exist"

# Case 5: no arg → rc=2 with clear error
err=$(cw_deploy_detect_provider 2>&1) && rc=0 || rc=$?
[[ "$rc" -eq 2 ]] || { echo "FAIL: no arg should rc=2 (got $rc)" >&2; exit 1; }
echo "$err" | grep -qi 'missing.*repo-root\|repo-root.*missing\|repo-root arg' \
  || { echo "FAIL: no-arg error message unclear: $err" >&2; exit 1; }
pass "detect_provider rc=2 + clear error when no arg"
```

- [ ] **Step 2: Run the test, confirm new section FAILS**

```
cd /home/liupan/CC/clone-wars && bash tests/test_deploy_helpers.sh
```

Expected: existing PASS lines preserved, then `cw_deploy_detect_provider: command not found` (or first new assertion fails).

- [ ] **Step 3: Add the helper to `lib/deploy.sh`**

Read `lib/deploy.sh` to find the END of the existing helpers section (after `cw_deploy_build_turn_prompt_fix`'s closing `}`, around line 210). Append:

```bash

# cw_deploy_detect_provider <repo-root>
# Auto-detect rule for /clone-wars:deploy: presence of
# <repo-root>/.claude-plugin/plugin.json signals "this repo is a Claude Code
# plugin" → claude trooper. Otherwise → codex (cheap default).
# Returns the slug to stdout. rc=2 on missing arg.
cw_deploy_detect_provider() {
  local repo_root="$1"
  [[ -n "$repo_root" ]] || { log_error "cw_deploy_detect_provider: missing repo-root arg"; return 2; }
  if [[ -f "$repo_root/.claude-plugin/plugin.json" ]]; then
    printf 'claude\n'
  else
    printf 'codex\n'
  fi
}
```

- [ ] **Step 4: Run the test, confirm it PASSES**

```
cd /home/liupan/CC/clone-wars && bash tests/test_deploy_helpers.sh
```

Expected: existing PASS lines + 5 new PASS lines (`detect_provider returns 'claude' …`, etc.). Suite ends green.

- [ ] **Step 5: Commit**

```
cd /home/liupan/CC/clone-wars
git add lib/deploy.sh tests/test_deploy_helpers.sh
git commit -m "feat(deploy): add cw_deploy_detect_provider helper"
```

---

## Task 2: Wire detector into `bin/deploy-init.sh`

**Files:**
- Modify: `bin/deploy-init.sh` (insert detection + auto_provider.txt write after the branch-create block)
- Modify: `tests/test_deploy_init.sh` (extend with 2 new assertions)

- [ ] **Step 1: Extend the failing test**

Read `tests/test_deploy_init.sh` to find the END of the file. Append:

```bash

# --- auto_provider.txt: codex case (no .claude-plugin/plugin.json) ---
TMP_AP_CODEX=$(mktemp -d); trap 'rm -rf "$TMP_AP_CODEX"' EXIT
export CLONE_WARS_HOME="$TMP_AP_CODEX/cw"
mkdir -p "$TMP_AP_CODEX/repo"; cd "$TMP_AP_CODEX/repo"
git init -q .; git config user.email t@t; git config user.name t
echo "# fake spec" > /tmp/auto-provider-fake-spec-codex.md
git add -A; git commit -q --allow-empty -m init
TOPIC=$(../../bin/deploy-init.sh --no-branch /tmp/auto-provider-fake-spec-codex.md 2>/dev/null \
  || ../../bin/deploy-init.sh --no-branch --topic auto-codex /tmp/auto-provider-fake-spec-codex.md 2>/dev/null) || true
RH=$(bash -c 'source ../../lib/state.sh; cw_repo_hash')
ART="$CLONE_WARS_HOME/state/$RH/$TOPIC/_deploy"
[[ -f "$ART/auto_provider.txt" ]] \
  || { echo "FAIL: codex case missing auto_provider.txt at $ART" >&2; exit 1; }
[[ "$(cat "$ART/auto_provider.txt")" == "codex" ]] \
  || { echo "FAIL: codex case auto_provider.txt should be 'codex' (got '$(cat "$ART/auto_provider.txt")')" >&2; exit 1; }
pass "deploy-init writes auto_provider.txt=codex when no .claude-plugin/plugin.json"
cd "$OLDPWD" 2>/dev/null || cd /tmp

# --- auto_provider.txt: claude case (.claude-plugin/plugin.json present) ---
TMP_AP_CLAUDE=$(mktemp -d); trap 'rm -rf "$TMP_AP_CODEX" "$TMP_AP_CLAUDE"' EXIT
export CLONE_WARS_HOME="$TMP_AP_CLAUDE/cw"
mkdir -p "$TMP_AP_CLAUDE/repo/.claude-plugin"
touch "$TMP_AP_CLAUDE/repo/.claude-plugin/plugin.json"
cd "$TMP_AP_CLAUDE/repo"
git init -q .; git config user.email t@t; git config user.name t
echo "# fake spec" > /tmp/auto-provider-fake-spec-claude.md
git add -A; git commit -q --allow-empty -m init
TOPIC=$(../../bin/deploy-init.sh --no-branch --topic auto-claude /tmp/auto-provider-fake-spec-claude.md 2>/dev/null) || true
RH=$(bash -c 'source ../../lib/state.sh; cw_repo_hash')
ART="$CLONE_WARS_HOME/state/$RH/$TOPIC/_deploy"
[[ -f "$ART/auto_provider.txt" ]] \
  || { echo "FAIL: claude case missing auto_provider.txt at $ART" >&2; exit 1; }
[[ "$(cat "$ART/auto_provider.txt")" == "claude" ]] \
  || { echo "FAIL: claude case auto_provider.txt should be 'claude' (got '$(cat "$ART/auto_provider.txt")')" >&2; exit 1; }
pass "deploy-init writes auto_provider.txt=claude when .claude-plugin/plugin.json present"
cd "$OLDPWD" 2>/dev/null || cd /tmp
```

NOTE: the test uses `--no-branch` to avoid the dirty-tree gate. Also verify the existing test file's harness conventions (working dir, cleanup) before merging — adapt the trap chain if the existing file already has one.

- [ ] **Step 2: Run the test, confirm new section FAILS**

```
cd /home/liupan/CC/clone-wars && bash tests/test_deploy_init.sh
```

Expected: existing PASS lines preserved, then FAIL on `missing auto_provider.txt`.

- [ ] **Step 3: Update `bin/deploy-init.sh`**

Read `bin/deploy-init.sh` to find the section AFTER the `# Branch` block (currently around line 80, just before the closing `log_info "topic: …"` lines). Insert this block:

```bash

# Auto-detect trooper provider (presence of .claude-plugin/plugin.json
# at the repo root → claude; else → codex). Used by commands/deploy.md
# Step 0 to pick the trooper for spawn.
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
AUTO_PROVIDER=$(cw_deploy_detect_provider "$REPO_ROOT")
printf '%s\n' "$AUTO_PROVIDER" > "$ART_DIR/auto_provider.txt.tmp" \
  || { log_error "failed to write auto_provider.txt"; exit 1; }
mv "$ART_DIR/auto_provider.txt.tmp" "$ART_DIR/auto_provider.txt" \
  || { log_error "failed to commit auto_provider.txt"; exit 1; }
log_info "  provider:   $AUTO_PROVIDER (auto-detected)"
```

The block uses the helper from Task 1 (already in `lib/deploy.sh`). The atomic write pattern (`.tmp` + `mv`) matches the convention used elsewhere in the codebase (e.g. `cw_status_write` in `lib/ipc.sh`).

- [ ] **Step 4: Run the test, confirm it PASSES**

```
cd /home/liupan/CC/clone-wars && bash tests/test_deploy_init.sh
```

Expected: existing PASS lines + 2 new PASS lines (codex auto_provider, claude auto_provider). Suite ends green.

- [ ] **Step 5: Commit**

```
cd /home/liupan/CC/clone-wars
git add bin/deploy-init.sh tests/test_deploy_init.sh
git commit -m "feat(deploy): wire auto-provider detection into deploy-init"
```

---

## Task 3: Update `bin/medic.sh` deploy-helpers-load probe

**Files:**
- Modify: `bin/medic.sh` (extend the existing 4d. probe to call the new detector)
- Modify: `tests/test_medic.sh` (no functional change but add an explanatory comment)

- [ ] **Step 1: Read the current probe block**

```
grep -n '4d\|cw_deploy_build_turn_prompt_round1' bin/medic.sh
```

Note the current shape (around lines 128-140 from v0.8). The probe currently chains `source` calls and ends with `cw_deploy_build_turn_prompt_round1 /a /b /c >/dev/null`.

- [ ] **Step 2: Extend the probe to also call the detector**

Read `bin/medic.sh` and find the existing `4d. deploy helpers source-load sanity` block. Modify the probe's chained `&&` to add the detector call:

```bash
# 4d. deploy helpers source-load sanity (turn-based deploy + provider detect).
if ( source "$PLUGIN_ROOT/lib/state.sh" \
     && source "$PLUGIN_ROOT/lib/log.sh" \
     && source "$PLUGIN_ROOT/lib/consult.sh" \
     && source "$PLUGIN_ROOT/lib/deploy.sh" \
     && cw_deploy_build_turn_prompt_round1 /a /b /c >/dev/null \
     && cw_deploy_detect_provider /tmp >/dev/null ) 2>/dev/null; then
  log_ok "deploy helpers load clean"
else
  log_warn "deploy helpers FAILED to load"
  warn=1
fi
```

(The `/tmp` arg is intentional — it's almost certainly missing `.claude-plugin/plugin.json`, so the detector will return `codex`. We don't care about the value here, only that the function loads and runs without error.)

- [ ] **Step 3: Run medic to verify the extended probe**

```
cd /home/liupan/CC/clone-wars && bash bin/medic.sh 2>&1 | grep -i 'deploy helpers'
```

Expected: `[ OK ]  deploy helpers load clean`.

- [ ] **Step 4: Run the medic test to confirm no regression**

```
cd /home/liupan/CC/clone-wars && bash tests/test_medic.sh
```

Expected: existing PASS lines preserved (10 from v0.8), no new failures.

- [ ] **Step 5: Add an explanatory comment to test_medic.sh**

Find the existing assertion `pass "medic deploy-helpers probe still clean after refactor"` in `tests/test_medic.sh`. Add a comment ABOVE that line explaining the extended probe coverage:

```bash
# Probe still passes after the refactor. As of v0.9 the probe ALSO smoke-tests
# cw_deploy_detect_provider; if that helper breaks, this assertion will catch it.
out=$(bash ../bin/medic.sh 2>&1) || true
echo "$out" | grep -q 'deploy helpers load clean' \
  || { echo "FAIL: medic deploy-helpers probe regressed" >&2; exit 1; }
pass "medic deploy-helpers probe still clean after refactor"
```

- [ ] **Step 6: Run the test again to confirm it still passes**

```
cd /home/liupan/CC/clone-wars && bash tests/test_medic.sh
```

Expected: same PASS count as before, all green.

- [ ] **Step 7: Commit**

```
cd /home/liupan/CC/clone-wars
git add bin/medic.sh tests/test_medic.sh
git commit -m "chore(medic): extend deploy-helpers probe to smoke-test detect_provider"
```

---

## Task 4: Update `commands/deploy.md` (Step 0 confirm + Step 1.1 spawn)

**Files:**
- Modify: `commands/deploy.md` (Step 0 read + AskUserQuestion + provider.txt write; Step 1.1 use `$PROVIDER`)

- [ ] **Step 1: Read the current directive shape**

```
cd /home/liupan/CC/clone-wars
sed -n '95,145p' commands/deploy.md
```

Note the boundary between Step 0 (init + audit) and Step 1.1 (spawn). The new logic inserts BETWEEN them.

- [ ] **Step 2: Add a provider-resolve block at the END of Step 0**

Find the line `Set task `0` → `completed`.` near the end of the current Step 0. INSERT the following block IMMEDIATELY BEFORE that line:

```markdown

8. Resolve trooper provider (auto-detect → confirm if claude):

   ```
   AUTO_PROVIDER=$(cat "$ART_DIR/auto_provider.txt")
   ```

   Branch on `$AUTO_PROVIDER`:

   - `codex` (or any unexpected value) → no prompt, just persist:
     ```
     PROVIDER=codex
     log_info "trooper provider: codex (auto-go)"
     ```
   - `claude` → AskUserQuestion (the cheap default isn't appropriate for
     plugin repos; ask the user before spending claude tokens):
     ```
     question: "This repo has .claude-plugin/plugin.json — Claude is the
       recommended trooper for plugin testing (it can load slash commands,
       run hooks, exercise the Claude Code surface natively). It will use
       claude tokens. Use claude or fall back to codex?"
     options:
       - "Use claude (recommended for plugin testing)"
       - "Fall back to codex (cheaper)"
     ```
     Set `PROVIDER` to `claude` if user picked "Use claude"; else `codex`.

   Atomically persist the final choice:
   ```
   printf '%s\n' "$PROVIDER" > "$ART_DIR/provider.txt.tmp"
   mv "$ART_DIR/provider.txt.tmp" "$ART_DIR/provider.txt"
   ```
```

- [ ] **Step 3: Update Step 1.1 to read `provider.txt` and use `$PROVIDER`**

Find the heading `### Step 1.1 — Spawn cody-codex`. Replace it with:

```markdown
### Step 1.1 — Spawn cody-$PROVIDER

Set task `1.1` → `in_progress`.
```
PROVIDER=$(cat "$ART_DIR/provider.txt")
"$CLAUDE_PLUGIN_ROOT/bin/spawn.sh" cody "$PROVIDER" "$TOPIC"
```
Set task `1.1` → `completed`. If spawn fails, archive `_deploy/` and exit.
```

- [ ] **Step 4: Sweep for hard-coded `cody-codex` references in the directive**

```
grep -n 'cody-codex\|cody codex' commands/deploy.md
```

For each match, decide:
- If it's a state-dir path reference (e.g. `<topic-state>/cody-codex/`), change to `<topic-state>/cody-<provider>/` or `cody-$PROVIDER` (whichever fits the surrounding context).
- If it's narrative prose like "the cody-codex pane", change to "the cody pane" — provider-agnostic.
- If it's the spawn line, that was already updated in Step 3 above.

Be careful NOT to change references inside the v0.7.0 / v0.8.0 design-doc commit messages or task tables that historically referenced cody-codex; we're rewriting the directive's runtime behavior, not erasing history.

- [ ] **Step 5: Update the TaskCreate row for Step 1.1**

Find the TaskCreate table at the top of `commands/deploy.md`. Update row `1.1`:

```markdown
| 1.1 | `1.1 Spawn cody (auto-provider) [yoda]`    | `Spawning cody-${PROVIDER}` |
```

(The activeForm uses `${PROVIDER}` shell-style so a Claude session reading the table will template it at runtime.)

- [ ] **Step 6: Run focused tests to confirm directive references stay coherent**

```
cd /home/liupan/CC/clone-wars
bash tests/test_deploy_helpers.sh
bash tests/test_deploy_init.sh
bash tests/test_medic.sh
```

Expected: each passes (no new failures from directive rewrite — the bin scripts and lib helpers are stable).

- [ ] **Step 7: Self-review**

- `grep -nE 'spawn.sh cody codex ' commands/deploy.md` should return nothing (no hard-coded codex spawn line).
- `grep -n 'auto_provider.txt' commands/deploy.md` should return at least one match (Step 0 reads it).
- `grep -n 'provider.txt' commands/deploy.md` should return at least one match (Step 0 writes it; Step 1.1 reads it).

- [ ] **Step 8: Commit**

```
cd /home/liupan/CC/clone-wars
git add commands/deploy.md
git commit -m "feat(deploy): auto-detect trooper provider with claude confirmation"
```

---

## Task 5: Add `tests/test_deploy_directive_provider.sh` static-wiring test

**Files:**
- Create: `tests/test_deploy_directive_provider.sh`

- [ ] **Step 1: Write the failing test (it'll fail until task 4 is committed, but the file should exist now for the test discovery flow)**

Create `tests/test_deploy_directive_provider.sh`:

```bash
#!/usr/bin/env bash
# tests/test_deploy_directive_provider.sh — static-wiring assertions
# for the v0.9 auto-provider directive flow. The directive's
# AskUserQuestion can't be exercised from a shell test; this catches
# the mechanical wiring (file refs, spawn variable usage).
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

D=../commands/deploy.md

# Auto file is read.
grep -q 'auto_provider.txt' "$D" \
  || { echo "FAIL: directive must reference auto_provider.txt" >&2; exit 1; }
pass "directive reads auto_provider.txt"

# Final-choice file is written + read.
grep -q 'provider.txt' "$D" \
  || { echo "FAIL: directive must reference provider.txt (final choice)" >&2; exit 1; }
pass "directive writes/reads provider.txt"

# AskUserQuestion appears near the provider block (within ~30 lines of auto_provider.txt).
auto_line=$(grep -n 'auto_provider.txt' "$D" | head -1 | cut -d: -f1)
ask_after=$(awk -v start="$auto_line" -v end="$((auto_line + 40))" \
  'NR>=start && NR<=end && /AskUserQuestion/ {print NR; exit}' "$D")
[[ -n "$ask_after" ]] \
  || { echo "FAIL: AskUserQuestion not found within 40 lines of auto_provider.txt read" >&2; exit 1; }
pass "directive asks user when claude is auto-detected"

# Spawn uses $PROVIDER, not hardcoded codex.
grep -qE 'spawn\.sh.*cody.*"?\$PROVIDER"?\b|spawn\.sh.*cody.*"\$\{PROVIDER\}"' "$D" \
  || { echo "FAIL: Step 1.1 spawn line must use \$PROVIDER variable" >&2; exit 1; }
pass "directive's spawn line uses \$PROVIDER variable"

# No leftover hard-coded codex in the spawn line (matches the literal command form,
# allowing matches inside the new provider-resolve block's prose).
if grep -qE '^\s*"\$CLAUDE_PLUGIN_ROOT/bin/spawn\.sh" cody codex ' "$D"; then
  echo "FAIL: leftover hard-coded 'spawn.sh cody codex' line in directive" >&2; exit 1
fi
pass "no leftover hard-coded 'cody codex' spawn line"

echo "ALL: ok"
```

```
chmod +x tests/test_deploy_directive_provider.sh
```

- [ ] **Step 2: Run the test, confirm it PASSES (assuming Task 4 was committed)**

```
cd /home/liupan/CC/clone-wars && bash tests/test_deploy_directive_provider.sh
```

Expected: 5 PASS lines, ends with `ALL: ok`. If FAIL, the issue is most likely in Task 4 — re-examine the directive edits.

- [ ] **Step 3: Run the full test suite to confirm no regression**

```
cd /home/liupan/CC/clone-wars && bash tests/run.sh 2>&1 | tail -10
```

Expected: same baseline (the known pre-existing test_consult_load_prompt_migration.sh fail) plus all other tests green, including the new directive-wiring test.

- [ ] **Step 4: Commit**

```
cd /home/liupan/CC/clone-wars
git add tests/test_deploy_directive_provider.sh
git commit -m "test(deploy): add static-wiring assertions for auto-provider directive"
```

---

## Task 6: Update manual dogfood gate

**Files:**
- Modify: `tests/test_deploy_v07_dogfood.sh` (add provider-selection scenario)

- [ ] **Step 1: Read the current dogfood script**

```
cat tests/test_deploy_v07_dogfood.sh
```

Note its structure (likely just an info-print + exit 0).

- [ ] **Step 2: Append a new scenario block**

Find the end of the existing `echo` block (before the final `echo "ALL: ok"` line). Append:

```bash
echo ""
echo "v0.9 auto-provider scenarios:"
echo "  4. cd into a non-plugin repo (no .claude-plugin/plugin.json)."
echo "     Run /clone-wars:deploy <design>. Confirm Step 0 picks codex"
echo "     WITHOUT prompting (auto-go). Inspect"
echo "     <topic-state>/_deploy/auto_provider.txt → 'codex'."
echo "     Inspect <topic-state>/_deploy/provider.txt → 'codex'."
echo "  5. cd into the clone-wars repo (has .claude-plugin/plugin.json)."
echo "     Run /clone-wars:deploy <design>. Confirm Step 0 raises an"
echo "     AskUserQuestion. Pick 'Use claude'. Confirm cody-claude pane"
echo "     spawns. auto_provider.txt='claude'; provider.txt='claude'."
echo "  6. Re-run scenario 5 with a fresh topic. Pick 'Fall back to codex'"
echo "     in the AskUserQuestion. Confirm cody-codex pane spawns."
echo "     auto_provider.txt='claude'; provider.txt='codex' (the override)."
echo ""
echo "If scenarios 4-6 pass, this gate is GREEN — flip the v0.9 release"
echo "checkbox in CLAUDE.md."
```

- [ ] **Step 3: Confirm the script still exits 0 cleanly**

```
cd /home/liupan/CC/clone-wars && bash tests/test_deploy_v07_dogfood.sh
echo "RC=$?"
```

Expected: prints the (now extended) info block, exits 0. The denylist in `tests/run.sh` still keeps it out of automated runs.

- [ ] **Step 4: Commit**

```
cd /home/liupan/CC/clone-wars
git add tests/test_deploy_v07_dogfood.sh
git commit -m "test(deploy): add v09 auto-provider scenarios to manual dogfood gate"
```

---

## Task 7: Final validation + CLAUDE.md status update

**Files:**
- Modify: `CLAUDE.md` (add v0.9.0 status entry)

- [ ] **Step 1: Run the full test suite**

```
cd /home/liupan/CC/clone-wars && bash tests/run.sh 2>&1 | tee /tmp/deploy-provider-final.log | tail -15
echo "EXIT_CODE=$?"
```

Expected: 1 known pre-existing failure (`test_consult_load_prompt_migration.sh` — drilldown path mismatch from v0.5.3, unrelated). Every other test PASS, including:
- `tests/test_deploy_helpers.sh` (now with 5 new detect_provider PASS lines)
- `tests/test_deploy_init.sh` (now with 2 new auto_provider PASS lines)
- `tests/test_deploy_directive_provider.sh` (5 PASS lines)
- `tests/test_medic.sh` (10 PASS lines, unchanged count)

If ANY OTHER test fails, investigate the regression and STOP. Do not commit until green.

- [ ] **Step 2: Run medic + confirm clean**

```
bash bin/medic.sh
```

Expected: `[ OK ]  deploy helpers load clean` (now smoke-tests both turn-prompt builder AND detect_provider). Verdict: OK.

- [ ] **Step 3: Confirm no leftover stale references**

```
cd /home/liupan/CC/clone-wars
grep -rn 'spawn\.sh cody codex \|cody-codex' commands/ 2>/dev/null
```

Expected: empty, OR matches only in narrative prose where "cody-codex" describes a *previous* codex run (not a current spawn instruction). If unsure, audit each match.

- [ ] **Step 4: Update `CLAUDE.md` status checklist**

Find the status checklist near the bottom of `CLAUDE.md` (look for `- [x] v0.8.0` and `- [ ] v0.8.0 strict-dogfood`). Append:

```markdown
- [x] v0.9.0: deploy auto-detects trooper provider (codex default; claude with confirmation when .claude-plugin/plugin.json present); cw_deploy_detect_provider helper + auto_provider.txt/provider.txt state files; medic probe extended; static-wiring test for the directive
- [ ] v0.9.0 strict-dogfood pass on a real machine (release gate — see tests/test_deploy_v07_dogfood.sh scenarios 4-6)
```

- [ ] **Step 5: Commit + final summary**

```
cd /home/liupan/CC/clone-wars
git add CLAUDE.md
git commit -m "docs(claude): mark v0.9.0 deploy auto-provider complete"
git log --oneline main..HEAD
```

Expected: 7 commits on the branch (one per task), all conventional-commits formatted.

---

## Self-review notes

- **Spec coverage:**
  - `cw_deploy_detect_provider` helper in `lib/deploy.sh` → Task 1
  - `bin/deploy-init.sh` writes `_deploy/auto_provider.txt` → Task 2
  - `commands/deploy.md` Step 0 reads + AskUserQuestion + writes `provider.txt` → Task 4
  - Step 1.1 spawn uses `$PROVIDER` → Task 4
  - Cross-reference sweep (no hardcoded `cody-codex`) → Task 4
  - `bin/medic.sh` deploy-helpers-load probe extension → Task 3
  - 5 new `cw_deploy_detect_provider` unit assertions → Task 1
  - 2 new `auto_provider.txt` integration assertions → Task 2
  - Static-wiring test → Task 5
  - Manual dogfood gate update → Task 6
  - `tests/run.sh` stays green (validation) → Task 7

- **Type / name consistency:** `cw_deploy_detect_provider`, `auto_provider.txt`, `provider.txt`, `$PROVIDER`, `$AUTO_PROVIDER`, `$REPO_ROOT` — used identically across all tasks.

- **No placeholders:** every step has explicit code or commands. Task 4's directive rewrite shows the exact markdown blocks to insert; the helper (Task 1) shows the full function body; the bin script edit (Task 2) shows the full insertion block.

- **Order safety:** Task 1 → Task 2 (helper exists before deploy-init.sh references it) → Task 3 (medic probe references both helpers) → Task 4 (directive references the state files written in Task 2) → Task 5 (test asserts directive content from Task 4) → Task 6 (dogfood gate doc) → Task 7 (validation + status). No task depends on a later task.
