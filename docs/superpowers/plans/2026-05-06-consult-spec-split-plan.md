# /clone-wars:consult + /spec Split — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split monolithic `/clone-wars:consult` at the design-doc-walk seam into `/clone-wars:consult` (research → synthesis → optional drill-deeper → teardown) and `/clone-wars:spec` (conductor-only design-doc walk that consumes a synthesis seed and commits a spec).

**Architecture:** Pure topology change. Pre-Step-8.5 chain stays in `/consult` byte-identical. Step 8.5 lifts wholesale into `/spec` minus the drill-deeper sub-loop. Drill-deeper relocates to a new pre-teardown Step 8.4 in `/consult` where troopers are still alive. `bin/consult-design-doc.sh` renames to `bin/spec-assemble.sh`. `lib/consult-*.sh` files stay put (shared by both commands).

**Tech Stack:** bash 4.2+, tmux, file IPC under `~/.clone-wars/{state,archive}/`, JSONL outboxes, markdown directives parsed by Claude Code's slash-command renderer.

**Spec:** `docs/superpowers/specs/2026-05-06-consult-spec-split-design.md`

---

## File Structure

**Create:**
- `bin/spec-init.sh` — resolve seed path (explicit > archive scan > active state > refuse); echo `TOPIC=` + `SEED=`.
- `commands/spec.md` — 7-step directive (resolve / detect mode / walk sections / assemble / commit / user-review / done).
- `tests/test_spec_init_source_defaulting.sh` — explicit path / archive scan / refuse paths.
- `tests/test_spec_directive_static_wiring.sh` — `commands/spec.md` references `bin/spec-init.sh` and `bin/spec-assemble.sh`; never references `bin/spawn.sh`.
- `tests/test_consult_step84_drilldown_wiring.sh` — `commands/consult.md` Step 8.4 invokes `bin/consult-drilldown.sh` with `_consult/drilldowns/` path.
- `tests/test_consult_design_doc_flag_deprecated.sh` — `--design-doc` flag prints deprecation warning and does NOT enter walk.

**Rename:**
- `bin/consult-design-doc.sh` → `bin/spec-assemble.sh` (pure rename; same behavior).
- `tests/test_consult_design_doc_assemble_single_unchanged.sh` → `tests/test_spec_assemble_single_unchanged.sh` (sacred byte-equality baseline preserved).

**Modify:**
- `commands/consult.md` — delete Step 8.5 (lines ~497-737); add new Step 8.4 (drill-deeper loop) between current Step 8 and Step 9; make Step 9 unconditional (drop "if Step 8.5 ran, skip" branch); add `--design-doc` deprecation warning in Step 0.
- `.claude-plugin/plugin.json` — version 0.11.2 → 0.12.0.
- `CLAUDE.md` — add v0.12.0 status line.

**Untouched (shared by both commands):**
- `lib/consult.sh`, `lib/consult-prompts.sh`, `lib/consult-validators.sh`, `lib/consult-hub.sh`.
- `bin/consult-{init,research-send,research-wait,verify-send,verify-wait,diff,adjudicate,synthesize,drilldown,teardown,archive,offset-reset}.sh`.

---

## Task 1: Create `bin/spec-init.sh` + source-defaulting test

**Files:**
- Create: `bin/spec-init.sh`
- Test: `tests/test_spec_init_source_defaulting.sh`

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# tests/test_spec_init_source_defaulting.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"
export CLAUDE_PLUGIN_ROOT="$(cd .. && pwd)"
source ../lib/state.sh
REPO_HASH=$(cw_repo_hash)

# Case 1: explicit valid path → echoes TOPIC + SEED.
SEED1="$TMP/explicit-synthesis.md"
mkdir -p "$TMP/state/$REPO_HASH/topic-explicit/_consult"
ARCHIVED1="$TMP/cw/state/$REPO_HASH/topic-explicit/_consult/synthesis.md"
mkdir -p "$(dirname "$ARCHIVED1")"
echo "## Synthesis" > "$ARCHIVED1"
OUT=$(../bin/spec-init.sh "$ARCHIVED1")
echo "$OUT" | grep -q '^TOPIC=topic-explicit$' || { echo "FAIL: explicit path TOPIC wrong: $OUT" >&2; exit 1; }
echo "$OUT" | grep -q "^SEED=$ARCHIVED1$" || { echo "FAIL: explicit path SEED wrong: $OUT" >&2; exit 1; }
pass "explicit seed path resolves topic + seed"

