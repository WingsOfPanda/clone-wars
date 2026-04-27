# Clone Wars Hardening — Phase 3 (`v0.0.6`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land Phase 3 polish fixes from the hardening spec — accurate `ready` event timestamp, residual test coverage for `lib/colors.sh` and `lib/commanders.sh`, palette tweak so `fives` and `wolffe` aren't visually adjacent — and tag `v0.0.6`.

**Architecture:** All changes are local: one heredoc edit in `lib/ipc.sh`, two new test files, two two-line palette swaps in `lib/colors.sh`. No new dependencies. Each fix is independently shippable.

**Tech Stack:** bash 4.2+, tmux ≥ 3.0, pure-shell test harness (`tests/run.sh` discovers every `tests/test_*.sh`), `lib/log.sh` for stderr output.

---

## Spec reference

`/home/liupan/CC/clone-wars/docs/superpowers/specs/2026-04-26-clone-wars-hardening-design.md` § Phase 3.

## File structure (Phase 3 changes)

| File | Status | Responsibility |
|---|---|---|
| `lib/ipc.sh` | modify | `cw_identity_write` heredoc — replace baked `$(date)` with a shell `$(date)` the trooper runs at emit time |
| `lib/commanders.sh` | modify | `cw_commanders_in_use_in_topic` + `cw_commanders_in_use_globally` switch from `sed 's/-[^-]*$//'` (last-hyphen strip — buggy for hyphenated models) to `cw_pane_meta_read_for_dir` (Phase 1's source-of-truth helper). Closes the latent #3 leak that Phase 1 fixed in `bin/list.sh`/`bin/teardown.sh` but missed here. |
| `tests/test_identity_template.sh` | **NEW** | Cover `cw_identity_write`: identity.md ends with the "First action" block; the embedded shell command **actually executes** to produce a single valid `ready` JSONL line with a fresh ts inside a known time window. |
| `tests/test_colors.sh` | **NEW** | Cover `lib/colors.sh`: palette shape, case-insensitivity, default fallback, rank/label helpers. NO palette-stability assertions in this file — those land with the swap (Task 4) so every commit is green. |
| `tests/test_commanders.sh` | **NEW** | Cover `lib/commanders.sh`: pool parsing, in-use detection (including the **hyphenated-model deployment** case Codex flagged), random-pick semantics across the global/topic-unused fallback. |
| `lib/colors.sh` | modify | Two two-line edits: `fives` colour103 → colour67; `dogma` colour67 → colour103 (visual deduplication of fives + wolffe). Same commit appends palette-stability assertions to `tests/test_colors.sh`. |
| `.claude-plugin/plugin.json` | modify | Bump to `0.0.6` |
| `.claude-plugin/marketplace.json` | modify | Bump to `0.0.6` |

## Codex review revisions baked in

The original draft of this plan had three issues caught by Codex adversarial review. They are addressed inline rather than as follow-ups:

1. **`lib/commanders.sh` still uses last-hyphen strip** — same bug class Phase 1's #3 fixed in `bin/list.sh`/`bin/teardown.sh`. Task 3 now (a) adds a hyphenated-model regression test AND (b) fixes the lib so `cw_commanders_in_use_in_topic` reads pane.json via `cw_pane_meta_read_for_dir`. Without this, the duplicate-commander guard would silently fail for hyphenated-model deployments.
2. **The #12 test originally only grepped for substrings.** Now it extracts the rendered shell command from identity.md and **executes it against a temp outbox**, asserting exactly one well-formed JSONL line with a runtime-fresh `ts` inside a before/after time window.
3. **The original Task 2 → Task 4 ordering committed a failing suite for one revision.** The palette-stability assertions are now appended to `tests/test_colors.sh` IN THE SAME COMMIT as the palette swap (Task 4). Every commit on the branch leaves the suite green.

---

## Setup (before Task 1)

- [ ] **Step 0.1: Create the implementation branch**

```bash
cd /home/liupan/CC/clone-wars
git checkout main
git pull origin main
git checkout -b chore/v0.0.6-hardening-phase-3
```

The hook policy blocks direct commits to `main`; everything goes through this branch + a PR.

---

## Task 1 — `lib/ipc.sh`: `ready` event timestamp at emit time (#12)

**Problem.** `cw_identity_write` builds the trooper's identity.md via an unquoted heredoc that runs `$(date -u +"%Y-%m-%dT%H:%M:%SZ")` AT WRITE TIME. The trooper is told to "Append exactly this single line", and that single line carries the conductor's spawn-prep timestamp, NOT the trooper's actual emit timestamp. Drift is typically 8–30 seconds depending on bootstrap. Cosmetic but wrong.

**Fix.** Replace the baked-at-write `$(date ...)` literal with a token the trooper runs at emit time. The `echo` command in the prompt becomes:

```sh
echo "{\"event\":\"ready\",\"ts\":\"$(date -u +'%Y-%m-%dT%H:%M:%SZ')\",\"commander\":\"$commander\",\"model\":\"$model\"}" >> $outbox
```

The TROOPER's shell expands `$(date)` at the time it runs the command. The CONDUCTOR's heredoc, which renders identity.md, must NOT expand it. Currently the heredoc is `<<EOF` (unquoted) — every `$(...)` and `$var` runs at write time. The fix uses backslash escapes inside the unquoted heredoc to defer the expansion to the trooper.

**Files:**
- Modify: `/home/liupan/CC/clone-wars/lib/ipc.sh:74-89` (the `cw_identity_write` heredoc)
- Test: `/home/liupan/CC/clone-wars/tests/test_identity_template.sh` (new)

### Step 1.1: Write the failing test

Create `/home/liupan/CC/clone-wars/tests/test_identity_template.sh` with EXACTLY this content:

```bash
#!/usr/bin/env bash
# tests/test_identity_template.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/state.sh
source ../lib/ipc.sh

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"
export PLUGIN_ROOT="$(cd .. && pwd)"

DIR=$(cw_trooper_dir rex codex demo)
mkdir -p "$DIR"

# 1. cw_identity_write produces identity.md with the trooper's name + topic.
cw_identity_write rex codex demo
IDENTITY="$DIR/identity.md"
assert_file_exists "$IDENTITY" "identity.md created"
grep -q 'rex' "$IDENTITY" || { echo "FAIL: identity.md missing commander 'rex'" >&2; exit 1; }
grep -q 'demo' "$IDENTITY" || { echo "FAIL: identity.md missing topic 'demo'" >&2; exit 1; }
pass "identity.md substitutes commander+topic"

# 2. The "First action" block exists with the ready-event echo command.
grep -q 'First action' "$IDENTITY" || { echo "FAIL: First action block missing" >&2; exit 1; }
grep -q '"event":"ready"' "$IDENTITY" || { echo "FAIL: ready event template missing" >&2; exit 1; }
pass "First action block present"

# 3. The commander/model substitutions WORK at write time (those should be
#    baked — they don't change between write and emit). The "commander":"rex"
#    and "model":"codex" fields must be literally present somewhere in
#    identity.md (either in the display JSON line or the shell command line).
grep -q '"commander":"rex"' "$IDENTITY" || { echo "FAIL: commander field not baked" >&2; exit 1; }
grep -q '"model":"codex"' "$IDENTITY" || { echo "FAIL: model field not baked" >&2; exit 1; }
pass "commander+model baked correctly (these don't drift)"

# 4. Defense against pre-baked timestamps inside the SHELL command line:
#    extract the line that begins with `echo "{...` (the verbatim shell
#    command the trooper is told to run) and ensure the ts field is a
#    runtime command substitution, not a literal value.
SHELL_LINE=$(grep -E '^\\?`echo "?\{|^echo "\{' "$IDENTITY" | head -n1)
[[ -z "$SHELL_LINE" ]] && SHELL_LINE=$(grep -F '$(date' "$IDENTITY" | head -n1)
[[ -n "$SHELL_LINE" ]] || {
  echo "FAIL: couldn't locate the shell-command line in identity.md" >&2
  echo "  identity.md tail:" >&2; tail -20 "$IDENTITY" >&2
  exit 1; }
[[ "$SHELL_LINE" == *'$(date'* ]] || {
  echo "FAIL: shell-command line lacks runtime \$(date ...) substitution" >&2
  echo "  line was: $SHELL_LINE" >&2
  exit 1; }
[[ "$SHELL_LINE" =~ \"ts\":\"[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] && {
  echo "FAIL: shell-command line has a literal pre-baked timestamp inside ts" >&2
  echo "  line was: $SHELL_LINE" >&2
  exit 1; } || true
pass "shell command line uses runtime \$(date ...) and has no baked ts"

# 5. EXECUTABLE VERIFICATION (the load-bearing test, per Codex review):
#    extract the verbatim shell command from identity.md, run it against
#    a temp outbox file, and assert exactly one well-formed JSONL line
#    with commander/model baked AND a runtime-fresh ts inside the
#    [before, after] execution window. This proves the heredoc's escape
#    sequences actually produce a parseable, working shell command —
#    not just a substring that LOOKS right but mis-parses when run.
EXEC_OUTBOX="$TMP/exec-outbox.jsonl"
:> "$EXEC_OUTBOX"
# The instructions tell the trooper to write to $outbox — a path baked at
# write time. Our test just rendered identity.md against a sandbox state
# dir whose outbox is at $DIR/outbox.jsonl. Read the rendered command and
# run it; the redirect target is already correct.
# Extract the line that contains both 'echo' and '$(date' and looks like
# the verbatim command (sits inside markdown backticks).
CMD=$(grep -E 'echo .*\$\(date' "$IDENTITY" | head -n1 \
  | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
        -e 's/^`//' -e 's/`$//')
[[ -n "$CMD" ]] || {
  echo "FAIL: couldn't extract verbatim shell command" >&2
  exit 1; }
# Replace the rendered $outbox path (which points at $DIR/outbox.jsonl)
# with our test outbox so we don't pollute the sandbox. We rendered with
# rex/codex/demo so the path in $CMD is $DIR/outbox.jsonl.
RENDERED_OUTBOX="$DIR/outbox.jsonl"
CMD_TEST=${CMD//$RENDERED_OUTBOX/$EXEC_OUTBOX}
BEFORE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
sleep 1
bash -c "$CMD_TEST"
sleep 1
AFTER=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Outbox should have exactly one line.
LINE_COUNT=$(wc -l < "$EXEC_OUTBOX")
assert_eq "$LINE_COUNT" "1" "exactly one JSONL line written"
LINE=$(cat "$EXEC_OUTBOX")
# Must be valid-shape JSON with the four expected fields.
[[ "$LINE" =~ ^\{\"event\":\"ready\",\"ts\":\"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\",\"commander\":\"rex\",\"model\":\"codex\"\}$ ]] || {
  echo "FAIL: emitted line doesn't match expected JSON shape" >&2
  echo "  line: $LINE" >&2
  exit 1; }
# Extract the ts and check it's strictly within [BEFORE, AFTER].
EMITTED_TS=$(printf '%s\n' "$LINE" | grep -oE '"ts":"[0-9TZ:-]+"' | head -n1 | sed -e 's/"ts":"//' -e 's/"$//')
[[ "$EMITTED_TS" > "$BEFORE" || "$EMITTED_TS" == "$BEFORE" ]] || {
  echo "FAIL: emitted ts $EMITTED_TS is older than BEFORE $BEFORE" >&2; exit 1; }
[[ "$EMITTED_TS" < "$AFTER" || "$EMITTED_TS" == "$AFTER" ]] || {
  echo "FAIL: emitted ts $EMITTED_TS is newer than AFTER $AFTER" >&2; exit 1; }
pass "executable rendering produces well-formed JSON with runtime ts"

echo "  ALL: ok"
```

### Step 1.2: Run the test to verify it fails

```bash
cd /home/liupan/CC/clone-wars && bash tests/test_identity_template.sh
```

Expected: FAIL on test 4 — current heredoc bakes a literal timestamp like `"ts":"2026-04-27T01:23:45Z"` into identity.md, which test 4's regex catches. Test 3 may also fail because the current heredoc has only the literal-quoted form, no `$(date` substring.

### Step 1.3: Patch the `cw_identity_write` heredoc

Open `/home/liupan/CC/clone-wars/lib/ipc.sh`. Find `cw_identity_write` (currently around lines 53-90 — use `grep -n cw_identity_write lib/ipc.sh` to locate). The heredoc currently looks like:

```bash
  cat >> "$identity" <<EOF

---

**First action (do this immediately, then wait):**

Append exactly this single line to $outbox:

\`{"event":"ready","ts":"$(date -u +"%Y-%m-%dT%H:%M:%SZ")","commander":"$commander","model":"$model"}\`

Use a shell command: \`echo '{"event":"ready","ts":"...","commander":"$commander","model":"$model"}' >> $outbox\`

Then stop and wait. I will send another instruction asking you to read your inbox.
EOF
```

Note the THREE different things happening in this heredoc:
- `$outbox` and `$commander` and `$model` SHOULD expand at write time (the conductor knows these values; the trooper's shell wouldn't).
- `$(date -u +"%Y-%m-%dT%H:%M:%SZ")` SHOULD NOT expand at write time — that's the bug.
- The `\`backticks\`` are markdown-display backticks (escaped because the heredoc body is markdown).

Replace the heredoc body with EXACTLY:

```bash
  cat >> "$identity" <<EOF

---

**First action (do this immediately, then wait):**

Append exactly ONE JSONL line to $outbox. The line MUST be:

\`{"event":"ready","ts":"<ISO-8601 UTC>","commander":"$commander","model":"$model"}\`

Generate the timestamp at the moment you emit (NOT a remembered value). Use this shell command verbatim:

\`echo "{\\"event\\":\\"ready\\",\\"ts\\":\\"\$(date -u +'%Y-%m-%dT%H:%M:%SZ')\\",\\"commander\\":\\"$commander\\",\\"model\\":\\"$model\\"}" >> $outbox\`

The \\\$(date -u ...) command runs in YOUR shell when you execute the command — it produces a fresh timestamp at the moment you emit, not a stale one from when you read this prompt.

Then stop and wait. I will send another instruction asking you to read your inbox.
EOF
```

Key escapes inside the unquoted heredoc:
- `\\"` produces a literal `\"` (backslash + double-quote) in identity.md, so the shell command the trooper sees is double-quoted with escaped inner quotes.
- `\$(date ...)` produces a literal `$(date ...)` in identity.md (the conductor doesn't expand it at write time; the trooper's shell will at emit time).
- `\\\$(date ...)` (in the explanatory paragraph) produces `\$(date ...)` in identity.md so the markdown reader sees an escaped dollar (avoiding accidental expansion if the markdown is ever piped through a shell).
- `$commander`, `$model`, `$outbox` (not escaped) DO expand at write time.

### Step 1.4: Run the test to verify it passes

```bash
cd /home/liupan/CC/clone-wars && bash tests/test_identity_template.sh
```

Expected: All 5 `PASS:` lines, then `ALL: ok`.

### Step 1.5: Run the full suite

```bash
cd /home/liupan/CC/clone-wars && bash tests/run.sh
```

Expected: every test passes including the new `test_identity_template.sh`.

### Step 1.6: Commit

```bash
cd /home/liupan/CC/clone-wars
git add lib/ipc.sh tests/test_identity_template.sh
git commit -m "$(cat <<'EOF'
fix(ipc): ready event ts uses runtime \$(date ...) (#12)

cw_identity_write's heredoc previously baked the spawn-prep
timestamp into identity.md via \$(date ...), so the trooper's
{ready} event carried a stale ts (8-30s drift typical, larger
on slow bootstraps).

Now the heredoc emits a literal \$(date -u +...) command for the
trooper's shell to expand at emit time. The conductor still bakes
\$commander, \$model, and \$outbox (which don't drift), but the
timestamp is fresh.

Test asserts identity.md contains the runtime \$(date... substring
AND does NOT contain any literal pre-baked timestamp inside a ts
field.
EOF
)"
```

---

## Task 2 — `tests/test_colors.sh`: residual coverage for `lib/colors.sh` (#13a)

**Files:**
- Test: `/home/liupan/CC/clone-wars/tests/test_colors.sh` (new)

No code changes — this task is pure test addition.

### Step 2.1: Write the test

Create `/home/liupan/CC/clone-wars/tests/test_colors.sh` with EXACTLY this content:

```bash
#!/usr/bin/env bash
# tests/test_colors.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/colors.sh

# 1. cw_palette_for returns "<primary> <secondary>" for known commanders.
PAL=$(cw_palette_for rex)
[[ "$PAL" =~ ^colour[0-9]+\ colour[0-9]+$ ]] || {
  echo "FAIL: rex palette shape wrong: '$PAL'" >&2; exit 1; }
pass "palette has two colour## tokens"

# 2. Case insensitivity: cw_palette_for accepts uppercase.
PAL_LOWER=$(cw_palette_for rex)
PAL_UPPER=$(cw_palette_for REX)
assert_eq "$PAL_LOWER" "$PAL_UPPER" "rex/REX produce same palette"
pass "palette lookup is case-insensitive"

# 3. Default fallback for unknown commanders.
PAL_UNKNOWN=$(cw_palette_for nosuchcommander)
assert_eq "$PAL_UNKNOWN" "white default" "unknown commander → white default"
pass "default fallback for unknowns"

# 4. cw_color_for returns ONLY the primary (first token).
PRIMARY=$(cw_color_for rex)
[[ "$PRIMARY" =~ ^colour[0-9]+$ ]] || {
  echo "FAIL: rex primary shape wrong: '$PRIMARY'" >&2; exit 1; }
# Sanity: it should equal the first token of cw_palette_for.
EXPECTED=$(cw_palette_for rex | awk '{print $1}')
assert_eq "$PRIMARY" "$EXPECTED" "primary = first token of palette"
pass "cw_color_for returns the primary"

# 5. cw_rank_for maps known commanders to canonical Star Wars ranks.
assert_eq "$(cw_rank_for rex)" "captain"      "rex is captain"
assert_eq "$(cw_rank_for cody)" "commander"   "cody is commander"
assert_eq "$(cw_rank_for wolffe)" "commander" "wolffe is commander"
assert_eq "$(cw_rank_for jesse)" "sergeant"   "jesse is sergeant"
assert_eq "$(cw_rank_for unknown_name)" "trooper" "unknown name → trooper (default rank)"
pass "rank mapping correct for known + default"

# 6. cw_label_for produces "<rank>-<commander>:<model>:<topic>".
LABEL=$(cw_label_for rex codex auth-review)
assert_eq "$LABEL" "captain-rex:codex:auth-review" "label format"
pass "label_for shape"

# 7. cw_label_fmt produces a tmux #[fg=...] format string with primary,
#    secondary, and the topic in plain text.
FMT=$(cw_label_fmt rex codex auth-review)
[[ "$FMT" == *'#[fg=colour'* ]] || { echo "FAIL: label_fmt missing #[fg=...]: '$FMT'" >&2; exit 1; }
[[ "$FMT" == *captain-rex* ]] || { echo "FAIL: label_fmt missing rank-commander: '$FMT'" >&2; exit 1; }
[[ "$FMT" == *':codex:'* ]] || { echo "FAIL: label_fmt missing :codex:: '$FMT'" >&2; exit 1; }
[[ "$FMT" == *auth-review* ]] || { echo "FAIL: label_fmt missing topic: '$FMT'" >&2; exit 1; }
pass "label_fmt contains fg color + rank-commander + model + topic"

echo "  ALL: ok"
```

**Codex review note.** The original draft of this test had a case 8 that asserted post-Task-4 palette values (fives=67, dogma=103). It would have FAILED for one commit between Task 2 and Task 4. To keep every commit on the branch green and bisect-safe, those assertions land WITH the palette swap in Task 4 — see Step 4.1.

### Step 2.2: Run the test to verify it passes

```bash
cd /home/liupan/CC/clone-wars && bash tests/test_colors.sh
```

Expected: All 7 `PASS:` lines, then `ALL: ok`. (No failing assertions — palette stability lands with the swap in Task 4.)

### Step 2.3: Run the full suite

```bash
cd /home/liupan/CC/clone-wars && bash tests/run.sh
```

Expected: every test passes including the new `test_colors.sh`.

### Step 2.4: Commit

```bash
cd /home/liupan/CC/clone-wars
git add tests/test_colors.sh
git commit -m "$(cat <<'EOF'
test(colors): residual coverage for lib/colors.sh (#13a)

Adds tests/test_colors.sh covering:
- palette shape ("colour##  colour##")
- case insensitivity (rex == REX)
- default fallback for unknown commanders
- cw_color_for returns primary
- cw_rank_for canonical mappings + default rank=trooper
- cw_label_for / cw_label_fmt formats

Palette-stability assertions for specific commanders (rex/cody/
wolffe/fives/dogma) land with the Task 4 swap so every commit on
the branch leaves the suite green.
EOF
)"
```

---

## Task 3 — `lib/commanders.sh` + `tests/test_commanders.sh`: residual coverage AND hyphenated-model parser fix (#13b)

**Codex review note.** The original draft only added test coverage. Codex flagged that `lib/commanders.sh:36` still uses `sed 's/-[^-]*$//'` (last-hyphen strip) — same bug class Phase 1's #3 fixed in `bin/list.sh`/`bin/teardown.sh`. For a state dir like `alpha-claude-haiku/`, the strip yields `alpha-claude` instead of `alpha`, so `cw_commander_in_use` and `cw_commanders_in_use_globally` mis-identify the deployed commander. Effect: the duplicate-spawn guard (`bin/spawn.sh:108`) silently lets a user spawn `alpha` again on the same topic when an `alpha-claude-haiku` trooper already exists.

This task therefore (a) fixes `lib/commanders.sh` to use Phase 1's `cw_pane_meta_read_for_dir` as the source of truth, and (b) adds a hyphenated-model regression test.

**Files:**
- Modify: `/home/liupan/CC/clone-wars/lib/commanders.sh` (`cw_commanders_in_use_in_topic` + `cw_commanders_in_use_globally`)
- Test: `/home/liupan/CC/clone-wars/tests/test_commanders.sh` (new)

### Step 3.1: Write the test

Create `/home/liupan/CC/clone-wars/tests/test_commanders.sh` with EXACTLY this content:

```bash
#!/usr/bin/env bash
# tests/test_commanders.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/state.sh
source ../lib/commanders.sh

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"
mkdir -p "$CLONE_WARS_HOME/state/$(cw_repo_hash)"

# 1. cw_commanders_path uses the user override if present, else falls back
#    to the shipped default at $PLUGIN_ROOT/config/commanders.yaml.
export PLUGIN_ROOT="$(cd .. && pwd)"
PATH_OUT=$(cw_commanders_path)
[[ "$PATH_OUT" == "$PLUGIN_ROOT/config/commanders.yaml" ]] || {
  echo "FAIL: commanders_path didn't fall back to plugin default; got '$PATH_OUT'" >&2; exit 1; }
pass "commanders_path falls back to plugin default"

# 2. User override takes precedence.
mkdir -p "$CLONE_WARS_HOME"
cat > "$CLONE_WARS_HOME/commanders.yaml" <<'YAML'
commanders:
  - alpha
  - beta
YAML
PATH_OUT=$(cw_commanders_path)
assert_eq "$PATH_OUT" "$CLONE_WARS_HOME/commanders.yaml" "user-owned commanders.yaml wins"
pass "user override takes precedence"

# 3. cw_commanders_pool parses the user-owned list, skipping comments + empties.
cat > "$CLONE_WARS_HOME/commanders.yaml" <<'YAML'
# This is a comment
commanders:
  - alpha
  # nested comment
  - beta

  - gamma
YAML
mapfile -t POOL < <(cw_commanders_pool)
assert_eq "${#POOL[@]}" "3" "pool has 3 entries"
assert_eq "${POOL[0]}" "alpha" "first entry"
assert_eq "${POOL[1]}" "beta"  "second entry"
assert_eq "${POOL[2]}" "gamma" "third entry"
pass "pool parsing skips comments and empties"

# Need lib/ipc.sh for cw_pane_meta_write (so test state dirs have valid pane.json
# that the new lib/commanders.sh code path will read).
source ../lib/ipc.sh

# 4. cw_commander_in_use returns 0 iff the commander has a state dir under topic.
TOPIC_DIR="$CLONE_WARS_HOME/state/$(cw_repo_hash)/demo"
mkdir -p "$TOPIC_DIR/alpha-codex"
cw_pane_meta_write alpha codex demo '%101'
cw_commander_in_use alpha demo && pass "alpha is in use on demo" \
  || { echo "FAIL: alpha should be in use on demo" >&2; exit 1; }
cw_commander_in_use beta demo  && { echo "FAIL: beta should NOT be in use on demo" >&2; exit 1; } \
  || pass "beta is NOT in use on demo"

# 4b. HYPHENATED-MODEL REGRESSION (Codex review finding): a deployment with
#     a hyphenated model key like 'claude-haiku' must be detected via its
#     pane.json's "commander" field, NOT via name-parsing the dir. The pre-fix
#     last-hyphen strip would misread alpha-claude-haiku as commander='alpha-claude'
#     and silently let `alpha` be re-spawned.
HYPHEN_DIR="$CLONE_WARS_HOME/state/$(cw_repo_hash)/hyphen-topic"
mkdir -p "$HYPHEN_DIR/alpha-claude-haiku"
cw_pane_meta_write alpha claude-haiku hyphen-topic '%102'
cw_commander_in_use alpha hyphen-topic \
  && pass "alpha detected as in-use on hyphen-topic (via pane.json)" \
  || { echo "FAIL: alpha (deployed as alpha-claude-haiku) not detected as in-use" >&2
       echo "       last-hyphen strip would misread it as 'alpha-claude'" >&2
       exit 1; }

# 5. cw_commanders_in_use_globally lists deployed commanders across topics
#    AND correctly resolves hyphenated-model dirs to the right commander.
mkdir -p "$CLONE_WARS_HOME/state/$(cw_repo_hash)/other-topic/beta-claude"
cw_pane_meta_write beta claude other-topic '%103'
mapfile -t GLOBAL < <(cw_commanders_in_use_globally | sort)
[[ " ${GLOBAL[*]} " == *' alpha '* ]] || {
  echo "FAIL: globally-deployed alpha missing from list: '${GLOBAL[*]}'" >&2; exit 1; }
[[ " ${GLOBAL[*]} " == *' beta '* ]] || {
  echo "FAIL: globally-deployed beta missing from list: '${GLOBAL[*]}'" >&2; exit 1; }
# Crucially: alpha (deployed as alpha-claude-haiku in test 4b) must show
# up as 'alpha', not as 'alpha-claude' — proving the parser uses pane.json
# instead of last-hyphen strip across the global enumeration too.
[[ " ${GLOBAL[*]} " != *' alpha-claude '* ]] || {
  echo "FAIL: hyphenated-model leakage: 'alpha-claude' appeared instead of 'alpha'" >&2
  echo "       global list was: '${GLOBAL[*]}'" >&2; exit 1; }
pass "in_use_globally correctly resolves hyphenated-model dirs"

# 6. cw_commander_pick_random excludes globally-used names first.
#    Pool: alpha, beta, gamma. Used globally: alpha, beta. Pick should be gamma.
PICK=$(cw_commander_pick_random new-topic)
assert_eq "$PICK" "gamma" "pick prefers globally-unused names"
pass "pick_random excludes globally-used names (first pass)"

# 7. When every pool name is globally used, fall back to topic-unused.
mkdir -p "$CLONE_WARS_HOME/state/$(cw_repo_hash)/saturated/gamma-codex"
# Now alpha+beta+gamma are all globally used. New topic 'fresh-topic' has
# none of them in-use locally, so pick should still succeed (fallback).
PICK2=$(cw_commander_pick_random fresh-topic)
[[ -n "$PICK2" ]] || { echo "FAIL: pick returned empty when fallback should succeed" >&2; exit 1; }
[[ "$PICK2" == "alpha" || "$PICK2" == "beta" || "$PICK2" == "gamma" ]] \
  || { echo "FAIL: pick returned unexpected name '$PICK2'" >&2; exit 1; }
pass "pick_random falls back to topic-unused when all pool is globally used"

# 8. When pool is empty / all in-use within the target topic, pick returns 1.
#    Saturate 'overcrowded' with all three pool members.
for c in alpha beta gamma; do
  mkdir -p "$CLONE_WARS_HOME/state/$(cw_repo_hash)/overcrowded/${c}-codex"
done
PICK3=$(cw_commander_pick_random overcrowded 2>/dev/null) && CODE=0 || CODE=$?
assert_eq "$CODE" "1" "pick returns rc=1 when topic saturated"
pass "pick_random fails closed when no pool name is available"

echo "  ALL: ok"
```

### Step 3.2: Run the test to verify it fails

```bash
cd /home/liupan/CC/clone-wars && bash tests/test_commanders.sh
```

Expected: FAIL on test 4b — `cw_commander_in_use alpha hyphen-topic` returns false because v0.0.5's last-hyphen strip misreads the dir as commander=`alpha-claude`. Test 5's "no leakage" assertion may also fail.

### Step 3.3: Patch `lib/commanders.sh` to use Phase 1's pane.json source-of-truth

Open `/home/liupan/CC/clone-wars/lib/commanders.sh`. Use Read to find the exact current text. The current code (around lines 32-55) is approximately:

```bash
# cw_commanders_in_use_in_topic <topic>
cw_commanders_in_use_in_topic() {
  local topic="$1"
  local dir="$(cw_state_root)/state/$(cw_repo_hash)/$topic"
  [[ -d "$dir" ]] || return 0
  ls -1 "$dir" 2>/dev/null | sed 's/-[^-]*$//' | sort -u
}

# cw_commander_in_use <commander> <topic>
cw_commander_in_use() {
  local commander="$1" topic="$2"
  cw_commanders_in_use_in_topic "$topic" | grep -qx "$commander"
}

# cw_commanders_in_use_globally
cw_commanders_in_use_globally() {
  local root="$(cw_state_root)/state/$(cw_repo_hash)"
  [[ -d "$root" ]] || return 0
  for topic_dir in "$root"/*/; do
    [[ -d "$topic_dir" ]] || continue
    ls -1 "$topic_dir" 2>/dev/null | sed 's/-[^-]*$//'
  done | sort -u
}
```

Replace the two helpers `cw_commanders_in_use_in_topic` and `cw_commanders_in_use_globally` with versions that read `pane.json` (via Phase 1's `cw_pane_meta_read_for_dir`) as the source of truth, falling through to the legacy parse only if pane.json is absent. The corrected block:

```bash
# cw_commanders_in_use_in_topic <topic>
# Print the set of commanders currently deployed in <topic> by reading each
# trooper dir's pane.json (Phase 1's commander+model schema). Falls back to
# dir-name parse for legacy v0.0.3 troopers — the same fallback path as
# bin/list.sh and bin/teardown.sh use elsewhere via cw_pane_meta_read_for_dir.
cw_commanders_in_use_in_topic() {
  local topic="$1"
  local dir="$(cw_state_root)/state/$(cw_repo_hash)/$topic"
  [[ -d "$dir" ]] || return 0
  shopt -s nullglob
  local trooper_dir _META
  for trooper_dir in "$dir"/*/; do
    [[ -d "$trooper_dir" ]] || continue
    mapfile -t _META < <(cw_pane_meta_read_for_dir "$trooper_dir")
    [[ -n "${_META[0]:-}" ]] && printf '%s\n' "${_META[0]}"
  done | sort -u
}

# cw_commander_in_use <commander> <topic>
# Return 0 if <commander> is currently deployed under <topic>.
cw_commander_in_use() {
  local commander="$1" topic="$2"
  cw_commanders_in_use_in_topic "$topic" | grep -qx "$commander"
}

# cw_commanders_in_use_globally
# Print every commander currently deployed across every topic in this repo.
cw_commanders_in_use_globally() {
  local root="$(cw_state_root)/state/$(cw_repo_hash)"
  [[ -d "$root" ]] || return 0
  shopt -s nullglob
  local topic_dir trooper_dir _META
  for topic_dir in "$root"/*/; do
    [[ -d "$topic_dir" ]] || continue
    for trooper_dir in "$topic_dir"*/; do
      [[ -d "$trooper_dir" ]] || continue
      mapfile -t _META < <(cw_pane_meta_read_for_dir "$trooper_dir")
      [[ -n "${_META[0]:-}" ]] && printf '%s\n' "${_META[0]}"
    done
  done | sort -u
}
```

**Important:** `cw_pane_meta_read_for_dir` lives in `lib/ipc.sh`. The bin scripts source `lib/ipc.sh` AND `lib/commanders.sh`, so the function is in scope at runtime. But `lib/commanders.sh` doesn't itself source `lib/ipc.sh` — keep it that way (the test at Step 3.1 sources both explicitly), avoiding a load-order dependency in the lib hierarchy.

### Step 3.4: Run the test to verify it passes

```bash
cd /home/liupan/CC/clone-wars && bash tests/test_commanders.sh
```

Expected: All 9 `PASS:` lines (8 from the original spec + the new 4b case), then `ALL: ok`.

### Step 3.5: Run the full suite

```bash
cd /home/liupan/CC/clone-wars && bash tests/run.sh
```

Expected: every test passes EXCEPT `test_colors.sh` case 8 (the fives/dogma stability assertions still fail until Task 4 lands the swap).

### Step 3.6: Commit

```bash
cd /home/liupan/CC/clone-wars
git add lib/commanders.sh tests/test_commanders.sh
git commit -m "$(cat <<'EOF'
fix(commanders): use pane.json metadata for in-use detection (#13b)

cw_commanders_in_use_in_topic and cw_commanders_in_use_globally
previously derived commander names by stripping the last hyphen
segment of each state-dir name. For a hyphenated model key like
'claude-haiku', a dir 'alpha-claude-haiku' was misread as
commander='alpha-claude' instead of 'alpha' — same bug class
Phase 1's #3 fixed in bin/list.sh and bin/teardown.sh, but missed
in commanders.sh.

Effect of the latent bug: bin/spawn.sh's duplicate-commander
guard (cw_commander_in_use) silently let a user re-spawn 'alpha'
when 'alpha-claude-haiku' was already deployed.

Now both helpers iterate state dirs and read each pane.json via
cw_pane_meta_read_for_dir (Phase 1's source-of-truth helper),
falling back to dir-name parse only for legacy state. Same
pattern bin/list.sh and bin/teardown.sh established.

Adds tests/test_commanders.sh covering:
- cw_commanders_path: user override vs plugin-default fallback
- cw_commanders_pool: skips comments + empty lines
- cw_commander_in_use: based on state-dir presence
- HYPHENATED-MODEL regression: alpha-claude-haiku → alpha
- cw_commanders_in_use_globally: multi-topic enumeration with
  hyphenated-model leakage check
- cw_commander_pick_random: prefers globally-unused, falls back
  to topic-unused, returns rc=1 when topic is saturated
EOF
)"
```

---

## Task 4 — `lib/colors.sh` + `tests/test_colors.sh`: palette tweak + lock-in test (#17)

**Problem.** `fives` (colour103, steel-blue) and `wolffe` (colour104, periwinkle) are one shade apart in the 256-color terminal palette. Adjacent panes look near-identical.

**Fix.** Move `fives` from colour103 → colour67 (mid-slate, currently used by `dogma`). Move `dogma` from colour67 → colour103 (steel-blue). Net: fives is now slate, dogma is steel-blue, neither adjacent to wolffe. Both retain Morandi character. **Same commit appends a palette-stability test case** to `tests/test_colors.sh` so the swap is regression-guarded and every commit on the branch leaves the suite green.

**Files:**
- Modify: `/home/liupan/CC/clone-wars/lib/colors.sh:34` (fives entry)
- Modify: `/home/liupan/CC/clone-wars/lib/colors.sh:38` (dogma entry)
- Modify: `/home/liupan/CC/clone-wars/tests/test_colors.sh` (append case 8: palette stability)

### Step 4.1: Patch the fives entry

Open `/home/liupan/CC/clone-wars/lib/colors.sh`. Find the line:

```bash
    fives)      printf 'colour103 colour187\n' ;;  # steel-blue + cream
```

Replace with:

```bash
    fives)      printf 'colour67 colour187\n'  ;;  # mid slate + cream (swapped from 103 in v0.0.6: was adjacent to wolffe colour104)
```

### Step 4.2: Patch the dogma entry

Find the line:

```bash
    dogma)      printf 'colour67 colour187\n'  ;;  # mid slate + cream
```

Replace with:

```bash
    dogma)      printf 'colour103 colour187\n' ;;  # steel-blue + cream (swapped from 67 in v0.0.6: traded with fives for visual deduplication)
```

### Step 4.3: Append the palette-stability case to `tests/test_colors.sh`

Find the last `pass` line + the `echo "  ALL: ok"` line in `tests/test_colors.sh` (case 7 in Task 2). INSERT the following case 8 block immediately BEFORE the `echo "  ALL: ok"` line:

```bash
# 8. Palette stability — assert specific colors so a future palette edit
#    can't accidentally change canon-color identity. Reflects the v0.0.6
#    fives+dogma swap (was: fives=103, dogma=67; now: fives=67, dogma=103).
assert_eq "$(cw_palette_for rex | awk '{print $1}')"    "colour110" "rex primary stable"
assert_eq "$(cw_palette_for cody | awk '{print $1}')"   "colour137" "cody primary stable"
assert_eq "$(cw_palette_for wolffe | awk '{print $1}')" "colour104" "wolffe primary stable"
assert_eq "$(cw_palette_for fives | awk '{print $1}')"  "colour67"  "fives primary stable (post-v0.0.6 swap; was 103)"
assert_eq "$(cw_palette_for dogma | awk '{print $1}')"  "colour103" "dogma primary stable (post-v0.0.6 swap; was 67)"
# Visual deduplication: fives must NOT be one-shade-away from wolffe.
[[ "$(cw_color_for fives)" != "colour103" ]] || {
  echo "FAIL: fives reverted to colour103 — visually adjacent to wolffe colour104" >&2; exit 1; }
[[ "$(cw_color_for fives)" != "colour105" ]] || {
  echo "FAIL: fives is now colour105 — visually adjacent to wolffe colour104" >&2; exit 1; }
pass "palette stability + fives/wolffe deduplication"
```

### Step 4.4: Run `test_colors.sh` to verify case 8 passes

```bash
cd /home/liupan/CC/clone-wars && bash tests/test_colors.sh
```

Expected: All 8 `PASS:` lines, then `ALL: ok`. The fives=colour67 and dogma=colour103 assertions in case 8 now hit.

### Step 4.5: Run the full suite

```bash
cd /home/liupan/CC/clone-wars && bash tests/run.sh
```

Expected: every test passes (16 test files now: Phase 1's 10 + Phase 2's 3 + Phase 3's 3).

### Step 4.6: Commit

```bash
cd /home/liupan/CC/clone-wars
git add lib/colors.sh tests/test_colors.sh
git commit -m "$(cat <<'EOF'
fix(colors): swap fives + dogma to deduplicate adjacent shades (#17)

fives (colour103, steel-blue) and wolffe (colour104, dusty
periwinkle) were one shade apart in tmux's 256-color palette.
Adjacent panes looked near-identical.

Swap fives -> colour67 (mid-slate, was dogma) and dogma -> colour103
(steel-blue, was fives). Net: neither is adjacent to wolffe. Both
keep Morandi character.

Same commit appends test_colors.sh case 8 (palette stability +
fives/wolffe deduplication invariants) so future palette edits
can't accidentally re-introduce the adjacency.
EOF
)"
```

---

## Task 5 — Bump to `v0.0.6`

**Files:**
- Modify: `/home/liupan/CC/clone-wars/.claude-plugin/plugin.json` (version)
- Modify: `/home/liupan/CC/clone-wars/.claude-plugin/marketplace.json` (both `version` keys)

### Step 5.1: Update `plugin.json`

In `/home/liupan/CC/clone-wars/.claude-plugin/plugin.json`, change `"version": "0.0.5"` → `"version": "0.0.6"`.

### Step 5.2: Update `marketplace.json`

In `/home/liupan/CC/clone-wars/.claude-plugin/marketplace.json`, change BOTH `"version": "0.0.5"` occurrences (per-plugin entry + top-level marketplace) to `"version": "0.0.6"`.

### Step 5.3: Final test-suite run

```bash
cd /home/liupan/CC/clone-wars && bash tests/run.sh
```

Expected: every test passes.

### Step 5.4: Commit

```bash
cd /home/liupan/CC/clone-wars
git add .claude-plugin/plugin.json .claude-plugin/marketplace.json
git commit -m "$(cat <<'EOF'
chore: bump version 0.0.5 → 0.0.6 (Phase 3 polish release)

Phase 3 of the hardening rollout per
docs/superpowers/specs/2026-04-26-clone-wars-hardening-design.md.

Includes:
- ready event timestamp at emit time, not write time (#12)
- residual test coverage for lib/colors.sh + lib/commanders.sh (#13)
- palette tweak: fives + dogma swap to break adjacency with wolffe (#17)

Closes the 14-fix hardening rollout. v0.0.4 shipped Phase 1 (#1-#5),
v0.0.5 shipped Phase 2 (#6-#11; #9 was already in v0.0.4 Task 1),
v0.0.6 ships Phase 3 (#12, #13, #17).
EOF
)"
```

---

## Task 6 — Open the PR

**Files:** none (git/gh operations only).

### Step 6.1: Push the branch

```bash
cd /home/liupan/CC/clone-wars
git push -u origin chore/v0.0.6-hardening-phase-3
```

### Step 6.2: Open the PR

```bash
gh pr create --title "chore: v0.0.6 — Phase 3 hardening (fixes #12, #13, #17)" --body "$(cat <<'EOF'
## Summary

Phase 3 (final) of the hardening rollout per the locked spec at \`docs/superpowers/specs/2026-04-26-clone-wars-hardening-design.md\` § Phase 3.

### Fixes

- **#12** \`cw_identity_write\` heredoc now emits a literal \`\$(date -u +'%Y-%m-%dT%H:%M:%SZ')\` for the trooper's shell to expand at emit time. Previously the conductor baked its spawn-prep timestamp into identity.md (8-30s drift). Commander/model still bake at write time (they don't drift).
- **#13** Adds \`tests/test_colors.sh\` (palette shape, case-insensitivity, default fallback, rank/label helpers, palette stability for rex/cody/wolffe/fives/dogma) and \`tests/test_commanders.sh\` (path resolution, pool parsing, in-use detection, random-pick semantics).
- **#17** Palette swap: \`fives\` colour103 → colour67, \`dogma\` colour67 → colour103. Net: fives no longer one shade away from \`wolffe\` (colour104). \`test_colors.sh\` case 8 lock-asserts the new mapping.

Bumps to **v0.0.6**. **Closes the 14-fix hardening rollout.**

## Process

- Plan brainstormed and locked at \`docs/superpowers/plans/2026-04-27-clone-wars-hardening-phase-3.md\`.
- Codex adversarial review on the plan ran before implementation.
- 4 implementation tasks dispatched as fresh subagents per task; spec-compliance + code-quality review each.

## Test results

- 16 test files, all green.
- 3 new test files in this branch: \`test_identity_template.sh\`, \`test_colors.sh\`, \`test_commanders.sh\`.

## Test plan (post-merge, with \`/plugin update\`)

- [ ] Spawn a trooper; check the resulting outbox.jsonl — \`ready\` event \`ts\` should match the time the trooper actually emitted, not the spawn-prep time.
- [ ] Spawn rex + fives + wolffe on the same topic — verify the three pane labels are visually distinct (no two are one-shade-apart).
- [ ] \`/clone-wars:medic\` still verdict-OK.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

### Step 6.3: Surface the PR URL

The user merges, retags \`v0.0.6\`, and runs \`/plugin update\`. Plan execution ends here.

---

## Self-review checklist

- [x] **Spec coverage:** Each of #12, #13, #17 has a dedicated task. Version bump and PR are explicit final tasks. ✓
- [x] **Placeholder scan:** No "TBD", "TODO", "implement later", or vague "add error handling" instructions. Every code step has the exact code; every command step has the exact invocation and expected output. ✓
- [x] **Type / signature consistency:**
  - `cw_identity_write <commander> <model> <topic>` — signature unchanged; only heredoc body (Task 1.3).
  - `cw_palette_for / cw_color_for / cw_rank_for / cw_label_for / cw_label_fmt` — signatures unchanged; Task 4 only swaps two case-arm bodies.
  - All test files follow the existing harness conventions (source `lib/assert.sh`, `mktemp -d` sandbox, `pass` calls).
- [x] **TDD discipline:** Task 1 has a failing-test step that EXECUTES the rendered shell command (per Codex review). Task 3 has a failing-test step before the lib fix (the new hyphenated-model regression case 4b fails until the lib switches to pane.json). Task 2 is a pure test addition (passes against current lib). Task 4 swap + matching case 8 land in the same commit. ✓
- [x] **Every commit is green** (per Codex review revision). The original "Task 2 commits a failing test, Task 4 makes it pass" ordering was changed: Task 2's test_colors.sh case 8 was deferred to ship WITH the palette swap in Task 4. ✓
- [x] **Frequent commits:** One commit per task. ✓
- [x] **No fix-list overrun:** Phase 3 ships 3 fixes per the spec — #12, #13, #17. Final phase. ✓
- [x] **Codex adversarial review findings addressed:**
  - Finding 1 (high, commanders.sh hyphenated-model parser still uses last-hyphen strip) → Task 3 now patches `cw_commanders_in_use_in_topic` and `cw_commanders_in_use_globally` to use `cw_pane_meta_read_for_dir`; test 4b regression-guards the fix.
  - Finding 2 (medium, ready-event test only greps substrings) → Task 1's test 5 now extracts the rendered shell command and EXECUTES it against a temp outbox, asserting one well-formed JSONL line with a runtime ts inside the `[before, after]` window.
  - Finding 3 (medium, Task 2 commits a failing suite) → palette-stability assertions moved into Task 4's commit; every commit on the branch leaves the suite green. ✓
