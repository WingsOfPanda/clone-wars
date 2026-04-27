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
| `lib/ipc.sh` | modify | `cw_identity_write` heredoc — replace baked `$(date)` with a shell `$(date)` the trooper runs at emit time, so the `ready` event's timestamp is accurate-to-the-second |
| `tests/test_identity_template.sh` | **NEW** | Cover `cw_identity_write`: identity.md ends with the "First action" block; the embedded shell command uses a runtime `$(date ...)` not a baked literal |
| `tests/test_colors.sh` | **NEW** | Cover `lib/colors.sh`: palette stability for known commanders (rex/cody/wolffe/fives/dogma after the swap) + default fallback for unknowns + the rank/label helpers |
| `tests/test_commanders.sh` | **NEW** | Cover `lib/commanders.sh`: pool parsing skips comments + empties, `cw_commander_in_use` honors topic dirs, `cw_commander_pick_random` excludes globally-used names |
| `lib/colors.sh` | modify | Two two-line edits: `fives` colour103 → colour67; `dogma` colour67 → colour103 (visual deduplication of fives + wolffe) |
| `.claude-plugin/plugin.json` | modify | Bump to `0.0.6` |
| `.claude-plugin/marketplace.json` | modify | Bump to `0.0.6` |

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

# Need a real identity-template.md to render against. The plugin ships one
# at $PLUGIN_ROOT/config/identity-template.md; PLUGIN_ROOT is set by the
# bin scripts, but in tests we set it explicitly.
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

# 3. The CRITICAL regression: the ts field in the trooper's echo command
#    must NOT be a literal pre-baked timestamp. It must contain a literal
#    $(date ...) command substitution that the trooper's shell will run
#    at emit time. A baked literal would look like '"ts":"2026-04-27T...Z"';
#    the runtime form contains the literal text '$(date'.
grep -F '$(date' "$IDENTITY" || {
  echo "FAIL: identity.md doesn't contain a runtime \$(date ...) substitution — ts will be baked at write time" >&2
  echo "  identity.md content (relevant region):" >&2
  grep -A3 'First action' "$IDENTITY" | head -20 >&2
  exit 1; }
pass "ready event ts uses runtime \$(date ...)"

# 4. Defense against pre-baked timestamps: scan identity.md for any literal
#    timestamp shape (YYYY-MM-DDTHH:MM:SSZ) inside the ready-event template.
#    If one slipped through, the trooper would echo it verbatim.
if grep -oE '"ts":"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"' "$IDENTITY"; then
  echo "FAIL: identity.md contains a baked timestamp inside a ts field" >&2
  exit 1
fi
pass "no baked literal timestamp inside any ts field"

# 5. The commander/model substitutions WORK at write time (those should be
#    baked — they don't change between write and emit). Specifically the
#    "commander":"rex" and "model":"codex" fields must be literally present.
grep -q '"commander":"rex"' "$IDENTITY" || { echo "FAIL: commander field not baked" >&2; exit 1; }
grep -q '"model":"codex"' "$IDENTITY" || { echo "FAIL: model field not baked" >&2; exit 1; }
pass "commander+model baked correctly (these don't drift)"

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

# 8. Palette stability — assert specific colors for several commanders so
#    a future palette edit can't accidentally change canon-color identity
#    without a corresponding test update. After Phase 3's palette tweak
#    (Task 4): rex=110, cody=137, wolffe=104, fives=67, dogma=103.
assert_eq "$(cw_palette_for rex | awk '{print $1}')"    "colour110" "rex primary stable"
assert_eq "$(cw_palette_for cody | awk '{print $1}')"   "colour137" "cody primary stable"
assert_eq "$(cw_palette_for wolffe | awk '{print $1}')" "colour104" "wolffe primary stable"
assert_eq "$(cw_palette_for fives | awk '{print $1}')"  "colour67"  "fives primary stable (post-Task-4 swap)"
assert_eq "$(cw_palette_for dogma | awk '{print $1}')"  "colour103" "dogma primary stable (post-Task-4 swap)"
pass "palette stability (Phase 3 baseline)"

echo "  ALL: ok"
```

### Step 2.2: Run the test to verify it... well, mostly passes

```bash
cd /home/liupan/CC/clone-wars && bash tests/test_colors.sh
```

Expected: cases 1-7 pass against current `lib/colors.sh`. Case 8 FAILS on the `fives`/`dogma` assertions because the palette swap hasn't landed yet (Task 4). That's the regression-bait that locks the swap into place.

### Step 2.3: Commit (the test is correct as-is; Task 4 will make case 8 pass)

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
- palette stability for rex/cody/wolffe/fives/dogma

The fives/dogma stability assertions reference the post-Task-4
palette (fives=67, dogma=103). Case 8 of this test will FAIL
against the current lib/colors.sh until Task 4 lands the swap —
that's intentional: the test is the regression guard that locks
the swap in place.
EOF
)"
```

NOTE: this commit deliberately leaves `tests/run.sh` failing for one commit until Task 4 lands. If you'd rather have a green suite at every commit, defer this commit and combine Task 2 + Task 4's commits — but the plan ships them separately so each is independently understandable. Choose by consistency with the rest of the phase.

---

## Task 3 — `tests/test_commanders.sh`: residual coverage for `lib/commanders.sh` (#13b)