# Case 2: no arg, archive scan finds most recent.
mkdir -p "$CLONE_WARS_HOME/archive/$REPO_HASH/topic-archived/_consult"
echo "## Synthesis" > "$CLONE_WARS_HOME/archive/$REPO_HASH/topic-archived/_consult/synthesis.md"
sleep 1  # ensure mtime distinct
mkdir -p "$CLONE_WARS_HOME/archive/$REPO_HASH/topic-newer/_consult"
echo "## Synthesis" > "$CLONE_WARS_HOME/archive/$REPO_HASH/topic-newer/_consult/synthesis.md"
OUT=$(../bin/spec-init.sh)
echo "$OUT" | grep -q '^TOPIC=topic-newer$' || { echo "FAIL: archive-scan TOPIC wrong: $OUT" >&2; exit 1; }
pass "no-arg defaulting picks most recent archived synthesis"

# Case 3: no arg + no synthesis anywhere → exit 1.
rm -rf "$CLONE_WARS_HOME/archive" "$CLONE_WARS_HOME/state"
../bin/spec-init.sh && RC=0 || RC=$?
[[ "$RC" -eq 1 ]] || { echo "FAIL: empty state should exit 1, got $RC" >&2; exit 1; }
pass "no seed anywhere → exit 1"

# Case 4: explicit nonexistent path → exit 1.
../bin/spec-init.sh "$TMP/nope.md" && RC=0 || RC=$?
[[ "$RC" -eq 1 ]] || { echo "FAIL: nonexistent explicit path should exit 1, got $RC" >&2; exit 1; }
pass "explicit nonexistent path → exit 1"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_spec_init_source_defaulting.sh`
Expected: FAIL — `bin/spec-init.sh` does not exist.

- [ ] **Step 3: Implement `bin/spec-init.sh`**

```bash
#!/usr/bin/env bash
# bin/spec-init.sh — resolve seed path and topic for /clone-wars:spec.
# Usage: spec-init.sh [<seed.md>]
#   With arg:   validate file exists, echo "TOPIC=<extracted>\nSEED=<resolved-abs>"
#   Without:    scan archive (then state) for most-recent _consult/synthesis.md
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$SCRIPT_DIR/../lib/state.sh"

SEED="${1:-}"
if [[ -n "$SEED" ]]; then
  [[ -f "$SEED" ]] || { echo "FAIL: seed not found: $SEED" >&2; exit 1; }
  SEED=$(readlink -f "$SEED")
else
  REPO_HASH=$(cw_repo_hash)
  STATE_ROOT="${CLONE_WARS_HOME:-$HOME/.clone-wars}"
  SEED=$(find "$STATE_ROOT/archive/$REPO_HASH" "$STATE_ROOT/state/$REPO_HASH" \
              -path '*/_consult/synthesis.md' -type f -printf '%T@ %p\n' 2>/dev/null \
         | sort -n | tail -1 | cut -d' ' -f2-)
  [[ -n "$SEED" ]] || { echo "FAIL: no synthesis.md found; pass an explicit path" >&2; exit 1; }
fi

TOPIC=$(basename "$(dirname "$(dirname "$SEED")")")
[[ -n "$TOPIC" && "$TOPIC" != "/" ]] || { echo "FAIL: cannot extract topic from $SEED" >&2; exit 1; }

printf 'TOPIC=%s\nSEED=%s\n' "$TOPIC" "$SEED"
```

Then: `chmod +x bin/spec-init.sh`

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_spec_init_source_defaulting.sh`
Expected: PASS — all 4 cases green.

- [ ] **Step 5: Commit**

