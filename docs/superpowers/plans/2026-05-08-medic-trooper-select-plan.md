# Medic Trooper-Select Implementation Plan (v0.18.0)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an interactive trooper-selection flow to `/clone-wars:medic` that persists the user's chosen subset of detected providers in `$state_root/providers-active.txt`, with `bin/consult-init.sh` preferring the active set over the medic-detected set.

**Architecture:** Three thin component changes — (1) new `cw_active_providers_path` helper in `lib/state.sh` for path-precedence resolution; (2) one-line update at `bin/consult-init.sh:59` to consume the helper; (3) ~+60 lines of new directive prose in `commands/medic.md` that runs Steps A–G after the existing health-table render. `bin/medic.sh` stays mechanical — interactivity lives entirely on the Claude side.

**Tech Stack:** pure bash 4.2+, tmux ≥3.0, plain `tests/run.sh` test harness with `tests/lib/assert.sh` helpers. No npm, python, or external dependencies.

**Spec:** `docs/superpowers/specs/2026-05-08-medic-trooper-select-design.md` (committed `7bee43e` on `feat/v0.18.0-medic-trooper-select`).

**Codebase orientation (engineer who's never seen Clone Wars):**

- `bin/*.sh` are real shell scripts invoked by slash commands. `commands/*.md` are markdown directives Claude reads and uses to orchestrate Bash + Write + AskUserQuestion tool calls. The directive is interactive code; the bash script is mechanical code.
- `lib/state.sh` resolves paths under `$CLONE_WARS_HOME` (default `~/.clone-wars`). The functions of interest here are `cw_state_root` (returns the global root) and `cw_atomic_write` (used by bash for tmp+rename writes).
- `bin/consult-init.sh:59` is the single read site for `providers-available.txt` — that's where consult learns who's installed.
- `commands/medic.md` today has 6 numbered steps (resolve args path / write args / invoke `bin/medic.sh` / show output / FAIL summary / OK message). We append a new step for selection.
- Tests are independent bash scripts under `tests/` matching `test_*.sh`. Each sources `tests/lib/assert.sh` and uses `assert_contains`, `assert_file_exists`, `assert_eq`, `assert_exit`, plus `pass "<msg>"` on success. Run a single test with `bash tests/test_foo.sh`. Run the whole suite with `bash tests/run.sh`.

---

### Task 1: Verify branch state + capture baseline

**Files:** none modified — sanity check.

- [ ] **Step 1: Confirm you're on the feature branch**

Run: `git rev-parse --abbrev-ref HEAD`
Expected output: `feat/v0.18.0-medic-trooper-select`

- [ ] **Step 2: Confirm spec is committed**

Run: `git log --oneline -1 docs/superpowers/specs/2026-05-08-medic-trooper-select-design.md`
Expected output: `7bee43e docs(spec): v0.18.0 medic trooper-select design`

- [ ] **Step 3: Capture baseline test count for later comparison**

Run: `bash tests/run.sh 2>&1 | tail -3`
Expected: `PASS=N FAIL=0` (record N — every later task that adds tests should bump N upward).

---

### Task 2: Add `cw_active_providers_path` helper to `lib/state.sh`

**Files:**
- Modify: `lib/state.sh` (append helper at end of file, after line 121)
- Test: `tests/test_active_providers_path.sh` (new)

- [ ] **Step 1: Write the failing test**

Create `tests/test_active_providers_path.sh`:

```bash
#!/usr/bin/env bash
# tests/test_active_providers_path.sh
#
# v0.18.0: cw_active_providers_path returns providers-active.txt when it
# exists (user-selected roster); falls back to providers-available.txt
# (medic-detected) otherwise. Pure path resolution; does not validate
# contents.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

source ../lib/log.sh
source ../lib/state.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"
mkdir -p "$CLONE_WARS_HOME"

# Scenario 1: only providers-available.txt exists → returns that path.
echo codex > "$CLONE_WARS_HOME/providers-available.txt"
got=$(cw_active_providers_path)
assert_eq "$got" "$CLONE_WARS_HOME/providers-available.txt" \
  "fallback to providers-available.txt"

# Scenario 2: both files exist → returns providers-active.txt (preference wins).
echo claude > "$CLONE_WARS_HOME/providers-active.txt"
got=$(cw_active_providers_path)
assert_eq "$got" "$CLONE_WARS_HOME/providers-active.txt" \
  "providers-active.txt preferred when both exist"

# Scenario 3: only providers-active.txt exists (defensive — medic never ran)
# → returns providers-active.txt anyway.
rm "$CLONE_WARS_HOME/providers-available.txt"
got=$(cw_active_providers_path)
assert_eq "$got" "$CLONE_WARS_HOME/providers-active.txt" \
  "providers-active.txt returned when alone"

pass "cw_active_providers_path: precedence resolution works"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_active_providers_path.sh`
Expected: FAIL with `cw_active_providers_path: command not found` (helper doesn't exist yet).

- [ ] **Step 3: Add the helper to `lib/state.sh`**

Append at the end of `lib/state.sh` (after line 121, after `cw_repo_root`):

```bash

# cw_active_providers_path — canonical path the consult roster reads.
# Prefers providers-active.txt (user-selected via /clone-wars:medic) over
# providers-available.txt (medic-detected). Pure path resolution; does
# not validate contents — callers grep -vE '#' / blank as today.
#
# Used by bin/consult-init.sh and any future consumer that needs to know
# "which providers should /consult use right now".
cw_active_providers_path() {
  local sr; sr="$(cw_state_root)"
  if [[ -f "$sr/providers-active.txt" ]]; then
    printf '%s\n' "$sr/providers-active.txt"
  else
    printf '%s\n' "$sr/providers-available.txt"
  fi
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test_active_providers_path.sh`
Expected: `PASS: cw_active_providers_path: precedence resolution works`

- [ ] **Step 5: Run full suite to confirm no regressions**

Run: `bash tests/run.sh 2>&1 | tail -3`
Expected: `PASS=<N+1> FAIL=0` (one more than baseline).

- [ ] **Step 6: Commit**

```bash
git add lib/state.sh tests/test_active_providers_path.sh
git commit -m "$(cat <<'EOF'
feat(state): add cw_active_providers_path resolver

Returns providers-active.txt when present, falls back to
providers-available.txt otherwise. Single source of truth for the
"which providers should /consult use" precedence rule. Consumed by
bin/consult-init.sh in the next commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Wire `bin/consult-init.sh:59` to use the resolver

**Files:**
- Modify: `bin/consult-init.sh:58-64`
- Test: `tests/test_consult_init_prefers_active.sh` (new)

- [ ] **Step 1: Write the failing integration test**

Create `tests/test_consult_init_prefers_active.sh`:

```bash
#!/usr/bin/env bash
# tests/test_consult_init_prefers_active.sh
#
# v0.18.0: bin/consult-init.sh prefers providers-active.txt (user-
# selected) over providers-available.txt (medic-detected). Stage active
# as a strict subset of available; verify the resulting troopers.txt
# matches the active subset.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"
mkdir -p "$CLONE_WARS_HOME"

# Stage providers-available.txt with all 3 consult-eligible providers.
cat > "$CLONE_WARS_HOME/providers-available.txt" <<EOF
# generated by test
codex
claude
opencode
EOF

# Stage providers-active.txt as a strict subset (drop opencode).
cat > "$CLONE_WARS_HOME/providers-active.txt" <<EOF
# user selected
codex
claude
EOF

INIT="$(cd .. && pwd)/bin/consult-init.sh"
LIB="$(cd .. && pwd)/lib/state.sh"
RH=$(bash -c "source '$LIB'; cw_repo_hash")

TOPIC=$("$INIT" "v018 active subset wins")
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"

assert_file_exists "$TD/_consult/troopers.txt" "troopers.txt written"
TROOPERS_BODY=$(grep -vE '^[[:space:]]*(#|$)' "$TD/_consult/troopers.txt")
# Expect 2 rows (codex+claude), opencode dropped.
ROW_COUNT=$(echo "$TROOPERS_BODY" | wc -l)
assert_eq "$ROW_COUNT" "2" "active subset produces N=2 roster"

# Provider column (first column) must be codex + claude only.
echo "$TROOPERS_BODY" | grep -qE $'^codex\t'    || { echo "FAIL: codex row missing"     >&2; exit 1; }
echo "$TROOPERS_BODY" | grep -qE $'^claude\t'   || { echo "FAIL: claude row missing"    >&2; exit 1; }
echo "$TROOPERS_BODY" | grep -qE $'^opencode\t' && { echo "FAIL: opencode should not be in roster" >&2; exit 1; } || true

pass "bin/consult-init.sh prefers providers-active.txt over providers-available.txt"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_consult_init_prefers_active.sh`
Expected: FAIL — roster has 3 rows (active is ignored, all 3 from providers-available.txt are used).

- [ ] **Step 3: Read `bin/consult-init.sh` lines 58–64 to confirm the current code**

Run: `sed -n '58,64p' bin/consult-init.sh`
Expected output:

```
# v0.15.0: provider gate — read medic's remark.
PROVIDERS_FILE="$(cw_state_root)/providers-available.txt"
[[ -f "$PROVIDERS_FILE" ]] || {
  log_error "providers-available.txt not found at $PROVIDERS_FILE"
  log_error "run /clone-wars:medic first to detect installed providers."
  exit 2
}
```

- [ ] **Step 4: Edit `bin/consult-init.sh:58-64`**

Replace the block with:

```bash
# v0.18.0: provider gate — prefer providers-active.txt (user-selected
# via /clone-wars:medic) over providers-available.txt (medic-detected).
PROVIDERS_FILE="$(cw_active_providers_path)"
[[ -f "$PROVIDERS_FILE" ]] || {
  log_error "$PROVIDERS_FILE not found"
  log_error "run /clone-wars:medic first to detect installed providers."
  exit 2
}
```

The two changes: (1) `PROVIDERS_FILE` now comes from the resolver instead of a hard-coded path; (2) the error message uses `$PROVIDERS_FILE` directly so it accurately names whichever path the resolver returned.

- [ ] **Step 5: Run the integration test to verify it passes**

Run: `bash tests/test_consult_init_prefers_active.sh`
Expected: `PASS: bin/consult-init.sh prefers providers-active.txt over providers-available.txt`

- [ ] **Step 6: Run full suite to confirm no regressions**

Run: `bash tests/run.sh 2>&1 | tail -3`
Expected: `PASS=<N+2> FAIL=0` (two more than baseline).

- [ ] **Step 7: Commit**

```bash
git add bin/consult-init.sh tests/test_consult_init_prefers_active.sh
git commit -m "$(cat <<'EOF'
feat(consult-init): prefer providers-active.txt over providers-available.txt

Wires the cw_active_providers_path resolver into the v0.15.0 provider
gate. When the user has run /clone-wars:medic and picked an active
subset, consult-init now reads that file; otherwise it falls back to
providers-available.txt (today's behavior — back-compatible for users
who haven't yet exercised the v0.18 selection flow).

Error message at line 61 changed to "$PROVIDERS_FILE not found" so it
accurately names whichever path the resolver returned.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Add fallback regression test

**Files:**
- Test: `tests/test_consult_init_falls_back_to_available.sh` (new)

- [ ] **Step 1: Write the test**

Create `tests/test_consult_init_falls_back_to_available.sh`:

```bash
#!/usr/bin/env bash
# tests/test_consult_init_falls_back_to_available.sh
#
# v0.18.0 regression guard: when only providers-available.txt is
# present (no providers-active.txt — pre-v0.18 user, or user who
# hasn't run selection yet), bin/consult-init.sh's behavior is
# unchanged from v0.17.0.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"
mkdir -p "$CLONE_WARS_HOME"

# Stage only providers-available.txt — no providers-active.txt.
cat > "$CLONE_WARS_HOME/providers-available.txt" <<EOF
# generated by test
codex
claude
EOF

INIT="$(cd .. && pwd)/bin/consult-init.sh"
LIB="$(cd .. && pwd)/lib/state.sh"
RH=$(bash -c "source '$LIB'; cw_repo_hash")

TOPIC=$("$INIT" "v018 fallback regression")
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"

assert_file_exists "$TD/_consult/troopers.txt" "troopers.txt written"
TROOPERS_BODY=$(grep -vE '^[[:space:]]*(#|$)' "$TD/_consult/troopers.txt")
ROW_COUNT=$(echo "$TROOPERS_BODY" | wc -l)
assert_eq "$ROW_COUNT" "2" "all detected providers form the roster"

echo "$TROOPERS_BODY" | grep -qE $'^codex\t'  || { echo "FAIL: codex row missing"  >&2; exit 1; }
echo "$TROOPERS_BODY" | grep -qE $'^claude\t' || { echo "FAIL: claude row missing" >&2; exit 1; }

# Also verify providers-active.txt was NOT created as a side-effect.
[[ ! -f "$CLONE_WARS_HOME/providers-active.txt" ]] \
  || { echo "FAIL: providers-active.txt should not be auto-created" >&2; exit 1; }

pass "bin/consult-init.sh falls back to providers-available.txt when active is absent"
```

- [ ] **Step 2: Run the test to verify it passes immediately**

Run: `bash tests/test_consult_init_falls_back_to_available.sh`
Expected: `PASS: bin/consult-init.sh falls back to providers-available.txt when active is absent`

This test passes on the first run because the resolver already handles the absent-active case (Task 2 covered it). The test exists as a regression guard so future changes don't break the fallback.

- [ ] **Step 3: Run full suite**

Run: `bash tests/run.sh 2>&1 | tail -3`
Expected: `PASS=<N+3> FAIL=0`.

- [ ] **Step 4: Commit**

```bash
git add tests/test_consult_init_falls_back_to_available.sh
git commit -m "$(cat <<'EOF'
test(consult-init): regression guard for active-absent fallback

Locks in the v0.17.0 behavior: when providers-active.txt is absent,
consult-init reads providers-available.txt and uses every detected
provider as the roster. Catches future regressions to the resolver's
fallback branch.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Add stale-entry handling test

**Files:**
- Test: `tests/test_consult_init_handles_stale_active.sh` (new)

- [ ] **Step 1: Write the test**

Create `tests/test_consult_init_handles_stale_active.sh`:

```bash
#!/usr/bin/env bash
# tests/test_consult_init_handles_stale_active.sh
#
# v0.18.0: providers-active.txt may list a provider that's no longer
# consult-eligible (e.g. user uninstalled binary, or row removed from
# contracts.yaml). The existing cw_consult_eligible_providers filter
# drops the stale entry; consult-init proceeds with the surviving
# subset as long as N >= 2.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"
mkdir -p "$CLONE_WARS_HOME"

cat > "$CLONE_WARS_HOME/providers-available.txt" <<EOF
codex
claude
EOF

# Stage providers-active.txt with one stale entry ("gemini" is not in
# cw_consult_eligible_providers' allow-list of codex|claude|opencode).
cat > "$CLONE_WARS_HOME/providers-active.txt" <<EOF
codex
claude
gemini
EOF

INIT="$(cd .. && pwd)/bin/consult-init.sh"
LIB="$(cd .. && pwd)/lib/state.sh"
RH=$(bash -c "source '$LIB'; cw_repo_hash")

TOPIC=$("$INIT" "v018 stale entry filter")
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"

assert_file_exists "$TD/_consult/troopers.txt" "troopers.txt written"
TROOPERS_BODY=$(grep -vE '^[[:space:]]*(#|$)' "$TD/_consult/troopers.txt")
ROW_COUNT=$(echo "$TROOPERS_BODY" | wc -l)
assert_eq "$ROW_COUNT" "2" "stale entry filtered, 2 valid providers remain"

echo "$TROOPERS_BODY" | grep -qE $'^codex\t'  || { echo "FAIL: codex row missing"  >&2; exit 1; }
echo "$TROOPERS_BODY" | grep -qE $'^claude\t' || { echo "FAIL: claude row missing" >&2; exit 1; }
echo "$TROOPERS_BODY" | grep -qE $'^gemini\t' && { echo "FAIL: gemini should be filtered" >&2; exit 1; } || true

pass "bin/consult-init.sh filters stale entries from providers-active.txt"
```

- [ ] **Step 2: Run the test to verify it passes immediately**

Run: `bash tests/test_consult_init_handles_stale_active.sh`
Expected: `PASS: bin/consult-init.sh filters stale entries from providers-active.txt`

This passes on the first run because `cw_consult_eligible_providers` (in `lib/consult.sh:1169`) already filters non-allowlisted providers. The test locks in that the filter applies to the active file the same way it applied to the available file.

- [ ] **Step 3: Run full suite**

Run: `bash tests/run.sh 2>&1 | tail -3`
Expected: `PASS=<N+4> FAIL=0`.

- [ ] **Step 4: Commit**

```bash
git add tests/test_consult_init_handles_stale_active.sh
git commit -m "$(cat <<'EOF'
test(consult-init): handle stale providers-active.txt entries

Locks in that cw_consult_eligible_providers' allowlist filter applies
to providers-active.txt the same way it applies to
providers-available.txt — stale entries (e.g. a provider whose binary
has been uninstalled, or a row removed from contracts.yaml) are
silently filtered, and consult proceeds with the surviving subset.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Add Steps A–G interactive selection flow to `commands/medic.md`

**Files:**
- Modify: `commands/medic.md` (append a new "Trooper selection" section after step 6)
- Test: `tests/test_medic_directive_v018_static_wiring.sh` (new)

- [ ] **Step 1: Write the failing static-wiring test**

Create `tests/test_medic_directive_v018_static_wiring.sh`:

```bash
#!/usr/bin/env bash
# tests/test_medic_directive_v018_static_wiring.sh
#
# Static-wiring asserts on commands/medic.md: confirms the v0.18.0
# directive contains Steps A-G (interactive trooper selection),
# references providers-active.txt + providers-available.txt + Write
# tool + AskUserQuestion, and documents the stale-entry filter.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

DIR=../commands/medic.md
BODY=$(cat "$DIR")

# Step labels A-G must all appear.
for s in A B C D E F G; do
  grep -qE "^#### Step $s —" "$DIR" \
    || { echo "FAIL: missing '#### Step $s —' heading" >&2; exit 1; }
done

# Required references inside the new selection block.
assert_contains "$BODY" "providers-active.txt"  "directive references providers-active.txt"
assert_contains "$BODY" "providers-available.txt" "directive references providers-available.txt"
assert_contains "$BODY" "AskUserQuestion"        "directive uses AskUserQuestion"
assert_contains "$BODY" "Write tool"             "directive uses Write tool for atomic write"

# Stale-entry handling must be explicitly documented.
assert_contains "$BODY" "no longer detected"     "directive documents stale-entry filter"

# Empty-set guard must be explicit (Step F).
assert_contains "$BODY" "must select at least one provider" "directive documents empty-set guard"

# Auto-handle for N=0 and N=1 must be explicit (Step C).
assert_contains "$BODY" "auto-selected" "directive auto-handles N=1"

# Customize fallback path must exist for N=4.
assert_contains "$BODY" "Customize" "directive offers Customize fallback"

pass "commands/medic.md v0.18.0 static wiring complete"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_medic_directive_v018_static_wiring.sh`
Expected: FAIL — first missing-heading check trips on `#### Step A —`.

- [ ] **Step 3: Read the current commands/medic.md to locate the insertion point**

Run: `sed -n '50,53p' commands/medic.md`
Expected output:

```
6. If the verdict is `OK`, no further action is needed; the user is ready to spawn troopers
   (once the runtime commands ship in v0.0.1 — until then, `/clone-wars:spawn` etc. print
   stub messages).
```

The new section appends AFTER step 6 (i.e. at end of file).

- [ ] **Step 4: Append the new "Trooper selection" section to `commands/medic.md`**

Append to the end of `commands/medic.md`:

```markdown

## Trooper selection (v0.18.0)

After the health table renders (steps 1–6 above), interactively pick which
detected providers should be the active roster for `/clone-wars:consult`.
Selection persists at `$state_root/providers-active.txt` (global, one per
machine/install). `bin/consult-init.sh` prefers this file over
`providers-available.txt` when present; this is the user's "preference layer"
on top of medic's mechanical detection.

**Always-interactive policy:** every `/clone-wars:medic` invocation runs
Steps A–G. Whether the user actually sees an `AskUserQuestion` prompt
depends on the detected count (Step C — auto-handles 0 and 1, prompts
for 2+).

#### Step A — Read detected set

Use the Bash tool:

```
state_root="${CLONE_WARS_HOME:-$HOME/.clone-wars}"
grep -vE '^[[:space:]]*(#|$)' "$state_root/providers-available.txt" 2>/dev/null
```

Capture the result as `DETECTED` (one provider per line). If the file is
missing or unreadable, log `warn: providers-available.txt not found;
skipping trooper selection` and exit this section — Steps B–G are
skipped. (medic's existing FAIL handling has already surfaced the
underlying problem in step 5 above.)

#### Step B — Read prior selection if any

```
[[ -f "$state_root/providers-active.txt" ]] \
  && grep -vE '^[[:space:]]*(#|$)' "$state_root/providers-active.txt"
```

Capture the result as `PRIOR`. Filter `PRIOR` against `DETECTED` (drop
entries that are no longer detected — e.g. user uninstalled a binary
or the provider was removed from `contracts.yaml`). For each entry
dropped, print one line:

```
note: removed <provider> from active set (no longer detected)
```

If `PRIOR` is empty after filtering, treat it as no-prior for Steps D
and E (recommended option defaults switch from "keep current" to
"include all").

#### Step C — Decide whether to prompt

Branch on `DETECTED` count:

| Count | Behavior |
|---|---|
| `0`   | No prompt. medic already FAILed; nothing to choose. Skip Steps D–G. |
| `1`   | No prompt. Auto-write `providers-active.txt` with that one provider via Write tool. Print `auto-selected: <provider> (only detected provider)`. Skip Steps D–G. |
| `2`–`3` | Go to Step D (preset menu). |
| `4`   | Skip Step D (11+ subset options is too cluttered). Go directly to Step E (per-provider walk). |

#### Step D — Preset-subset menu (N=2 or N=3)

One `AskUserQuestion`. Build the options list from `DETECTED`, mapping
each provider to its commander via the lookup `codex → rex`,
`claude → cody`, `opencode → bly` (matches `cw_consult_provider_to_commander`
in `lib/consult.sh:1157`).

For **N=2** (`DETECTED = [A, B]`), 4 options:

- `Both <commander-A> + <commander-B>` (default recommended)
- `<commander-A> only`
- `<commander-B> only`
- `Customize…`

For **N=3** (`DETECTED = [A, B, C]`), 5 options:

- `All three (<commander-A> + <commander-B> + <commander-C>)` (default recommended)
- `<commander-A> + <commander-B>` (drop C)
- `<commander-A> + <commander-C>` (drop B)
- `<commander-B> + <commander-C>` (drop A)
- `Customize…`

If `PRIOR` matches one of the preset subsets exactly, relabel that
option to start with `Keep current selection (…)` and present it as
the recommended (top) option instead of the default "all".

User picks anything except `Customize…` → write `providers-active.txt`
via the Write tool with the chosen subset (one provider per line, in
the same order they appear in `DETECTED`). Skip Steps E and F. Go to
Step G's confirmation print.

User picks `Customize…` → fall through to Step E.

#### Step E — Per-provider walk (Customize, or N≥4)

For each provider in `DETECTED` (in order), one `AskUserQuestion` with
question `Include <commander> (<provider>)?` and 2 options:

- `Include`
- `Exclude`

Pre-select `Include` as the recommended option if the provider is in
`PRIOR` (after Step B's stale filter), OR if `PRIOR` is empty
(first-time selection). Otherwise `Exclude` is recommended.

After walking all providers, collect the included subset → `INCLUDED`.

#### Step F — Empty-set guard

If `INCLUDED` is empty (user excluded every provider), print:

```
error: must select at least one provider; selection unchanged
```

and exit this section. **Do not** write `providers-active.txt`. Prior
state is left intact (or absent if it didn't exist). Don't auto re-prompt;
the user can re-run `/clone-wars:medic` if they want another shot.

#### Step G — Atomic write

Use the **Write tool** to write `$state_root/providers-active.txt`.
File contents (replace tokens in angle brackets):

```
# generated <ISO-8601 UTC timestamp> by /clone-wars:medic
# active providers selected by user
<provider-1>
<provider-2>
…
```

Generate the timestamp with Bash: `date -u +%Y-%m-%dT%H:%M:%SZ`.

Print a confirmation line:

```
active set: <commander-A>, <commander-B> (written to providers-active.txt)
```

(Use commander names, not provider names, in the confirmation — matches
the AskUserQuestion option labels the user just saw.)
```

- [ ] **Step 5: Run the static-wiring test to verify it passes**

Run: `bash tests/test_medic_directive_v018_static_wiring.sh`
Expected: `PASS: commands/medic.md v0.18.0 static wiring complete`

- [ ] **Step 6: Run full suite**

Run: `bash tests/run.sh 2>&1 | tail -3`
Expected: `PASS=<N+5> FAIL=0`.

- [ ] **Step 7: Commit**

```bash
git add commands/medic.md tests/test_medic_directive_v018_static_wiring.sh
git commit -m "$(cat <<'EOF'
feat(medic): add interactive trooper-selection flow (Steps A-G)

Adds the v0.18.0 selection block to commands/medic.md. After the
health table renders, the directive reads providers-available.txt,
optionally compares against providers-active.txt (filtering stale
entries with note: lines), and walks the user through preset subsets
(N=2/3) or a per-provider Customize walk (N=4 / explicit choice).

bin/medic.sh stays mechanical — the prompt is Claude-side only,
matching every other interactive command in the codebase. Empty-set
guard refuses to write providers-active.txt when the user excludes
every detected provider.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Bump plugin version to 0.18.0

**Files:**
- Modify: `.claude-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json`

- [ ] **Step 1: Read current versions**

Run: `grep -nE '"version"' .claude-plugin/plugin.json .claude-plugin/marketplace.json`
Expected: each file should show `"version": "0.17.0"`.

- [ ] **Step 2: Update `.claude-plugin/plugin.json`**

Use the Edit tool to change the version line:

```
old_string: "version": "0.17.0"
new_string: "version": "0.18.0"
```

- [ ] **Step 3: Update `.claude-plugin/marketplace.json`**

Use the Edit tool. Replace `replace_all: true` since marketplace.json
may have multiple `"version": "0.17.0"` occurrences (one for each
embedded plugin entry). Confirm with `grep` first:

Run: `grep -c '"version": "0.17.0"' .claude-plugin/marketplace.json`
Expected: a count `>= 1`.

If count is 1, use a single Edit; if `> 1` and all should bump (verify
they're all clone-wars rows), use Edit with `replace_all: true`.

- [ ] **Step 4: Verify both files**

Run: `grep -nE '"version"' .claude-plugin/plugin.json .claude-plugin/marketplace.json`
Expected: no `"0.17.0"` remaining; all clone-wars version lines now `"0.18.0"`.

- [ ] **Step 5: Run full suite (no test changes, just regression check)**

Run: `bash tests/run.sh 2>&1 | tail -3`
Expected: `PASS=<N+5> FAIL=0` (unchanged from Task 6).

- [ ] **Step 6: Commit**

```bash
git add .claude-plugin/plugin.json .claude-plugin/marketplace.json
git commit -m "$(cat <<'EOF'
chore(release): bump plugin to v0.18.0

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Update CLAUDE.md status entries

**Files:**
- Modify: `CLAUDE.md` (Status section)

- [ ] **Step 1: Find the current last status entry**

Run: `grep -nE '^- \[[ x]\] v0\.1[78]' CLAUDE.md | tail -5`
Expected: the last lines are the v0.17.0 entries (one `[x]` for the
implemented work, one `[ ]` for the pending strict-dogfood release gate).

- [ ] **Step 2: Edit `CLAUDE.md` to add the v0.18.0 entries**

Use the Edit tool. Find the line:

```
- [ ] v0.17.0 strict-dogfood pass on a real machine (release gate — verify: ...)
```

Insert two new lines BELOW it (so v0.18.0 entries appear after v0.17.0
in chronological order). Show the lines surrounding the insertion to
make the Edit unambiguous:

```
old_string: - [ ] v0.17.0 strict-dogfood pass on a real machine (release gate — verify: (1) single-repo trivial fast-path produces 6-section deploy-audit-passing doc; (2) single-repo escalated path runs trooper roster + design walk; (3) multi-repo escalated path auto-detects sibling CLAUDE.md, asks AskUserQuestion to confirm targets, walks 8 sections with `**Target Sub-Project(s):**` header + soft DAG; (4) audit-fail recovery — Skip success-criteria → re-walk → audit PASS; (5) `--targets foo,bar <trivial topic>` forces escalation; (6) /clone-wars:deploy reads single-repo /consult output cleanly)
- [ ] v0.6: drop config/identity-template.md back-compat symlink + sweep tracer/*.sh + README.md legacy refs

new_string: - [ ] v0.17.0 strict-dogfood pass on a real machine (release gate — verify: (1) single-repo trivial fast-path produces 6-section deploy-audit-passing doc; (2) single-repo escalated path runs trooper roster + design walk; (3) multi-repo escalated path auto-detects sibling CLAUDE.md, asks AskUserQuestion to confirm targets, walks 8 sections with `**Target Sub-Project(s):**` header + soft DAG; (4) audit-fail recovery — Skip success-criteria → re-walk → audit PASS; (5) `--targets foo,bar <trivial topic>` forces escalation; (6) /clone-wars:deploy reads single-repo /consult output cleanly)
- [x] v0.18.0: medic trooper-select — `/clone-wars:medic` now runs interactive Steps A–G after the health table; user picks an active subset (preset N=2/3 menu or per-provider Customize walk for N=4); selection persists in `$state_root/providers-active.txt` and `bin/consult-init.sh` prefers it over `providers-available.txt`; new `cw_active_providers_path` resolver in `lib/state.sh` is the single source of truth for precedence; `bin/medic.sh` unchanged (interactivity is Claude-side only)
- [ ] v0.18.0 strict-dogfood pass on a real machine (release gate — verify: (1) all-providers detected → preset menu offers all subsets; (2) Customize walk per-provider; (3) selection persists across medic re-runs; (4) /consult uses active subset; (5) stale provider entry filtered with note: line; (6) empty-selection guard refuses write)
- [ ] v0.6: drop config/identity-template.md back-compat symlink + sweep tracer/*.sh + README.md legacy refs
```

- [ ] **Step 3: Verify the insertion**

Run: `grep -nE '^- \[[ x]\] v0\.1[78]' CLAUDE.md`
Expected: two v0.17.0 lines + two v0.18.0 lines, in that order.

- [ ] **Step 4: Run full suite**

Run: `bash tests/run.sh 2>&1 | tail -3`
Expected: `PASS=<N+5> FAIL=0` (unchanged).

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md
git commit -m "$(cat <<'EOF'
docs(claude): record v0.18.0 medic trooper-select status

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Final green-light + push branch

**Files:** none modified.

- [ ] **Step 1: Run the full test suite one more time**

Run: `bash tests/run.sh 2>&1 | tail -3`
Expected: `PASS=<N+5> FAIL=0` where N is the baseline from Task 1 Step 3.

If FAIL > 0 — read the failing test, fix the underlying issue (do NOT
delete or skip the test), re-run, and commit the fix as
`fix(<area>): <what>` before proceeding.

- [ ] **Step 2: Inspect the commit log on this branch**

Run: `git log --oneline main..HEAD`
Expected: 7 commits (from Task 2 through Task 8) ending with
`docs(claude): record v0.18.0 medic trooper-select status`.

If you have a different number of commits, that's fine — what matters
is that each task's commit lands cleanly and the suite is green at
HEAD. (The spec commit `7bee43e` is already on the branch from
brainstorming and is NOT counted here.)

- [ ] **Step 3: Push the branch**

Run: `git push -u origin feat/v0.18.0-medic-trooper-select`
Expected: `* [new branch] feat/v0.18.0-medic-trooper-select -> feat/v0.18.0-medic-trooper-select`.

If the branch already has commits on origin from a prior partial run,
use a regular push without `--force`; if it was force-pushed by an
earlier orchestrator, ask the user before deciding whether to
fast-forward.

- [ ] **Step 4: Open the PR (only if user has previously authorized PR creation)**

If the user has explicitly asked you to open the PR, run:

```bash
gh pr create --title "v0.18.0: medic trooper-select" --body "$(cat <<'EOF'
## Summary
- Adds interactive trooper-selection flow to `/clone-wars:medic` — Steps A–G run after the health table; user picks active subset via preset menu (N=2/3) or per-provider Customize walk (N=4).
- Persists choice in `$state_root/providers-active.txt`; `bin/consult-init.sh` prefers active over available via new `cw_active_providers_path` resolver.
- `bin/medic.sh` unchanged — interactivity is Claude-side only, matching every other interactive command.

## Test plan
- [ ] `bash tests/run.sh` passes locally (PASS+5 over baseline)
- [ ] Strict-dogfood pass per CLAUDE.md release gate (6 scenarios)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

If the user has NOT authorized PR creation, stop after Step 3 and tell
them the branch is pushed and ready for review.

---

## Self-review notes (for plan author, not implementer)

Spec coverage check (each spec section maps to a task):

| Spec section | Task |
|---|---|
| Architecture (3 thin changes) | Task 2 (lib/state.sh), Task 3 (consult-init.sh), Task 6 (commands/medic.md) |
| Selection flow Steps A–G | Task 6 (directive prose verbatim) |
| Components → `lib/state.sh` | Task 2 |
| Components → `bin/consult-init.sh:59` | Task 3 |
| Components → `commands/medic.md` | Task 6 |
| Components → `bin/medic.sh` (unchanged) | n/a — verified by lack of edits |
| Error handling (10 rows) | Step F (Task 6, empty-set), stale-entry note (Task 6, Step B), fallback (Task 4), atomic Write (Task 6, Step G) |
| Testing → `test_active_providers_path.sh` | Task 2 |
| Testing → `test_consult_init_prefers_active.sh` | Task 3 |
| Testing → `test_consult_init_falls_back_to_available.sh` | Task 4 |
| Testing → `test_consult_init_handles_stale_active.sh` | Task 5 |
| Testing → `test_medic_directive_v018_static_wiring.sh` | Task 6 |
| Versioning (plugin/marketplace bump + CLAUDE.md) | Task 7 + Task 8 |

No spec gaps detected. No orphan tasks. Type/identifier consistency:
`cw_active_providers_path` is the helper name in Task 2, Task 3, and
Task 6 — verified.