**Files:**
- Test: `/home/liupan/CC/clone-wars/tests/test_commanders.sh` (new)

No code changes.

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

# 4. cw_commander_in_use returns 0 iff the commander has a state dir under topic.
TOPIC_DIR="$CLONE_WARS_HOME/state/$(cw_repo_hash)/demo"
mkdir -p "$TOPIC_DIR/alpha-codex"
cw_commander_in_use alpha demo && pass "alpha is in use on demo" \
  || { echo "FAIL: alpha should be in use on demo" >&2; exit 1; }
cw_commander_in_use beta demo  && { echo "FAIL: beta should NOT be in use on demo" >&2; exit 1; } \
  || pass "beta is NOT in use on demo"

# 5. cw_commanders_in_use_globally lists deployed commanders across topics.
mkdir -p "$CLONE_WARS_HOME/state/$(cw_repo_hash)/other-topic/beta-claude"
mapfile -t GLOBAL < <(cw_commanders_in_use_globally | sort)
[[ " ${GLOBAL[*]} " == *' alpha '* ]] || {
  echo "FAIL: globally-deployed alpha missing from list: '${GLOBAL[*]}'" >&2; exit 1; }
[[ " ${GLOBAL[*]} " == *' beta '* ]] || {
  echo "FAIL: globally-deployed beta missing from list: '${GLOBAL[*]}'" >&2; exit 1; }
pass "in_use_globally includes deployments across topics"

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

### Step 3.2: Run the test

```bash
cd /home/liupan/CC/clone-wars && bash tests/test_commanders.sh
```

Expected: All 8 `PASS:` lines, then `ALL: ok`. (No code changes needed — this task is pure test addition against the existing v0.0.5 lib.)

### Step 3.3: Run the full suite

```bash
cd /home/liupan/CC/clone-wars && bash tests/run.sh
```

Expected: every test passes EXCEPT `test_colors.sh` case 8 (the fives/dogma stability assertions still fail until Task 4 lands the swap).

### Step 3.4: Commit

```bash
cd /home/liupan/CC/clone-wars
git add tests/test_commanders.sh
git commit -m "$(cat <<'EOF'
test(commanders): residual coverage for lib/commanders.sh (#13b)

Adds tests/test_commanders.sh covering:
- cw_commanders_path: user override vs plugin-default fallback
- cw_commanders_pool: skips comments + empty lines
- cw_commander_in_use: based on state-dir presence
- cw_commanders_in_use_globally: multi-topic enumeration
- cw_commander_pick_random: prefers globally-unused, falls back
  to topic-unused, returns rc=1 when topic is saturated
EOF
)"
```

---

## Task 4 — `lib/colors.sh`: palette tweak (fives + dogma swap) (#17)

**Problem.** `fives` (colour103, steel-blue) and `wolffe` (colour104, periwinkle) are one shade apart in the 256-color terminal palette. Adjacent panes look near-identical.

**Fix.** Move `fives` from colour103 → colour67 (mid-slate, currently used by `dogma`). Move `dogma` from colour67 → colour103 (steel-blue). Net: fives is now slate, dogma is steel-blue, neither adjacent to wolffe. Both retain Morandi character.

**Files:**
- Modify: `/home/liupan/CC/clone-wars/lib/colors.sh:34` (fives entry)
- Modify: `/home/liupan/CC/clone-wars/lib/colors.sh:38` (dogma entry)

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

### Step 4.3: Run `test_colors.sh` to verify case 8 now passes

```bash
cd /home/liupan/CC/clone-wars && bash tests/test_colors.sh
```

Expected: All 8 `PASS:` lines, then `ALL: ok`. The fives=colour67 and dogma=colour103 assertions in case 8 now hit.

### Step 4.4: Run the full suite

```bash
cd /home/liupan/CC/clone-wars && bash tests/run.sh
```

Expected: every test passes (16 test files now: Phase 1's 10 + Phase 2's 3 + Phase 3's 3).

### Step 4.5: Commit

```bash
cd /home/liupan/CC/clone-wars
git add lib/colors.sh
git commit -m "$(cat <<'EOF'
fix(colors): swap fives + dogma to deduplicate adjacent shades (#17)

fives (colour103, steel-blue) and wolffe (colour104, dusty
periwinkle) were one shade apart in tmux's 256-color palette.
Adjacent panes looked near-identical.

Swap fives -> colour67 (mid-slate, was dogma) and dogma -> colour103
(steel-blue, was fives). Net: neither is adjacent to wolffe. Both
keep Morandi character.

The Task 2 test (test_colors.sh case 8) lock-asserts the new
mapping so future palette edits can't accidentally re-introduce
the adjacency.
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
- [x] **TDD discipline:** Task 1 has a failing-test step before implementation. Tasks 2 and 3 are pure test additions (the test IS the deliverable; running it on the current code is the verification). Task 4 is locked into place by Task 2's case 8 — failing pre-swap, passing post-swap. ✓
- [x] **Frequent commits:** One commit per task. The Task 2 → Task 4 dependency is intentional (test is committed first, then the swap that makes it pass — case 8 fails for one commit until Task 4 lands). Stop after Task 4 and the suite is green. ✓
- [x] **No fix-list overrun:** Phase 3 ships 3 fixes per the spec — #12, #13, #17. Final phase. ✓