```bash
git add bin/spec-init.sh tests/test_spec_init_source_defaulting.sh
git commit -m "feat(spec): add bin/spec-init.sh source-defaulting

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Rename `bin/consult-design-doc.sh` → `bin/spec-assemble.sh`

**Files:**
- Rename: `bin/consult-design-doc.sh` → `bin/spec-assemble.sh`
- Rename: `tests/test_consult_design_doc_assemble_single_unchanged.sh` → `tests/test_spec_assemble_single_unchanged.sh`
- Modify: any internal references in `lib/`, other tests, `commands/consult.md` (will be modified again in Task 4).

- [ ] **Step 1: Identify all references**

Run: `grep -rn 'consult-design-doc\.sh' --include='*.sh' --include='*.md' . | grep -v '\.git/'`
Expected: list of files needing update.

- [ ] **Step 2: Rename the bin script**

```bash
git mv bin/consult-design-doc.sh bin/spec-assemble.sh
```

- [ ] **Step 3: Rename the test**

```bash
git mv tests/test_consult_design_doc_assemble_single_unchanged.sh tests/test_spec_assemble_single_unchanged.sh
```

- [ ] **Step 4: Update internal references**

For each file in step 1's grep output (excluding the renamed pair itself), replace `consult-design-doc.sh` with `spec-assemble.sh`. For `commands/consult.md`, this only matters until Task 4 deletes Step 8.5 entirely — but do it now to keep intermediate commits green.

- [ ] **Step 5: Update test harness**

Run: `bash tests/run.sh`
Expected: all tests pass; `test_spec_assemble_single_unchanged.sh` produces byte-equal output to the v0.10 baseline.

If the byte-equality test fails, revert the rename — there must be a hidden coupling that needs separate fixing first.

- [ ] **Step 6: Commit**

```bash
git add bin/spec-assemble.sh tests/test_spec_assemble_single_unchanged.sh \
        $(git diff --name-only HEAD)  # any files updated for references
git commit -m "refactor(spec): rename consult-design-doc.sh → spec-assemble.sh

Pure rename; behavior + output preserved. Sacred byte-equality baseline
test_spec_assemble_single_unchanged.sh still green.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Create `commands/spec.md` directive

**Files:**
- Create: `commands/spec.md`
- Test: `tests/test_spec_directive_static_wiring.sh`

- [ ] **Step 1: Write the failing wiring test**

```bash
#!/usr/bin/env bash
# tests/test_spec_directive_static_wiring.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

DIR=../commands/spec.md
[[ -f "$DIR" ]] || { echo "FAIL: $DIR missing" >&2; exit 1; }

grep -q 'bin/spec-init.sh'      "$DIR" || { echo "FAIL: directive missing bin/spec-init.sh reference" >&2; exit 1; }
grep -q 'bin/spec-assemble.sh'  "$DIR" || { echo "FAIL: directive missing bin/spec-assemble.sh reference" >&2; exit 1; }
! grep -q 'bin/spawn.sh'         "$DIR" || { echo "FAIL: /spec must NOT spawn troopers; spawn.sh referenced" >&2; exit 1; }
! grep -q 'consult-research-send' "$DIR" || { echo "FAIL: /spec must NOT dispatch research" >&2; exit 1; }
! grep -q 'consult-verify-send'   "$DIR" || { echo "FAIL: /spec must NOT dispatch verify" >&2; exit 1; }
grep -q 'cw_consult_design_doc_resume_state' "$DIR" || { echo "FAIL: directive missing resume-state helper" >&2; exit 1; }
grep -q 'hub-mode.txt'           "$DIR" || { echo "FAIL: directive missing hub-mode detection" >&2; exit 1; }
pass "commands/spec.md static wiring complete"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_spec_directive_static_wiring.sh`
Expected: FAIL — `commands/spec.md` does not exist.

- [ ] **Step 3: Write `commands/spec.md`**

Lift Step 8.5's section-walk loop verbatim from `commands/consult.md` (current lines 497-737), MINUS the drill-deeper sub-loop (entire "Drill-down sub-loop" block including the `consult-drilldown.sh` invocations). Replace the per-section AskUserQuestion options with `Approve / Revise / Skip` (no "Drill deeper").

Wrap with the new Steps 0-6 from the spec's "commands/spec.md" section. Source-defaulting in Step 0 calls `bin/spec-init.sh`. Step 1 reads `_consult/hub-mode.txt` from the archived `$TOPIC` dir. Step 2 is the section walk. Step 3 invokes `bin/spec-assemble.sh "$CONSULT_TOPIC"`. Step 4 is implicit in spec-assemble.sh (commit happens there). Step 5 is the verbatim brainstorming-skill user-review gate. Step 6 prints the final committed path.

The full directive should be ~150-200 lines (compact compared to the 250-line Step 8.5 section being lifted, because trooper drill-deeper paths are gone).

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_spec_directive_static_wiring.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add commands/spec.md tests/test_spec_directive_static_wiring.sh
git commit -m "feat(spec): add /clone-wars:spec directive

Conductor-only design-doc walk lifted from /consult Step 8.5 minus the
drill-deeper sub-loop. Reads synthesis.md + adjudicated.md + findings.md +
verify.md + hub-mode.txt + targets.txt + drilldowns/*.md from archive.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Add Step 8.4 (drill-deeper) to `commands/consult.md`

**Files:**
- Modify: `commands/consult.md` (insert new Step 8.4 between current Step 8 and Step 9)
- Test: `tests/test_consult_step84_drilldown_wiring.sh`

- [ ] **Step 1: Write the failing wiring test**

```bash
#!/usr/bin/env bash
# tests/test_consult_step84_drilldown_wiring.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

DIR=../commands/consult.md
grep -q 'Step 8.4'                    "$DIR" || { echo "FAIL: Step 8.4 header missing" >&2; exit 1; }
grep -q 'drill deeper before tearing' "$DIR" || { echo "FAIL: Step 8.4 prompt missing" >&2; exit 1; }
grep -q '_consult/drilldowns'         "$DIR" || { echo "FAIL: Step 8.4 must use _consult/drilldowns/ path" >&2; exit 1; }
grep -q 'bin/consult-drilldown.sh'    "$DIR" || { echo "FAIL: Step 8.4 must invoke consult-drilldown.sh" >&2; exit 1; }
# Step 8.4 must be BEFORE Step 9 (teardown).
LINE_84=$(grep -n '^### Step 8.4' "$DIR" | head -1 | cut -d: -f1)
LINE_9=$(grep -n '^### Step 9' "$DIR" | head -1 | cut -d: -f1)
[[ -n "$LINE_84" && -n "$LINE_9" && "$LINE_84" -lt "$LINE_9" ]] || \
  { echo "FAIL: Step 8.4 must precede Step 9 (got 8.4=$LINE_84 9=$LINE_9)" >&2; exit 1; }
pass "Step 8.4 drilldown wiring complete + ordered before teardown"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_consult_step84_drilldown_wiring.sh`
Expected: FAIL — Step 8.4 not present in directive.

- [ ] **Step 3: Insert Step 8.4 into `commands/consult.md`**

After the Step 8 section ends (synthesis printed, task `3.1` → `completed`), before the current Step 8.5 block (which Task 5 will delete), insert:

````markdown
### Step 8.4 — Drill deeper (optional)

Before teardown, offer one or more free-form drill-deeper rounds while
troopers are still alive. Each round writes to
`$TOPIC_DIR/_consult/drilldowns/_scratch/drilldown-<slug>-<commander>.md`
(slug = lowercased drill topic with spaces as hyphens).

```
DRILL_DIR="$TOPIC_DIR/_consult/drilldowns"
mkdir -p "$DRILL_DIR"
```

`AskUserQuestion`: "Any aspect to drill deeper before tearing down? (panes still live)"
Options: `Yes — drill` / `No — proceed to teardown`.

Note: Step 8.4 drops the per-sub-project trooper-options expansion that
old Step 8.5 had (rex on $SP / cody on $SP). For hub-mode users: include
the sub-project name in the `$DRILL_TOPIC` if you want to scope the
drill to one leaf (e.g., "auth in backend"). Yoda will route this through
the prose-context the trooper sees.

Loop while user picks "Yes":

1. `AskUserQuestion`: "Drill subject?" — free-form text. → `$DRILL_TOPIC=<response>`
2. `AskUserQuestion`: "Focus angle? (e.g., 'tradeoffs feel hand-wavy')" — free-form. → `$DRILL_FOCUS=<response>`
3. `AskUserQuestion`: "Which trooper?" Options: `rex (codex)` / `cody (claude)` / `both (parallel)`. → `$DRILL_TROOPER=<choice>`
4. Invoke:
   ```
   "$CLAUDE_PLUGIN_ROOT/bin/consult-drilldown.sh" \
     "$CONSULT_TOPIC" "$DRILL_TOPIC" "$DRILL_DIR" "$DRILL_FOCUS" \
     <commander+model selections>
   ```
5. Read produced files under `$DRILL_DIR/_scratch/` (one or two of
   `drilldown-<slug>-{rex,cody}.md`) and print summary to user.
5b. If `rc=1` (all troopers timed out / errored), `AskUserQuestion`:
    "Drill returned no findings. Retry / Different trooper / Skip and continue?"
6. `AskUserQuestion`: "Drill another aspect?" Options: `Yes` / `No — proceed to teardown`.

Drilldowns are part of the archive and become available to `/clone-wars:spec`.
````

Save.

- [ ] **Step 4: Run wiring test**

Run: `bash tests/test_consult_step84_drilldown_wiring.sh`
Expected: PASS.

- [ ] **Step 5: Run full suite to verify no regression**

Run: `bash tests/run.sh`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add commands/consult.md tests/test_consult_step84_drilldown_wiring.sh
git commit -m "feat(consult): add Step 8.4 free-form drill-deeper before teardown

Drill-deeper relocates from per-section (old Step 8.5) to free-form
pre-teardown. Outputs go to _consult/drilldowns/ (was design-doc/_scratch/),
become part of the archive for /clone-wars:spec to consume.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Remove Step 8.5 from `commands/consult.md`; make Step 9 unconditional

**Files:**
- Modify: `commands/consult.md`

- [ ] **Step 1: Identify Step 8.5 boundaries**

Run:
```bash
grep -n '^### Step 8\.5\|^### Step 9' commands/consult.md
```
Expected: prints `### Step 8.5` and `### Step 9` line numbers.

- [ ] **Step 2: Delete Step 8.5 section**

Use Edit tool to remove the entire `### Step 8.5 — Design-doc walk (optional)` block from its header through the line immediately before `### Step 9`. Also remove the line in Step 0 that says `Persist $DESIGN_DOC for Step 8.5.` and the inline `(downstream Step 8.5 picks it up)` comment in the targets-handling section.

Also remove from the task-list table:
- Row `3.1.5 Design-doc walk (optional) [yoda]` — entire row.
- The two task-status statements about `3.1.5` later in the directive.

- [ ] **Step 3: Make Step 9 unconditional**

In `### Step 9 — Teardown + archive`, delete the conditional block:

> `If Step 8.5 ran, teardown + archive already happened before the user-review gate. Skip this step. Otherwise (no design-doc walk):`

Replace with: just the unconditional teardown + archive commands. Step 9 always runs.

- [ ] **Step 4: Run static wiring tests for both directives**

Run:
```bash
bash tests/test_consult_step84_drilldown_wiring.sh && \
bash tests/test_consult_spawn_rollback.sh && \
bash tests/test_consult_lib_shim_sources_all.sh && \
bash tests/test_consult_load_prompt_migration.sh && \
bash tests/test_consult_slug_regex_constant.sh
```
Expected: all pass.

- [ ] **Step 5: Run full test suite**

Run: `bash tests/run.sh`
Expected: all tests pass. The byte-equality `test_spec_assemble_single_unchanged.sh` still green (assemble script unchanged; only its caller moved).

- [ ] **Step 6: Commit**

```bash
git add commands/consult.md
git commit -m "feat(consult): remove Step 8.5 design-doc walk (moved to /spec)

Step 8.5 lifted into commands/spec.md in the prior task. /consult now
terminates at synthesis + optional Step 8.4 drill-deeper + unconditional
Step 9 teardown.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Add `--design-doc` deprecation warning to `commands/consult.md`

**Files:**
- Modify: `commands/consult.md` Step 0
- Test: `tests/test_consult_design_doc_flag_deprecated.sh`

- [ ] **Step 1: Write the failing wiring test**

```bash
#!/usr/bin/env bash
# tests/test_consult_design_doc_flag_deprecated.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

DIR=../commands/consult.md

# v0.12 deprecation path: warning is present, walk-entry is gone.
grep -q 'deprecated as of v0.12.0'                 "$DIR" || { echo "FAIL: missing v0.12 deprecation notice" >&2; exit 1; }
grep -q 'Run /clone-wars:spec separately'          "$DIR" || { echo "FAIL: missing /spec migration hint" >&2; exit 1; }
! grep -q '^### Step 8\.5'                         "$DIR" || { echo "FAIL: Step 8.5 must be removed" >&2; exit 1; }
! grep -q 'cw_consult_design_doc_resume_state'     "$DIR" || { echo "FAIL: design-doc resume helper must be removed from /consult" >&2; exit 1; }
pass "/consult --design-doc deprecation wiring complete"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_consult_design_doc_flag_deprecated.sh`
Expected: FAIL — deprecation notice not present yet.

- [ ] **Step 3: Modify Step 0's `--design-doc` parsing**

In the Step 0 token-aware flag-parsing section, after `cw_consult_parse_design_doc_flag` extracts `$DESIGN_DOC`, append a deprecation branch:

```
if [[ "$DESIGN_DOC" == "1" ]]; then
  log_warn "--design-doc is deprecated as of v0.12.0. Run /clone-wars:spec separately after consult finishes."
fi
```

(Keep the parsing helper itself — backwards compatibility for any downstream test fixtures that still pass the flag. The flag is stripped from `$ARG_RAW` either way, so the rest of the directive is unaffected.)

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_consult_design_doc_flag_deprecated.sh`
Expected: PASS.

- [ ] **Step 5: Run full suite**

Run: `bash tests/run.sh`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add commands/consult.md tests/test_consult_design_doc_flag_deprecated.sh
git commit -m "feat(consult): deprecate --design-doc flag (moved to /spec in v0.12)

Flag still parses cleanly (back-compat) but emits a deprecation log_warn
and does NOT enter any walk. Migration: run /clone-wars:spec separately.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Plugin metadata + version bump

**Files:**
- Modify: `.claude-plugin/plugin.json` (version 0.11.2 → 0.12.0)
- Modify: `.claude-plugin/marketplace.json` (if it lists the version)

- [ ] **Step 1: Bump plugin version**

Edit `.claude-plugin/plugin.json`: change `"version": "0.11.2"` to `"version": "0.12.0"`.

- [ ] **Step 2: Check marketplace.json for version pin**

Run: `grep -n '0\.11\.2\|"version"' .claude-plugin/marketplace.json`

If a version is listed there, update it to `0.12.0` consistently.

- [ ] **Step 3: Verify**

```bash
grep '"version"' .claude-plugin/plugin.json
# Expected: "version": "0.12.0"
```

- [ ] **Step 4: Commit**

```bash
git add .claude-plugin/plugin.json $(git diff --name-only .claude-plugin/)
git commit -m "chore(release): bump plugin to v0.12.0

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: CLAUDE.md status line + commands inventory update

**Files:**
- Modify: `CLAUDE.md` (status section + Commands section)

- [ ] **Step 1: Update Commands section**

If the "Commands" section enumerates user-facing commands (`medic`/`consult`/`deploy`/`list`/`teardown`), add `spec` to the list:

> User-facing surface is now medic/consult/spec/deploy/list/teardown.

- [ ] **Step 2: Add v0.12.0 status line**

Append to the "Status" checklist:

```
- [x] v0.12.0: split /consult into /consult (research+synthesis+drill) + /spec (conductor-only design-doc walk); --design-doc flag deprecated; bin/consult-design-doc.sh renamed → bin/spec-assemble.sh
- [ ] v0.12.0 strict-dogfood pass on a real machine (release gate)
```

- [ ] **Step 3: Verify**

```bash
grep -n 'v0\.12\.0' CLAUDE.md
```

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(claude): record v0.12.0 consult/spec split status

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: Final test sweep + spec self-review against implementation

**Files:** none (verification only)

- [ ] **Step 1: Run full test suite**

Run: `bash tests/run.sh`
Expected: ALL tests pass — including:
- `test_spec_init_source_defaulting.sh` (new)
- `test_spec_directive_static_wiring.sh` (new)
- `test_spec_assemble_single_unchanged.sh` (renamed sacred baseline)
- `test_consult_step84_drilldown_wiring.sh` (new)
- `test_consult_design_doc_flag_deprecated.sh` (new)
- `test_consult_spawn_rollback.sh` (v0.11.2 cold-start retry — must still pass)
- `test_consult_lib_shim_sources_all.sh` (43-function drift counter — should pass; lib unchanged)
- `test_consult_load_prompt_migration.sh` (v0.4.2 prompts — should pass)
- `test_consult_slug_regex_constant.sh` (no bare-literal drift — should pass)

If `test_consult_lib_shim_sources_all.sh`'s drift counter trips, it means the lib actually changed — investigate before proceeding.

- [ ] **Step 2: Cross-check spec coverage**

Open `docs/superpowers/specs/2026-05-06-consult-spec-split-design.md`. For each entry in the "Components" / "Tests" tables, confirm a task above implements it. Specifically verify:

| Spec item | Implemented in |
|---|---|
| `bin/spec-init.sh` source-defaulting | Task 1 |
| `bin/spec-assemble.sh` (rename) | Task 2 |
| `commands/spec.md` directive | Task 3 |
| `commands/consult.md` Step 8.4 | Task 4 |
| `commands/consult.md` Step 8.5 removed + Step 9 unconditional | Task 5 |
| `--design-doc` deprecation | Task 6 |
| Plugin version bump | Task 7 |
| CLAUDE.md status | Task 8 |
| Sacred baseline preserved | Task 2 + 9 (via test rename + final suite) |

- [ ] **Step 3: Push branch + open PR (controller-only step)**

```bash
git push -u origin feat/v0.12.0-consult-spec-split
gh pr create --title "feat(v0.12.0): split /consult into /consult + /spec" \
  --body "$(cat <<'EOF'
## Summary
- Split monolithic `/clone-wars:consult` at the design-doc-walk seam
- New `/clone-wars:spec` is conductor-only (no trooper spawn)
- Drill-deeper relocates from per-section (old Step 8.5) to free-form pre-teardown (new Step 8.4)
- `bin/consult-design-doc.sh` → `bin/spec-assemble.sh` (pure rename, byte-equality preserved)
- `--design-doc` flag deprecated with migration hint

## Test plan
- [ ] `bash tests/run.sh` green on this branch
- [ ] Manual: run `/clone-wars:consult` end-to-end on a small topic; verify Step 8.4 drill prompt appears, declining proceeds to teardown
- [ ] Manual: run `/clone-wars:spec` against the just-archived synthesis.md; verify section walk + commit
- [ ] Manual: run `/clone-wars:consult --design-doc <topic>`; verify deprecation warning, no walk attempted
- [ ] Sacred baseline `test_spec_assemble_single_unchanged.sh` byte-equal to v0.10

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 4: Done**

Plan complete. Branch ready for review. v0.12.0 strict-dogfood pass remains as a separate release-gate task.

---

## Self-Review (run after writing this plan)

- [x] **Spec coverage:** every Components-table entry maps to a Task. Drill-deeper relocation, source-defaulting, deprecation warning, sacred baseline rename — all covered.
- [x] **Placeholder scan:** no TBD / TODO / "implement later". Every step has either concrete code or an exact command + expected output.
- [x] **Type consistency:** `bin/spec-init.sh` outputs `TOPIC=` and `SEED=` lines (Task 1); Task 3's directive references those exact tokens. `cw_consult_design_doc_resume_state` referenced in Task 3 exists in current `lib/consult.sh` (verified pre-write). `consult-drilldown.sh` invocation in Task 4 matches the existing 5-positional-arg signature with optional 6/7th commander+model pairs.
- [x] **TDD discipline:** Tasks 1, 3, 4, 6 have failing-test → impl → passing-test → commit. Task 2 (rename) and Tasks 5, 7, 8 are non-TDD (they're transformations whose correctness is verified by the existing test suite). Task 9 is the final sweep.
- [x] **Bisect safety:** every commit between Task 1 and Task 9 keeps `bash tests/run.sh` green. Specifically: Task 2 renames the assemble script + its test together (same commit); Task 4 adds Step 8.4 wiring before Task 5 deletes Step 8.5 (so the drill function never disappears mid-tree); Task 6 adds the deprecation warning AFTER Step 8.5 is gone (no path to enter the walk via the flag).
