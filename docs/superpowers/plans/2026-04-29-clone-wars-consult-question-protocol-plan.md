# /clone-wars:consult v0.3 — Question Protocol Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** Revision 3 — incorporates second-pass Codex adversarial findings (Rev2 left 4 unresolved; this revision closes them).

**Goal:** Implement the trooper-question protocol and skill routing defined in `docs/superpowers/specs/2026-04-29-clone-wars-consult-question-protocol-design.md` (Rev 2).

**Architecture:** Extend existing per-phase sub-scripts (no new commands). Wait-script captures the matched outbox event and branches on it; question events auto-advance OFFSET= in the per-commander state file. Re-arm path is wait-script-only (no send-script call). Topic classifier picks `brainstorming` / `systematic-debugging` / `none`. Two skill-hint files carry the autonomy contract.

**Tech Stack:** pure bash + tmux + file IPC (unchanged). No new dependencies.

**Branch:** `feat/v0.3-question-protocol` off `main` (after v0.2.1 merges).

**Total tasks:** 11. TDD throughout; every task includes a failing test, the implementation, the passing test, and a commit.

## Revision 3 changelog (second Codex pass)

| # | Codex Rev2 finding | Resolution |
|---|---|---|
| H1' | Task 9 fixture still called `consult-offset-reset.sh --keep-findings`, contradicting the H1 closure | Task 9 rewritten: H1 regression check anchored after Phase 1 (assert ≥2 OFFSET= lines + 2nd OFFSET == outbox size). Phase 2 simulates cw_send (no state touch). Phase 3 re-runs wait-script directly. |
| H2' | `wc -c` race + multiple queued questions not serialized | Wait-script re-scans tail (head -n1 across event types, with terminal-event precedence); new `cw_consult_outbox_match_endbyte` helper computes exact end-byte. New fixtures: case 5 (q1+q2 — first wins, OFFSET before q2), case 5b (re-run catches q2), case 6 (q+done — terminal wins). |
| H3' | Rev1 dogfood was a non-gate | Split into `_strict.sh` (release gate, MUST reach FS=question + verify ANSWER consumed) and `_default.sh` (informational). |
| M5' | Validator passes escaped quotes; extractor returns truncated text | Fail-closed: validator rejects any `\` in text. Autonomy contract teaches trooper to percent-encode (`%0A`/`%22`/`%5C`/`%09`). Fixtures cover escaped-quote + backslash. |

## Revision 2 changelog

| # | Codex Rev1 finding | How this plan closes it |
|---|---|---|
| H1 | Re-arm step double-writes inbox (cw_send ANSWER then phase send-script overwrites) | Task 6 makes wait-script auto-append `OFFSET=<post-question>` to state file. Task 8's directive recipe drops the `consult-research-send.sh` re-arm call entirely. Re-arm = `cw_send ANSWER → consult-research-wait.sh`. Verified by Task 9 fixture. |
| H2 | Wait-script ignores matched event, rescans for question | Task 6 captures `cw_outbox_wait_since` stdout into `$MATCHED`, parses `event=…`, `case` on actual event. New Task 9b fixture covers `question→error`, `question→done`, multi-question. |
| H3 | Task 9 mocks the protocol it claims to test | New Task 10 adds real-CLI dogfood gated on `command -v codex && command -v tmux`. Fast mock test stays as Task 9 for unit coverage. |
| M4 | Hint refers to `superpowers:debugging` (not installed) | All references renamed to `systematic-debugging`. Task 3 hint file is `config/skill-hints/systematic-debugging.md`. Task 3 test asserts skill names resolve to installed `SKILL.md`. |
| M5 | JSON-via-sed parser accepts malformed payloads | Task 5 adds `cw_consult_question_validate_line`; Task 6 wait-script calls validator before treating as question; Task 5 fixtures cover escaped-quotes, missing-text, embedded-backslash, empty-options, malformed-JSON. |

Lower-severity tightening:

- Task 1 trigger refinement: drop "design"/"structure"/"approach" as standalone triggers (too broad). Brainstorming triggers tightened to `"design pattern"`, `"how should"`, `"what's the best way"`, `"decide between"`.
- Task 4 helper asserts `PLUGIN_ROOT` (or `CLAUDE_PLUGIN_ROOT`) is set; fail loud, not silent no-append.
- Task 4 helper respects `CW_CONSULT_SKILL_OVERRIDE=none` env-var (kill-switch).
- Task 8 directive recipe explicitly Reads `findings.md` (or `verify.md`) before classifying critical/non-critical.

---

## File structure

| Path | Action | Why |
|---|---|---|
| `lib/consult.sh` | modify | Add `cw_consult_classify_topic`, `cw_consult_skill_hint_append`, `cw_consult_question_payload_write/_read`, `cw_consult_question_validate_line`, `cw_consult_question_extract_to_payload` |
| `bin/consult-init.sh` | modify | After picking the general, classify topic and write `_consult/skill.txt` |
| `bin/consult-research-send.sh` | modify | Read `_consult/skill.txt`, append `config/skill-hints/<skill>.md` to prompt; respect `CW_CONSULT_SKILL_OVERRIDE` |
| `bin/consult-verify-send.sh` | modify | Same skill-hint append + override |
| `bin/consult-research-wait.sh` | modify | Capture `cw_outbox_wait_since` stdout; parse `event=…`; branch on actual event; on `question` write payload + append `OFFSET=<post-question>` + `FS=question` |
| `bin/consult-verify-wait.sh` | modify | Same for `VS=question` |
| `bin/consult-offset-reset.sh` | modify | Add `--keep-findings` flag (used only by Patterns 1 / 3, NOT the question loop) |
| `commands/consult.md` | modify | Step 3 + Step 5 redesign (question loop, NO send-script re-arm); Pattern 4 added; explicit Read findings.md before classify |
| `config/skill-hints/brainstorming.md` | create | Brainstorming-skill prompt + autonomy contract |
| `config/skill-hints/systematic-debugging.md` | create | Systematic-debugging skill prompt + autonomy contract |
| `config/skill-hints/none.md` | create | Empty file (no-op append) |
| `tests/test_consult_classify_topic.sh` | create | Classifier coverage incl. M-tier trigger refinement |
| `tests/test_consult_skill_hint.sh` | create | Send-script appends correct hint file; CW_CONSULT_SKILL_OVERRIDE; PLUGIN_ROOT assertion; skill names resolve to installed SKILL.md |
| `tests/test_consult_question_event.sh` | create | Payload helpers + wait-script catches `question`; malformed-JSON fixtures |
| `tests/test_consult_question_event_priority.sh` | create | H2 closure: wait-script branches on actual matched event; question→error / question→done / multi-question fixtures |
| `tests/test_consult_offset_reset_keep.sh` | create | `--keep-findings` flag behavior |
| `tests/test_consult_question_loop.sh` | create | Mocked round-trip incl. Q→A→Q→A→done and FS=question + VS=question |
| `tests/test_consult_question_dogfood.sh` | create | H3 closure: real-CLI dogfood gated on codex+tmux |
| `tests/test_consult_init.sh` | modify | Assert `skill.txt` written with one of brainstorming/systematic-debugging/none |
| `tests/test_consult_research_wait.sh` | modify | Add question-event case + capture-MATCHED case |
| `tests/test_consult_verify_wait.sh` | modify | Add question-event case + capture-MATCHED case |
| `tests/test_consult_offset_reset.sh` | modify | Pin existing 3-arg signature still works after Task 7 |
| `.claude-plugin/plugin.json` | modify | Bump 0.2.1 → 0.3.0 |
| `.claude-plugin/marketplace.json` | modify | Bump 0.2.1 → 0.3.0 |
| `README.md` | modify | Mention question protocol + skill routing in v0.3 section |

---

## Task 1: Add `cw_consult_classify_topic` lib helper

**Files:**
- Modify: `lib/consult.sh` (append at end of file, before any final closing markers)
- Test: `tests/test_consult_classify_topic.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test_consult_classify_topic.sh`:

```bash
#!/usr/bin/env bash
# tests/test_consult_classify_topic.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/consult.sh

# brainstorming triggers — narrow set per Codex M-tier feedback.
# "design" alone is too broad; require "design pattern" or paired phrases.
assert_eq "$(cw_consult_classify_topic 'how should we approach the auth flow')" "brainstorming" "how should"
assert_eq "$(cw_consult_classify_topic 'design pattern review')"                 "brainstorming" "design pattern"
assert_eq "$(cw_consult_classify_topic 'what is the best way to handle X')"      "brainstorming" "best way"
assert_eq "$(cw_consult_classify_topic 'decide between Postgres and Mongo')"     "brainstorming" "decide between"
assert_eq "$(cw_consult_classify_topic 'How Should We Approach This?')"          "brainstorming" "case-insensitive"
pass "brainstorming triggers fire on design-shaped topics (narrow set)"

# systematic-debugging triggers — fixed name per Codex M4.
assert_eq "$(cw_consult_classify_topic 'why is the consult timing out')"      "systematic-debugging" "why"
assert_eq "$(cw_consult_classify_topic 'find edge cases in the parser')"      "systematic-debugging" "edge case"
assert_eq "$(cw_consult_classify_topic 'login is broken after the merge')"    "systematic-debugging" "broken"
assert_eq "$(cw_consult_classify_topic 'regression in checkout flow')"        "systematic-debugging" "regression"
assert_eq "$(cw_consult_classify_topic 'token-refresh bug fixture')"          "systematic-debugging" "bug"
assert_eq "$(cw_consult_classify_topic 'tests are failing on macOS')"         "systematic-debugging" "failing"
pass "systematic-debugging triggers fire on bug-hunt topics"

# none default — "design" alone, "structure" alone, "approach" alone all → none.
assert_eq "$(cw_consult_classify_topic 'review the auth middleware')"            "none" "plain review"
assert_eq "$(cw_consult_classify_topic 'audit lib/state.sh helpers')"            "none" "audit"
assert_eq "$(cw_consult_classify_topic 'document the IPC protocol')"             "none" "doc task"
assert_eq "$(cw_consult_classify_topic 'review the database structure')"         "none" "structure dropped"
assert_eq "$(cw_consult_classify_topic 'approach to error handling')"            "none" "approach dropped"
assert_eq "$(cw_consult_classify_topic 'design considerations document')"        "none" "design alone dropped"
pass "none is the default for narrow review/audit topics (M-tier refinements)"

# Disambiguation when both word classes appear:
# "audit X for bugs" — bug match, no design-pattern match → systematic-debugging.
assert_eq "$(cw_consult_classify_topic 'audit the structure for bugs')"          "systematic-debugging" "bug overrides absence of design-pattern"
# "design pattern of broken module" — design-pattern wins (priority).
assert_eq "$(cw_consult_classify_topic 'design pattern of the broken module')"   "brainstorming" "design pattern priority over broken"
pass "M-tier disambiguation: design-pattern wins over debugging; bug wins when only debugging matches"

# word-boundary discipline.
assert_eq "$(cw_consult_classify_topic 'designed by Alice last quarter')" "none" "word boundary: designed≠design"
assert_eq "$(cw_consult_classify_topic 'whyever it happened')"            "none" "word boundary: whyever≠why"
assert_eq "$(cw_consult_classify_topic 'debugger output review')"         "none" "word boundary: debugger has no trigger"
pass "word-boundary discipline holds"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_consult_classify_topic.sh`
Expected: FAIL — `cw_consult_classify_topic: command not found`.

- [ ] **Step 3: Implement `cw_consult_classify_topic`**

Append to `lib/consult.sh`:

```bash
# cw_consult_classify_topic <topic-text>
# Echo one of: brainstorming | systematic-debugging | none.
# Brainstorming wins ties. Triggers are case-insensitive, word-boundary-anchored.
# Codex M-tier refinement: "design"/"structure"/"approach" alone do NOT trigger.
cw_consult_classify_topic() {
  local topic="$1"
  local lower
  lower=$(printf '%s' "$topic" | tr '[:upper:]' '[:lower:]')

  # Word-boundary fence: surround triggers with space/punctuation boundaries.
  # Bash =~ uses POSIX ERE — \b is not portable. Replace punctuation with spaces.
  local fenced=" $lower "
  fenced=${fenced//[[:punct:]]/ }
  fenced=$(printf '%s' "$fenced" | tr -s ' ')

  # Brainstorming: tightened triggers. "design pattern" must be adjacent;
  # bare "design" does not trigger. Apostrophe in "what's" is replaced
  # with space by the punct fence, so the regex looks for "what s the best way".
  local brain_re='( design pattern | how should | best way | what s the best way | what is the best way | decide between )'
  local debug_re='( why | broken | failing | regression | edge case | bug | doesn t work | does not work )'

  if [[ "$fenced" =~ $brain_re ]]; then
    printf 'brainstorming\n'
  elif [[ "$fenced" =~ $debug_re ]]; then
    printf 'systematic-debugging\n'
  else
    printf 'none\n'
  fi
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run.sh test_consult_classify_topic.sh` (or `bash tests/test_consult_classify_topic.sh`)
Expected: PASS — all 5 `pass` statements emit.

- [ ] **Step 5: Commit**

```bash
chmod +x tests/test_consult_classify_topic.sh
git add tests/test_consult_classify_topic.sh lib/consult.sh
git commit -m "feat(consult): cw_consult_classify_topic — brainstorming/systematic-debugging/none

Regex-based topic classifier with word-boundary discipline. Brainstorming
wins ties. Triggers tightened per Codex Rev1 M-tier feedback: 'design'
alone, 'structure', 'approach' do NOT match. Used by consult-init to pick
a skill hint per consult run."
```

---

## Task 2: `consult-init.sh` writes `_consult/skill.txt`

**Files:**
- Modify: `bin/consult-init.sh`
- Test: `tests/test_consult_init.sh` (extend)

- [ ] **Step 1: Extend the test (failing case)**

Open `tests/test_consult_init.sh`. Add after the existing `general.txt` block:

```bash
# 2c. skill.txt holds one of {brainstorming, systematic-debugging, none}.
skill=$(cat "$CLONE_WARS_HOME/state/$RH/$topic/_consult/skill.txt")
[[ "$skill" =~ ^(brainstorming|systematic-debugging|none)$ ]] || { echo "FAIL: skill='$skill' not in pool" >&2; exit 1; }
pass "skill.txt holds a valid classifier value"

# 2d. brainstorming-shaped topic produces skill=brainstorming.
topic_brain=$(init_topic "how should we approach the cache layer")
skill_brain=$(cat "$CLONE_WARS_HOME/state/$RH/$topic_brain/_consult/skill.txt")
assert_eq "$skill_brain" "brainstorming" "brainstorming topic classified"
pass "brainstorming-shaped topic auto-selects brainstorming skill"

# 2e. debugging-shaped topic produces skill=systematic-debugging.
topic_dbg=$(init_topic "why is the test suite failing on macOS")
skill_dbg=$(cat "$CLONE_WARS_HOME/state/$RH/$topic_dbg/_consult/skill.txt")
assert_eq "$skill_dbg" "systematic-debugging" "debugging topic classified"
pass "debugging-shaped topic auto-selects systematic-debugging skill"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_consult_init.sh`
Expected: FAIL — `skill.txt missing` (file does not exist).

- [ ] **Step 3: Modify `bin/consult-init.sh`**

After the `general.txt` write (existing v0.2.1 line `printf '%s' "$GENERAL" > "$TOPIC_DIR/_consult/general.txt"`), add:

```bash
SKILL=$(cw_consult_classify_topic "$TOPIC_TEXT")
printf '%s' "$SKILL" > "$TOPIC_DIR/_consult/skill.txt"
log_info "  skill hint:       $SKILL"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_consult_init.sh`
Expected: PASS — all assertions including new `skill.txt` checks.

- [ ] **Step 5: Commit**

```bash
git add bin/consult-init.sh tests/test_consult_init.sh
git commit -m "feat(consult): write _consult/skill.txt during init

Classifies the topic text via cw_consult_classify_topic and persists
the result alongside topic.txt and general.txt. Send-scripts read this
in Task 4 to pick a skill-hint file."
```

---

## Task 3: Skill-hint files (brainstorming, systematic-debugging, none)

**Files:**
- Create: `config/skill-hints/brainstorming.md`
- Create: `config/skill-hints/systematic-debugging.md`
- Create: `config/skill-hints/none.md`
- Test: `tests/test_consult_skill_hint.sh` (skeleton; full assertions land in Task 4)

- [ ] **Step 1: Write the skeleton test**

Create `tests/test_consult_skill_hint.sh`:

```bash
#!/usr/bin/env bash
# tests/test_consult_skill_hint.sh — skill-hint files exist + are well-formed.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

HINTS=../config/skill-hints

[[ -f "$HINTS/brainstorming.md"        ]] || { echo "FAIL: brainstorming.md missing"        >&2; exit 1; }
[[ -f "$HINTS/systematic-debugging.md" ]] || { echo "FAIL: systematic-debugging.md missing" >&2; exit 1; }
[[ -f "$HINTS/none.md"                 ]] || { echo "FAIL: none.md missing"                 >&2; exit 1; }
pass "all three skill-hint files exist"

# none.md must be empty (or whitespace only).
[[ ! -s "$HINTS/none.md" ]] || [[ -z "$(tr -d '[:space:]' < "$HINTS/none.md")" ]] \
  || { echo "FAIL: none.md must be empty for no-op append" >&2; exit 1; }
pass "none.md is empty"

# brainstorming + systematic-debugging must mention the autonomy contract.
grep -q 'AUTONOMY CONTRACT' "$HINTS/brainstorming.md"        || { echo "FAIL: brainstorming.md missing autonomy contract"        >&2; exit 1; }
grep -q 'AUTONOMY CONTRACT' "$HINTS/systematic-debugging.md" || { echo "FAIL: systematic-debugging.md missing autonomy contract" >&2; exit 1; }
pass "both hints contain AUTONOMY CONTRACT"

# Both must mention the question event format.
grep -q '"event":"question"' "$HINTS/brainstorming.md"        || { echo "FAIL: brainstorming.md missing question event format"        >&2; exit 1; }
grep -q '"event":"question"' "$HINTS/systematic-debugging.md" || { echo "FAIL: systematic-debugging.md missing question event format" >&2; exit 1; }
pass "question event format documented in both hints"

# Both must mention the ANSWER: parse contract.
grep -q 'ANSWER:' "$HINTS/brainstorming.md"        || { echo "FAIL: brainstorming.md missing ANSWER: contract"        >&2; exit 1; }
grep -q 'ANSWER:' "$HINTS/systematic-debugging.md" || { echo "FAIL: systematic-debugging.md missing ANSWER: contract" >&2; exit 1; }
pass "ANSWER: response contract documented in both hints"

# M4 closure: skill names mentioned in hint files must resolve to an
# installed SKILL.md somewhere under ~/.claude/plugins/cache (or codex
# equivalent). This test runs only when the user has superpowers installed;
# skip otherwise.
SKILL_ROOTS=(
  "$HOME/.claude/plugins/cache"
  "$HOME/.codex/superpowers/skills"
)
resolve_skill() {
  local name="$1"
  local root path
  for root in "${SKILL_ROOTS[@]}"; do
    [[ -d "$root" ]] || continue
    path=$(find "$root" -maxdepth 6 -type d -name "$name" 2>/dev/null | head -n1)
    if [[ -n "$path" && -f "$path/SKILL.md" ]]; then return 0; fi
  done
  return 1
}
if resolve_skill brainstorming; then
  pass "superpowers:brainstorming resolves to an installed SKILL.md"
else
  echo "SKIP: superpowers:brainstorming not installed in this env"
fi
if resolve_skill systematic-debugging; then
  pass "superpowers:systematic-debugging resolves to an installed SKILL.md"
else
  echo "SKIP: superpowers:systematic-debugging not installed in this env"
fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_consult_skill_hint.sh`
Expected: FAIL — `brainstorming.md missing`.

- [ ] **Step 3: Create the three files**

Create `config/skill-hints/none.md` (empty file):

```bash
mkdir -p config/skill-hints
: > config/skill-hints/none.md
```

Create `config/skill-hints/brainstorming.md`:

```markdown
SKILL HINT — this consult is design-shaped.

Use the `superpowers:brainstorming` skill to structure your thinking. The
skill normally asks design questions one at a time; the protocol below
lets you do that without deadlocking the consult.

AUTONOMY CONTRACT

This consult is automated. The skill you invoke may try to ask design
questions one at a time. You may ask questions back to the Jedi general
via your outbox, but follow these rules:

1. Ask ONE question at a time. Wait for the answer before asking the next.

2. To ask: append to your outbox.jsonl:
     {"event":"question","text":"<your question>","options":["A","B"]}
   Set your status to "blocked". Poll your inbox.md for a new write.
   When inbox.md changes, read the line beginning "ANSWER: " — that is
   the response. Resume your skill loop with it.

3. CHARACTER ENCODING (Rev3): in the question's "text" and "options"
   fields, you MUST percent-encode special characters instead of using
   JSON escapes. The general's parser is line-based and rejects payloads
   with backslash escapes. Encoding map:
     newline      →  %0A
     tab          →  %09
     double-quote →  %22
     backslash    →  %5C
   Example: instead of {"text":"He said \"hi\""} write
   {"text":"He said %22hi%22"}. The general decodes %xx before
   answering; you receive plain text in the ANSWER line.

4. Do not pre-classify questions as critical/non-critical. The general
   makes that call. Just ask plainly.

5. Be concrete. "Should we use Postgres or DynamoDB?" is good.
   "What database?" is too open — answer it yourself with a default.

6. Document each Q&A in your findings.md as:
     [Q&A] question: <q> // answer: <a> (resolved by general)
   This lets the consult reader see the design choices that shaped the
   findings.

7. If the skill says "ask the user X", you ask the GENERAL X via this
   protocol. The general will relay to the user only if the question is
   critical. Otherwise the general answers from topic context.
```

Create `config/skill-hints/systematic-debugging.md`:

```markdown
SKILL HINT — this consult is bug-hunt shaped.

Use the `superpowers:systematic-debugging` skill to structure your investigation.
The skill walks through hypothesis → reproduction → root cause; the
protocol below lets you ask grounding questions without deadlocking
the consult.

AUTONOMY CONTRACT

This consult is automated. The skill you invoke may try to ask
clarifying questions one at a time. You may ask questions back to the
Jedi general via your outbox, but follow these rules:

1. Ask ONE question at a time. Wait for the answer before asking the next.

2. To ask: append to your outbox.jsonl:
     {"event":"question","text":"<your question>","options":["A","B"]}
   Set your status to "blocked". Poll your inbox.md for a new write.
   When inbox.md changes, read the line beginning "ANSWER: " — that is
   the response. Resume your skill loop with it.

3. CHARACTER ENCODING (Rev3): in the question's "text" and "options"
   fields, percent-encode special characters instead of JSON escapes:
     newline → %0A, tab → %09, " → %22, \ → %5C.
   The general's parser rejects payloads with backslash escapes.

4. Do not pre-classify questions as critical/non-critical. The general
   makes that call. Just ask plainly.

5. Be concrete. "Is the error from the Postgres driver or our wrapper?"
   is good. "What's wrong?" is too open — investigate first.

6. Document each Q&A in your findings.md as:
     [Q&A] question: <q> // answer: <a> (resolved by general)

7. If the skill says "ask the user X", you ask the GENERAL X via this
   protocol. The general will relay to the user only if the question is
   critical. Otherwise the general answers from topic context.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_consult_skill_hint.sh`
Expected: PASS — all 5 assertions.

- [ ] **Step 5: Commit**

```bash
chmod +x tests/test_consult_skill_hint.sh
git add config/skill-hints tests/test_consult_skill_hint.sh
git commit -m "feat(consult): skill-hint files (brainstorming, systematic-debugging, none)

Three files under config/skill-hints/. brainstorming.md +
systematic-debugging.md share the autonomy contract by literal
duplication (more robust than partial include). none.md is empty
for no-op append. Skill names are validated against installed
SKILL.md (Codex Rev1 M4 closure)."
```

---

## Task 4: Send-scripts append the skill hint

**Files:**
- Modify: `bin/consult-research-send.sh`
- Modify: `bin/consult-verify-send.sh`
- Modify: `lib/consult.sh` (add `cw_consult_skill_hint_append` helper)
- Test: `tests/test_consult_skill_hint.sh` (extend with send-script integration)

- [ ] **Step 1: Extend the test (failing case)**

Append to `tests/test_consult_skill_hint.sh`:

```bash
# Integration: when a state dir has skill.txt = brainstorming, the prompt
# generated by consult-research-send.sh contains the skill-hint content.
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"
export CLAUDE_PLUGIN_ROOT="$(cd .. && pwd)"

source ../lib/state.sh
RH=$(cw_repo_hash)
TOPIC=$(../bin/consult-init.sh "design pattern for the cache" | sed -n '1p')
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC/_consult"

# Pre-flight: skill.txt should be brainstorming (set by consult-init).
assert_eq "$(cat "$TD/skill.txt")" "brainstorming" "init wrote brainstorming skill"

# Build the prompt manually using the same lib helpers consult-research-send uses.
# (We can't run the full send.sh because there's no spawned trooper; we test the
# prompt-building in isolation via the new helper.)
source ../lib/consult.sh
PROMPT=$(cw_consult_skill_hint_append "$TD/skill.txt" "BASE PROMPT")

echo "$PROMPT" | grep -q "^BASE PROMPT$" || { echo "FAIL: base prompt preserved"     >&2; exit 1; }
echo "$PROMPT" | grep -q "AUTONOMY CONTRACT" || { echo "FAIL: hint appended"          >&2; exit 1; }
pass "skill-hint append wires brainstorming hint after base prompt"

# none case: no append.
echo none > "$TD/skill.txt"
PROMPT_NONE=$(cw_consult_skill_hint_append "$TD/skill.txt" "BASE PROMPT")
[[ "$PROMPT_NONE" == "BASE PROMPT" ]] || { echo "FAIL: none should not append; got: $PROMPT_NONE" >&2; exit 1; }
pass "skill=none produces no append"

# missing skill.txt case: defaults to none (no append).
rm -f "$TD/skill.txt"
PROMPT_MISSING=$(cw_consult_skill_hint_append "$TD/skill.txt" "BASE PROMPT")
[[ "$PROMPT_MISSING" == "BASE PROMPT" ]] || { echo "FAIL: missing skill.txt should default to none" >&2; exit 1; }
pass "missing skill.txt defaults to no append"

# CW_CONSULT_SKILL_OVERRIDE=none forces no append even if skill.txt says brainstorming.
echo brainstorming > "$TD/skill.txt"
PROMPT_OVR=$(CW_CONSULT_SKILL_OVERRIDE=none cw_consult_skill_hint_append "$TD/skill.txt" "BASE PROMPT")
[[ "$PROMPT_OVR" == "BASE PROMPT" ]] || { echo "FAIL: CW_CONSULT_SKILL_OVERRIDE=none should force no-append; got: $PROMPT_OVR" >&2; exit 1; }
pass "CW_CONSULT_SKILL_OVERRIDE=none kill-switch works"

# PLUGIN_ROOT unset → loud failure (rc=2), not silent no-append.
PLUGIN_ROOT_BAK="$PLUGIN_ROOT"; CC_BAK="${CLAUDE_PLUGIN_ROOT:-}"
unset PLUGIN_ROOT CLAUDE_PLUGIN_ROOT
echo brainstorming > "$TD/skill.txt"
err=$(cw_consult_skill_hint_append "$TD/skill.txt" "BASE PROMPT" 2>&1) && rc=0 || rc=$?
PLUGIN_ROOT="$PLUGIN_ROOT_BAK"; export CLAUDE_PLUGIN_ROOT="$CC_BAK"
[[ "$rc" -eq 2 ]] && echo "$err" | grep -q "PLUGIN_ROOT" \
  || { echo "FAIL: missing PLUGIN_ROOT should rc=2 + emit error; got rc=$rc, err=$err" >&2; exit 1; }
pass "missing PLUGIN_ROOT/CLAUDE_PLUGIN_ROOT fails loud"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_consult_skill_hint.sh`
Expected: FAIL — `cw_consult_skill_hint_append: command not found`.

- [ ] **Step 3: Add the lib helper**

Append to `lib/consult.sh`:

```bash
# cw_consult_skill_hint_append <skill-txt-path> <base-prompt>
# Echoes base-prompt followed by the skill-hint content (if any).
# Missing skill.txt or skill=none → base-prompt unchanged.
# CW_CONSULT_SKILL_OVERRIDE=none in env forces 'none' (kill-switch).
# PLUGIN_ROOT (or CLAUDE_PLUGIN_ROOT) MUST be set — fail loud, not silent.
cw_consult_skill_hint_append() {
  local skill_path="$1"
  local base="$2"
  local plugin_root="${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}"
  [[ -n "$plugin_root" ]] \
    || { echo "cw_consult_skill_hint_append: PLUGIN_ROOT/CLAUDE_PLUGIN_ROOT unset" >&2; return 2; }

  local skill="none"
  [[ -f "$skill_path" ]] && skill=$(tr -d '[:space:]' < "$skill_path")
  # Env-var kill-switch (Codex Rev1 low-tier closure).
  [[ "${CW_CONSULT_SKILL_OVERRIDE:-}" == "none" ]] && skill="none"

  case "$skill" in
    brainstorming|systematic-debugging) : ;;
    *) printf '%s' "$base"; return 0 ;;
  esac
  local hint_file="$plugin_root/config/skill-hints/$skill.md"
  [[ -f "$hint_file" ]] || { printf '%s' "$base"; return 0; }
  printf '%s\n\n---\n\n' "$base"
  cat "$hint_file"
}
```

- [ ] **Step 4: Wire the helper into send-scripts**

Modify `bin/consult-research-send.sh`. Replace the line:

```bash
cw_consult_build_research_prompt "$TOPIC_TEXT" "$TROOPER_DIR/findings.md" > "$PROMPT_FILE"
```

with:

```bash
BASE_PROMPT=$(cw_consult_build_research_prompt "$TOPIC_TEXT" "$TROOPER_DIR/findings.md")
cw_consult_skill_hint_append "$ART_DIR/skill.txt" "$BASE_PROMPT" > "$PROMPT_FILE"
```

Same change in `bin/consult-verify-send.sh` for the `cw_consult_build_verify_prompt` call (find it; the structure is identical).

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/test_consult_skill_hint.sh`
Expected: PASS — all 8 `pass` statements.

Also re-run `bash tests/test_consult_research_send.sh` and `bash tests/test_consult_verify_send.sh` to make sure existing send-script tests still pass (they don't write skill.txt, so default to none — should be no-op).

- [ ] **Step 6: Commit**

```bash
git add lib/consult.sh bin/consult-research-send.sh bin/consult-verify-send.sh tests/test_consult_skill_hint.sh
git commit -m "feat(consult): skill-hint append in research/verify send scripts

Send-scripts read _consult/skill.txt and append the matching hint file
to the base prompt. Missing skill.txt or skill=none → no append (full
backwards compat with v0.2 state dirs)."
```

---

## Task 5: `question` payload helpers in `lib/consult.sh`

**Files:**
- Modify: `lib/consult.sh`
- Test: `tests/test_consult_question_event.sh` (skeleton; wait-script integration in Task 6)

- [ ] **Step 1: Write the failing test (helper-only portion)**

Create `tests/test_consult_question_event.sh`:

```bash
#!/usr/bin/env bash
# tests/test_consult_question_event.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/consult.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# 1. Write + read payload round-trip (free-form question, no options).
cw_consult_question_payload_write "$TMP/q.txt" \
  "Should we use Postgres or DynamoDB for the metadata store?" "" "research"

[[ -f "$TMP/q.txt" ]] || { echo "FAIL: payload file not written" >&2; exit 1; }
grep -q '^TEXT='     "$TMP/q.txt" || { echo "FAIL: TEXT= line missing"     >&2; exit 1; }
grep -q '^PHASE='    "$TMP/q.txt" || { echo "FAIL: PHASE= line missing"    >&2; exit 1; }
grep -q '^ASKED_AT=' "$TMP/q.txt" || { echo "FAIL: ASKED_AT= line missing" >&2; exit 1; }
pass "payload write produces TEXT/PHASE/ASKED_AT lines"

read_text=$(cw_consult_question_payload_read "$TMP/q.txt" TEXT)
[[ "$read_text" == "Should we use Postgres or DynamoDB for the metadata store?" ]] \
  || { echo "FAIL: read text mismatch: '$read_text'" >&2; exit 1; }
pass "payload read TEXT round-trips"

read_phase=$(cw_consult_question_payload_read "$TMP/q.txt" PHASE)
assert_eq "$read_phase" "research" "PHASE round-trip"
pass "payload read PHASE round-trips"

# 2. Multi-line text gets percent-encoded then decoded back.
cw_consult_question_payload_write "$TMP/q2.txt" \
  $'Line one\nLine two\nLine three' "A|B" "verify"
read_text2=$(cw_consult_question_payload_read "$TMP/q2.txt" TEXT)
[[ "$read_text2" == $'Line one\nLine two\nLine three' ]] \
  || { echo "FAIL: multi-line round-trip broken: $(printf '%q' "$read_text2")" >&2; exit 1; }
pass "multi-line text round-trips via %0A encoding"

# 3. OPTIONS line round-trips.
read_opts=$(cw_consult_question_payload_read "$TMP/q2.txt" OPTIONS)
assert_eq "$read_opts" "A|B" "OPTIONS round-trip"
pass "OPTIONS pipe-list round-trips"

# 4. Missing OPTIONS produces empty string.
read_opts_empty=$(cw_consult_question_payload_read "$TMP/q.txt" OPTIONS)
[[ -z "$read_opts_empty" ]] || { echo "FAIL: missing OPTIONS should be empty: '$read_opts_empty'" >&2; exit 1; }
pass "missing OPTIONS reads as empty"

# === M5 closure: validation + malformed-input fixtures ===
# 5. Valid question line passes validation.
cw_consult_question_validate_line '{"event":"question","text":"hi","options":["A"]}' \
  || { echo "FAIL: valid question line should pass validation" >&2; exit 1; }
pass "valid question line validates"

# 6. Missing text field fails validation.
cw_consult_question_validate_line '{"event":"question","options":["A"]}' \
  && { echo "FAIL: missing text should fail validation" >&2; exit 1; } || true
pass "missing text fails validation"

# 7. Empty text fails validation.
cw_consult_question_validate_line '{"event":"question","text":"","options":["A"]}' \
  && { echo "FAIL: empty text should fail validation" >&2; exit 1; } || true
pass "empty text fails validation"

# 8. Non-question event fails validation.
cw_consult_question_validate_line '{"event":"done"}' \
  && { echo "FAIL: non-question event should fail validation" >&2; exit 1; } || true
pass "non-question event fails validation"

# 9. extract_to_payload writes payload only on valid input.
cw_consult_question_extract_to_payload '{"event":"question","text":"ok","options":["yes","no"]}' \
  "$TMP/q3.txt" "research"
[[ -f "$TMP/q3.txt" ]] || { echo "FAIL: payload should be written on valid input" >&2; exit 1; }
assert_eq "$(cw_consult_question_payload_read "$TMP/q3.txt" TEXT)"    "ok"        "extract TEXT round-trip"
assert_eq "$(cw_consult_question_payload_read "$TMP/q3.txt" OPTIONS)" "yes|no"    "extract OPTIONS pipe-encoded"
pass "extract_to_payload writes valid payload"

# 10. extract_to_payload refuses malformed input — no file written.
rm -f "$TMP/q4.txt"
cw_consult_question_extract_to_payload '{"event":"question","options":[]}' \
  "$TMP/q4.txt" "research" && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: extract should fail on missing text" >&2; exit 1; }
[[ ! -f "$TMP/q4.txt" ]] || { echo "FAIL: payload should not be written on malformed input" >&2; exit 1; }
pass "extract_to_payload rejects missing-text input"

# 11. Empty options array → OPTIONS empty (no pipe garbage).
cw_consult_question_extract_to_payload '{"event":"question","text":"x","options":[]}' \
  "$TMP/q5.txt" "research"
[[ -z "$(cw_consult_question_payload_read "$TMP/q5.txt" OPTIONS)" ]] \
  || { echo "FAIL: empty options should produce empty OPTIONS" >&2; exit 1; }
pass "empty options array round-trips as empty OPTIONS"

# === Rev3 escaped-quote fail-closed (Codex Rev2 M-tier) ===
# 12. Escaped quotes in text → validator REJECTS (rather than mis-extracting
#     to truncated text). This is intentional fail-closed: the autonomy
#     contract instructs the trooper to percent-encode special characters,
#     so escaped JSON quotes shouldn't appear in well-formed payloads.
cw_consult_question_validate_line '{"event":"question","text":"He said \"hi\"","options":[]}' \
  && { echo "FAIL: escaped-quote text should fail validation (fail-closed)" >&2; exit 1; } || true
pass "Rev3 escaped-quote fail-closed: payload with \\\" rejected"

# 13. Backslash in text → also rejected (\\n, \\t, \\\\, etc. all corrupt sed).
cw_consult_question_validate_line '{"event":"question","text":"line1\nline2","options":[]}' \
  && { echo "FAIL: backslash text should fail validation" >&2; exit 1; } || true
pass "Rev3 backslash fail-closed: payload with \\n rejected"

# 14. extract_to_payload rejects escaped-quote input — no payload written.
rm -f "$TMP/q6.txt"
cw_consult_question_extract_to_payload \
  '{"event":"question","text":"He said \"hi\"","options":[]}' "$TMP/q6.txt" "research" \
  && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: extract should fail on escaped-quote input" >&2; exit 1; }
[[ ! -f "$TMP/q6.txt" ]] || { echo "FAIL: payload should not be written for escaped-quote" >&2; exit 1; }
pass "Rev3 escaped-quote: extract refuses to write payload"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_consult_question_event.sh`
Expected: FAIL — `cw_consult_question_payload_write: command not found`.

- [ ] **Step 3: Add the helpers**

Append to `lib/consult.sh`:

```bash
# cw_consult_question_payload_write <file> <text> <options-pipe-or-empty> <phase>
# Atomic write (tmp + mv). Multi-line TEXT is percent-encoded via %0A.
cw_consult_question_payload_write() {
  local file="$1" text="$2" options="$3" phase="$4"
  local encoded
  encoded=${text//$'\n'/%0A}
  local tmp="$file.tmp.$$"
  {
    printf 'TEXT=%s\n'     "$encoded"
    [[ -n "$options" ]] && printf 'OPTIONS=%s\n' "$options"
    printf 'PHASE=%s\n'    "$phase"
    printf 'ASKED_AT=%s\n' "$(date +%s)"
  } > "$tmp"
  mv "$tmp" "$file"
}

# cw_consult_question_payload_read <file> <key>
# Echo the value for KEY. Decodes %0A back to newline for TEXT.
cw_consult_question_payload_read() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 1
  local raw
  raw=$(awk -F= -v k="$key" '$1==k { sub(/^[^=]*=/, ""); print; exit }' "$file")
  if [[ "$key" == "TEXT" ]]; then
    raw=${raw//%0A/$'\n'}
  fi
  printf '%s' "$raw"
}

# cw_consult_question_validate_line <json-line>
# Returns 0 if the line is a parseable {"event":"question",...} with non-empty
# text AND no JSON escapes (which the sed extractor cannot handle). Returns
# rc=1 otherwise. Used by wait-script to gate FS=question vs FS=failed
# (Codex Rev1 M5 closure + Rev2 M-tier escaped-quote tightening).
#
# Rev3 fail-closed policy: payloads containing backslash escapes
# (\", \\, \n, \t, \uXXXX, etc.) are REJECTED rather than mis-extracted.
# The trooper must percent-encode special characters via the autonomy
# contract instead. A real JSON decoder is deferred to v0.3.1+.
cw_consult_question_validate_line() {
  local line="$1"
  [[ "$line" == *'"event":"question"'* ]] || return 1
  # Require a "text":"..." field with non-empty content (no escaped quotes
  # — escaped quotes would slip through [^"]+ and corrupt extraction).
  printf '%s' "$line" | grep -qE '"text":"[^"\\]+"' || return 1
  return 0
}

# cw_consult_question_extract_to_payload <json-line> <payload-path> <phase>
# Validates + extracts the question event into the payload file format
# expected by cw_consult_question_payload_read. Returns rc=0 on success,
# rc=1 on validation/parse failure (no payload written).
cw_consult_question_extract_to_payload() {
  local line="$1" path="$2" phase="$3"
  cw_consult_question_validate_line "$line" || return 1
  local text opts
  text=$(printf '%s' "$line" | sed -n 's/.*"text":"\([^"]*\)".*/\1/p')
  [[ -n "$text" ]] || return 1
  opts=$(printf '%s' "$line" | sed -n 's/.*"options":\[\([^]]*\)\].*/\1/p' \
                              | sed 's/"//g; s/, */|/g; s/,/|/g')
  cw_consult_question_payload_write "$path" "$text" "$opts" "$phase"
}

# cw_consult_outbox_match_endbyte <outbox-path> <start-offset> <matched-line>
# Rev3 H2-race fix: the wait-script's old approach was NEW_OFFSET=$(wc -c < outbox)
# AFTER cw_outbox_wait_since returned — but the trooper might have written more
# events in that window, silently skipping them. This helper instead returns
# start-offset + bytes-up-to-and-including the matched line — the exact byte
# position past which the next wait should resume.
#
# Echoes the byte-position; rc=0 if matched line found in tail starting at
# start-offset; rc=1 if not found. Callers fall back to start-offset on rc=1.
cw_consult_outbox_match_endbyte() {
  local outbox="$1" start="$2" matched="$3"
  [[ -f "$outbox" ]] || return 1
  local pos=$start
  local line
  while IFS= read -r line; do
    # +1 for the trailing newline that read -r stripped.
    pos=$(( pos + ${#line} + 1 ))
    if [[ "$line" == "$matched" ]]; then
      printf '%s\n' "$pos"
      return 0
    fi
  done < <(tail -c "+$(( start + 1 ))" "$outbox")
  return 1
}
```

> **Byte-vs-character note:** `${#line}` is character count, not byte count.
> Our outbox JSON is ASCII-only by protocol (multi-byte content is
> percent-encoded by the trooper), so character count = byte count and the
> arithmetic is exact. If the protocol relaxes this in the future, switch
> to `LC_ALL=C` + `awk 'length($0)'` for byte-mode length.

(The old `cw_consult_question_extract_from_outbox` is replaced — see Task 6
for the wait-script call site that uses these helpers.)

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_consult_question_event.sh`
Expected: PASS — all 6 `pass` statements (helper portion only).

- [ ] **Step 5: Commit**

```bash
chmod +x tests/test_consult_question_event.sh
git add lib/consult.sh tests/test_consult_question_event.sh
git commit -m "feat(consult): cw_consult_question_payload_{read,write}

Atomic key=value file format for trooper-question payloads. Multi-line
TEXT is percent-encoded as %0A. Used by wait-scripts in Task 6."
```

---

## Task 6: Wait-scripts handle the `question` event (capture matched event)

**H1 + H2 closure.** Wait-script captures `cw_outbox_wait_since` stdout and
branches on the actual matched event — no rescan of the outbox. On a
question match, the script auto-appends `OFFSET=<post-question>` to the
state file so the directive's re-arm is wait-script-only (no send-script).

**Files:**
- Modify: `bin/consult-research-wait.sh`
- Modify: `bin/consult-verify-wait.sh`
- Test: `tests/test_consult_question_event.sh` (extend with wait-script)
- Test: `tests/test_consult_question_event_priority.sh` (NEW — H2 closure)
- Test: `tests/test_consult_research_wait.sh` (extend)
- Test: `tests/test_consult_verify_wait.sh` (extend)

- [ ] **Step 1: Extend `tests/test_consult_question_event.sh` with wait-script integration**

Append to `tests/test_consult_question_event.sh`:

```bash
# === wait-script integration ===
# Build a fake state dir + fake outbox where the LAST event after the
# stored OFFSET is a question. Run consult-research-wait.sh and assert
# FS=question + question-<commander>.txt was created.

export CLONE_WARS_HOME="$TMP/cw"
export CLAUDE_PLUGIN_ROOT="$(cd .. && pwd)"
source ../lib/state.sh

RH=$(cw_repo_hash)
TOPIC=$(../bin/consult-init.sh "edge cases in parser" | sed -n '1p')
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
mkdir -p "$TD/rex-codex"
OUTBOX="$TD/rex-codex/outbox.jsonl"
touch "$OUTBOX"
# Pre-question events that the OFFSET will skip past.
echo '{"event":"ready"}' >> "$OUTBOX"
echo '{"event":"ack"}'   >> "$OUTBOX"
OFFSET=$(wc -c < "$OUTBOX" | tr -d ' ')
# Now write the question.
echo '{"event":"question","text":"Use sync or async?","options":["sync","async"]}' >> "$OUTBOX"

# Stage the per-commander state file as if research-send had written it.
printf 'OFFSET=%s\n' "$OFFSET" > "$TD/_consult/research-rex.txt"

# Run the wait-script with a tight timeout (it should match immediately).
CW_CONSULT_RESEARCH_TIMEOUT_OVERRIDE=5 \
  ../bin/consult-research-wait.sh "$TOPIC" rex codex >/dev/null 2>&1 || rc=$?

grep -q '^FS=question$' "$TD/_consult/research-rex.txt" \
  || { echo "FAIL: FS=question not appended"; cat "$TD/_consult/research-rex.txt"; exit 1; }
pass "wait-script appends FS=question on question event"

[[ -f "$TD/_consult/question-rex.txt" ]] \
  || { echo "FAIL: question-rex.txt not written" >&2; exit 1; }
pass "wait-script wrote question-rex.txt payload"

q_text=$(cw_consult_question_payload_read "$TD/_consult/question-rex.txt" TEXT)
[[ "$q_text" == "Use sync or async?" ]] \
  || { echo "FAIL: question text not extracted: '$q_text'" >&2; exit 1; }
pass "question text extracted from outbox event correctly"

q_opts=$(cw_consult_question_payload_read "$TD/_consult/question-rex.txt" OPTIONS)
assert_eq "$q_opts" "sync|async" "OPTIONS pipe-encoded"
pass "question options extracted (JSON array → pipe list)"

q_phase=$(cw_consult_question_payload_read "$TD/_consult/question-rex.txt" PHASE)
assert_eq "$q_phase" "research" "PHASE recorded"
pass "question phase recorded as 'research'"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_consult_question_event.sh`
Expected: FAIL — wait-script doesn't recognize `question` events yet (FS won't be `question`).

- [ ] **Step 3: Update `bin/consult-research-wait.sh` (capture matched event)**

Replace the existing wait + FS-write block. Old code:

```bash
cw_outbox_wait_since "$COMMANDER" "$MODEL" "$TOPIC" "$OFFSET" done error "$TIMEOUT" >/dev/null || true
TROOPER_DIR=$(cw_trooper_dir "$COMMANDER" "$MODEL" "$TOPIC")
FS=$(cw_consult_findings_status "$TROOPER_DIR/findings.md")
printf 'FS=%s\n' "$FS" >> "$STATE_FILE"
```

New code (capture stdout, branch on actual event):

```bash
TROOPER_DIR=$(cw_trooper_dir "$COMMANDER" "$MODEL" "$TOPIC")
OUTBOX="$TROOPER_DIR/outbox.jsonl"

# Block until any awaited event appears past OFFSET. Discard wait_since's
# stdout — it returns LAST-match per event type (tail -n1), but Rev3
# serialization requires FIRST-match across all event types. We re-scan
# the tail ourselves below (head -n1) to honor that contract without
# changing wait_since's v0.2 behavior.
cw_outbox_wait_since "$COMMANDER" "$MODEL" "$TOPIC" "$OFFSET" \
                      done error question "$TIMEOUT" >/dev/null || true

# Rev3 priority + race fix:
#   1. Terminal events (done/error) WIN over mid-state question events. If
#      a trooper emits question then died (error) or finished (done), the
#      terminal event is what matters; the in-flight question is dropped.
#   2. Among questions, take FIRST (grep -m1) for serialization — multiple
#      queued questions get processed one at a time across re-arms.
#   3. NEW_OFFSET is computed from the matched line's exact end-byte (NOT
#      from `wc -c $OUTBOX`), so events written after the match aren't
#      silently consumed.
TAIL=$(tail -c "+$(( OFFSET + 1 ))" "$OUTBOX" 2>/dev/null || true)
MATCHED=$(printf '%s\n' "$TAIL" | grep -m1 -E '"event":"(done|error)"' || true)
[[ -z "$MATCHED" ]] \
  && MATCHED=$(printf '%s\n' "$TAIL" | grep -m1 '"event":"question"' || true)
EVENT=$(printf '%s' "$MATCHED" | sed -n 's/.*"event":"\([^"]*\)".*/\1/p')

if [[ -n "$MATCHED" ]]; then
  NEW_OFFSET=$(cw_consult_outbox_match_endbyte "$OUTBOX" "$OFFSET" "$MATCHED" 2>/dev/null) \
    || NEW_OFFSET="$OFFSET"
else
  NEW_OFFSET="$OFFSET"
fi

case "$EVENT" in
  question)
    if cw_consult_question_extract_to_payload \
         "$MATCHED" "$ART_DIR/question-$COMMANDER.txt" "research"; then
      printf 'OFFSET=%s\n' "$NEW_OFFSET" >> "$STATE_FILE"   # last-wins on re-arm
      printf 'FS=question\n' >> "$STATE_FILE"
      log_info "[research-wait] $COMMANDER FS=question (offset → $NEW_OFFSET)"
    else
      # M5 closure: malformed payload → failed, never question.
      printf 'FS=failed\n' >> "$STATE_FILE"
      log_warn "[research-wait] $COMMANDER FS=failed (malformed question payload)"
    fi
    ;;
  done)
    FS=$(cw_consult_findings_status "$TROOPER_DIR/findings.md")
    printf 'FS=%s\n' "$FS" >> "$STATE_FILE"
    log_info "[research-wait] $COMMANDER FS=$FS"
    ;;
  error)
    printf 'FS=failed\n' >> "$STATE_FILE"
    log_warn "[research-wait] $COMMANDER FS=failed (error event)"
    ;;
  '')   # timeout — no match within window
    printf 'FS=timeout\n' >> "$STATE_FILE"
    log_warn "[research-wait] $COMMANDER FS=timeout"
    ;;
  *)
    printf 'FS=failed\n' >> "$STATE_FILE"
    log_warn "[research-wait] $COMMANDER FS=failed (unknown event '$EVENT')"
    ;;
esac
```

- [ ] **Step 4: Update `bin/consult-verify-wait.sh` symmetrically**

Same change shape, but with `verify` instead of `research`, `VS=` instead
of `FS=`, `cw_consult_verify_status` instead of `cw_consult_findings_status`,
and `verify.md` instead of `findings.md`.

- [ ] **Step 5: Add `tests/test_consult_question_event_priority.sh` (H2 closure)**

This is the new fixture proving wait-script branches on the actual matched event.

```bash
#!/usr/bin/env bash
# tests/test_consult_question_event_priority.sh — H2 closure: wait-script
# must branch on cw_outbox_wait_since's actual match, not rescan for question.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"
export CLAUDE_PLUGIN_ROOT="$(cd .. && pwd)"
source ../lib/state.sh
RH=$(cw_repo_hash)

stage_topic() {
  # Args: <topic-text>
  local topic; topic=$(../bin/consult-init.sh "$1" | sed -n '1p')
  local td="$CLONE_WARS_HOME/state/$RH/$topic"
  mkdir -p "$td/rex-codex"
  printf '%s' "$td"
}

# Case 1: question THEN error → wait_since returns 'error' (last match wins);
# wait-script must set FS=failed, NOT FS=question.
TD=$(stage_topic "case1 q-then-error")
OUTBOX="$TD/rex-codex/outbox.jsonl"
echo '{"event":"ack"}'                                            >> "$OUTBOX"
OFFSET=$(wc -c < "$OUTBOX" | tr -d ' ')
echo '{"event":"question","text":"x","options":[]}'                >> "$OUTBOX"
echo '{"event":"error","text":"trooper died"}'                    >> "$OUTBOX"
TOPIC=$(basename "$TD")
printf 'OFFSET=%s\n' "$OFFSET" > "$TD/_consult/research-rex.txt"
CW_CONSULT_RESEARCH_TIMEOUT_OVERRIDE=5 \
  ../bin/consult-research-wait.sh "$TOPIC" rex codex >/dev/null 2>&1
FS=$(grep '^FS=' "$TD/_consult/research-rex.txt" | tail -1 | cut -d= -f2)
[[ "$FS" == "failed" ]] \
  || { echo "FAIL case1: expected FS=failed when error follows question; got '$FS'"; exit 1; }
[[ ! -f "$TD/_consult/question-rex.txt" ]] \
  || { echo "FAIL case1: payload should NOT be written when terminal event is error"; exit 1; }
pass "case 1 (question→error): FS=failed, no payload"

# Case 2: question THEN done → wait_since returns 'done'; FS depends on findings.md.
TD=$(stage_topic "case2 q-then-done")
OUTBOX="$TD/rex-codex/outbox.jsonl"
echo '{"event":"ack"}'                              >> "$OUTBOX"
OFFSET=$(wc -c < "$OUTBOX" | tr -d ' ')
echo '{"event":"question","text":"x","options":[]}' >> "$OUTBOX"
echo '{"event":"done"}'                             >> "$OUTBOX"
echo "valid findings"      > "$TD/rex-codex/findings.md"
echo "[citation] sample"   >> "$TD/rex-codex/findings.md"
TOPIC=$(basename "$TD")
printf 'OFFSET=%s\n' "$OFFSET" > "$TD/_consult/research-rex.txt"
CW_CONSULT_RESEARCH_TIMEOUT_OVERRIDE=5 \
  ../bin/consult-research-wait.sh "$TOPIC" rex codex >/dev/null 2>&1
FS=$(grep '^FS=' "$TD/_consult/research-rex.txt" | tail -1 | cut -d= -f2)
[[ "$FS" == "ok" ]] \
  || { echo "FAIL case2: expected FS=ok when done follows question; got '$FS'"; exit 1; }
pass "case 2 (question→done): FS=ok (terminal done wins over earlier question)"

# Case 3: only question → FS=question, OFFSET advances past it.
TD=$(stage_topic "case3 question-only")
OUTBOX="$TD/rex-codex/outbox.jsonl"
echo '{"event":"ack"}'                              >> "$OUTBOX"
OFFSET=$(wc -c < "$OUTBOX" | tr -d ' ')
echo '{"event":"question","text":"sync or async?","options":["sync","async"]}' >> "$OUTBOX"
TOPIC=$(basename "$TD")
printf 'OFFSET=%s\n' "$OFFSET" > "$TD/_consult/research-rex.txt"
CW_CONSULT_RESEARCH_TIMEOUT_OVERRIDE=5 \
  ../bin/consult-research-wait.sh "$TOPIC" rex codex >/dev/null 2>&1
FS=$(grep '^FS=' "$TD/_consult/research-rex.txt" | tail -1 | cut -d= -f2)
[[ "$FS" == "question" ]] || { echo "FAIL case3: expected FS=question; got '$FS'"; exit 1; }

# OFFSET advanced past the question event.
NEW_OFF=$(grep '^OFFSET=' "$TD/_consult/research-rex.txt" | tail -1 | cut -d= -f2)
OUTBOX_SIZE=$(wc -c < "$OUTBOX" | tr -d ' ')
[[ "$NEW_OFF" == "$OUTBOX_SIZE" ]] \
  || { echo "FAIL case3: OFFSET=$NEW_OFF should match outbox size $OUTBOX_SIZE"; exit 1; }
pass "case 3 (question only): FS=question + OFFSET advances past question"

# Case 4: malformed question (missing text) → FS=failed, no payload.
TD=$(stage_topic "case4 malformed-q")
OUTBOX="$TD/rex-codex/outbox.jsonl"
echo '{"event":"ack"}'                                  >> "$OUTBOX"
OFFSET=$(wc -c < "$OUTBOX" | tr -d ' ')
echo '{"event":"question","options":["x"]}'              >> "$OUTBOX"   # missing text
TOPIC=$(basename "$TD")
printf 'OFFSET=%s\n' "$OFFSET" > "$TD/_consult/research-rex.txt"
CW_CONSULT_RESEARCH_TIMEOUT_OVERRIDE=5 \
  ../bin/consult-research-wait.sh "$TOPIC" rex codex >/dev/null 2>&1
FS=$(grep '^FS=' "$TD/_consult/research-rex.txt" | tail -1 | cut -d= -f2)
[[ "$FS" == "failed" ]] \
  || { echo "FAIL case4: malformed question should FS=failed; got '$FS'"; exit 1; }
[[ ! -f "$TD/_consult/question-rex.txt" ]] \
  || { echo "FAIL case4: malformed question should not write payload"; exit 1; }
pass "case 4 (malformed question): FS=failed, no payload (M5 closure)"

# Case 5 (Rev3 serialization + race fix): two questions queued before wait
# fires. wait-script catches the FIRST (head -n1 semantics) and OFFSET points
# BEFORE the second (NOT past the entire outbox). Critical for two reasons:
#  - serialization: questions get processed one at a time, not batched
#  - race fix: NEW_OFFSET is end-of-matched-line, not wc -c of outbox
TD=$(stage_topic "case5 q-q-no-done")
OUTBOX="$TD/rex-codex/outbox.jsonl"
echo '{"event":"ack"}'                                            >> "$OUTBOX"
OFFSET=$(wc -c < "$OUTBOX" | tr -d ' ')
echo '{"event":"question","text":"Q1?","options":[]}'              >> "$OUTBOX"
END_OF_Q1=$(wc -c < "$OUTBOX" | tr -d ' ')
echo '{"event":"question","text":"Q2?","options":[]}'              >> "$OUTBOX"
TOPIC=$(basename "$TD")
printf 'OFFSET=%s\n' "$OFFSET" > "$TD/_consult/research-rex.txt"
CW_CONSULT_RESEARCH_TIMEOUT_OVERRIDE=5 \
  ../bin/consult-research-wait.sh "$TOPIC" rex codex >/dev/null 2>&1
FS=$(grep '^FS=' "$TD/_consult/research-rex.txt" | tail -1 | cut -d= -f2)
[[ "$FS" == "question" ]] \
  || { echo "FAIL case5: expected FS=question on multi-question; got $FS"; exit 1; }
NEW_OFF=$(grep '^OFFSET=' "$TD/_consult/research-rex.txt" | tail -1 | cut -d= -f2)
[[ "$NEW_OFF" == "$END_OF_Q1" ]] \
  || { echo "FAIL case5: NEW_OFFSET=$NEW_OFF should equal end-of-Q1=$END_OF_Q1 (NOT past Q2)"; exit 1; }
Q_TEXT=$(cw_consult_question_payload_read "$TD/_consult/question-rex.txt" TEXT)
[[ "$Q_TEXT" == "Q1?" ]] \
  || { echo "FAIL case5: should have Q1 payload (FIRST question); got '$Q_TEXT'"; exit 1; }
pass "case 5 (Rev3 serialization+race): caught Q1, OFFSET points BEFORE Q2"

# Case 5b: re-run wait-script — should now catch Q2 (since OFFSET advanced past Q1).
CW_CONSULT_RESEARCH_TIMEOUT_OVERRIDE=5 \
  ../bin/consult-research-wait.sh "$TOPIC" rex codex >/dev/null 2>&1
Q_TEXT2=$(cw_consult_question_payload_read "$TD/_consult/question-rex.txt" TEXT)
[[ "$Q_TEXT2" == "Q2?" ]] \
  || { echo "FAIL case5b: re-run should catch Q2; got '$Q_TEXT2'"; exit 1; }
pass "case 5b (Rev3): re-run wait catches Q2 — questions truly serialized"

# Case 6 (Rev3 race fix variant): question + done queued together. Terminal
# event WINS over question — the trooper finished, the in-flight question
# is dropped. Critical for not blocking on a question the trooper already
# moved past.
TD=$(stage_topic "case6 q-done-priority")
OUTBOX="$TD/rex-codex/outbox.jsonl"
echo '{"event":"ack"}'                                            >> "$OUTBOX"
OFFSET=$(wc -c < "$OUTBOX" | tr -d ' ')
echo '{"event":"question","text":"abandoned Q","options":[]}'      >> "$OUTBOX"
echo '{"event":"done"}'                                            >> "$OUTBOX"
echo "stub findings" > "$TD/rex-codex/findings.md"
echo "[citation] x" >> "$TD/rex-codex/findings.md"
TOPIC=$(basename "$TD")
printf 'OFFSET=%s\n' "$OFFSET" > "$TD/_consult/research-rex.txt"
CW_CONSULT_RESEARCH_TIMEOUT_OVERRIDE=5 \
  ../bin/consult-research-wait.sh "$TOPIC" rex codex >/dev/null 2>&1
FS=$(grep '^FS=' "$TD/_consult/research-rex.txt" | tail -1 | cut -d= -f2)
[[ "$FS" == "ok" ]] \
  || { echo "FAIL case6: terminal done should win over abandoned question; got FS=$FS"; exit 1; }
[[ ! -f "$TD/_consult/question-rex.txt" ]] \
  || { echo "FAIL case6: abandoned question payload should not be written"; exit 1; }
pass "case 6 (Rev3 priority): terminal done wins over in-flight question"
```

- [ ] **Step 6: Run tests**

```bash
chmod +x tests/test_consult_question_event_priority.sh
bash tests/test_consult_question_event.sh
bash tests/test_consult_question_event_priority.sh
bash tests/test_consult_research_wait.sh
bash tests/test_consult_verify_wait.sh
```

Expected: all PASS. Existing wait-script tests already cover
`done`/`error`/`timeout`/`empty` paths — those should still pass since
the new code's case-arms reproduce the v0.2 behaviors.

- [ ] **Step 7: Commit**

```bash
git add bin/consult-research-wait.sh bin/consult-verify-wait.sh \
        tests/test_consult_question_event.sh \
        tests/test_consult_question_event_priority.sh
git commit -m "feat(consult): wait-scripts capture matched event + auto-bump OFFSET

Captures cw_outbox_wait_since stdout into MATCHED, parses event=…, and
branches via case on the actual matched event (closes Codex Rev1 H2).
On question match, validates payload and appends OFFSET=<post-question>
to state file so re-arm is wait-script-only — directive does not call
the phase send-script (closes H1). Malformed question payloads → FS=failed
not FS=question (closes M5)."
```

---

## Task 7: `--keep-findings` flag for `consult-offset-reset.sh`

**Scope clarification (post-Codex Rev1):** this flag is **NOT** used by
the question loop. The question loop is wait-script-only re-arm; the
wait-script auto-advances OFFSET on its own. `--keep-findings` exists
for **Patterns 1 and 3** (malformed-findings re-prompt, all-UNCERTAIN
re-prompt) where the conductor wants to clear the per-commander state
file but preserve work in progress.

**Files:**
- Modify: `bin/consult-offset-reset.sh`
- Test: `tests/test_consult_offset_reset_keep.sh`
- Test: `tests/test_consult_offset_reset.sh` (re-run to pin existing 3-arg signature)

- [ ] **Step 1: Write the failing test**

Create `tests/test_consult_offset_reset_keep.sh`:

```bash
#!/usr/bin/env bash
# tests/test_consult_offset_reset_keep.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"
export CLAUDE_PLUGIN_ROOT="$(cd .. && pwd)"

source ../lib/state.sh
RH=$(cw_repo_hash)
TOPIC=$(../bin/consult-init.sh "keep-findings test" | sed -n '1p')
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"

# Stage the artifacts that --keep-findings should preserve.
mkdir -p "$TD/rex-codex"
echo "preserved findings"  > "$TD/rex-codex/findings.md"
echo "preserved verify"    > "$TD/rex-codex/verify.md"
echo "preserved diff"      > "$TD/_consult/diff.md"
echo "preserved rex_only"  > "$TD/_consult/rex_only_items.txt"
echo "preserved cody_only" > "$TD/_consult/cody_only_items.txt"
echo "preserved draft"     > "$TD/_consult/adjudicated-draft.md"
echo "OFFSET=42"            > "$TD/_consult/research-rex.txt"
echo "FS=question"          >> "$TD/_consult/research-rex.txt"

../bin/consult-offset-reset.sh "$TOPIC" rex research --keep-findings

# State file removed (always).
[[ ! -f "$TD/_consult/research-rex.txt" ]] || { echo "FAIL: state file should be removed" >&2; exit 1; }
pass "state file removed"

# Trooper-owned files preserved.
[[ -f "$TD/rex-codex/findings.md" ]] || { echo "FAIL: findings.md was deleted" >&2; exit 1; }
pass "findings.md preserved with --keep-findings"

# Cascade artifacts preserved (the whole point of the flag).
[[ -f "$TD/_consult/diff.md"      ]] || { echo "FAIL: diff.md deleted"      >&2; exit 1; }
[[ -f "$TD/_consult/rex_only_items.txt"  ]] || { echo "FAIL: rex_only deleted"  >&2; exit 1; }
[[ -f "$TD/_consult/cody_only_items.txt" ]] || { echo "FAIL: cody_only deleted" >&2; exit 1; }
[[ -f "$TD/_consult/adjudicated-draft.md" ]] || { echo "FAIL: draft deleted"     >&2; exit 1; }
pass "cascade artifacts preserved with --keep-findings"

# Verify-phase symmetry.
echo "OFFSET=99"   > "$TD/_consult/verify-rex.txt"
echo "VS=question" >> "$TD/_consult/verify-rex.txt"
../bin/consult-offset-reset.sh "$TOPIC" rex verify --keep-findings

[[ ! -f "$TD/_consult/verify-rex.txt" ]] || { echo "FAIL: verify state file should be removed" >&2; exit 1; }
[[ -f "$TD/rex-codex/verify.md" ]] || { echo "FAIL: verify.md was deleted" >&2; exit 1; }
[[ -f "$TD/_consult/adjudicated-draft.md" ]] || { echo "FAIL: draft deleted in verify-phase" >&2; exit 1; }
pass "verify --keep-findings preserves verify.md + draft"

# Without --keep-findings, full cascade still works (existing v0.2 behavior).
echo "OFFSET=1" > "$TD/_consult/research-rex.txt"
../bin/consult-offset-reset.sh "$TOPIC" rex research
[[ ! -f "$TD/rex-codex/findings.md" ]] || { echo "FAIL: findings.md should be removed without flag" >&2; exit 1; }
[[ ! -f "$TD/_consult/diff.md" ]]      || { echo "FAIL: diff.md should be removed without flag" >&2; exit 1; }
pass "without flag, full cascade still removes findings.md + diff.md"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_consult_offset_reset_keep.sh`
Expected: FAIL — script doesn't accept `--keep-findings` flag yet.

- [ ] **Step 3: Modify `bin/consult-offset-reset.sh`**

Change the arg-handling header. Replace:

```bash
[[ $# -eq 3 ]] || { echo "Usage: $0 <consult-topic> <commander> <phase>" >&2; exit 2; }
TOPIC="$1"; COMMANDER="$2"; PHASE="$3"
```

with:

```bash
KEEP_FINDINGS=0
ARGS=()
for a in "$@"; do
  case "$a" in
    --keep-findings) KEEP_FINDINGS=1 ;;
    --*) echo "Unknown flag: $a" >&2; exit 2 ;;
    *) ARGS+=("$a") ;;
  esac
done
[[ ${#ARGS[@]} -eq 3 ]] \
  || { echo "Usage: $0 <consult-topic> <commander> <phase> [--keep-findings]" >&2; exit 2; }
TOPIC="${ARGS[0]}"; COMMANDER="${ARGS[1]}"; PHASE="${ARGS[2]}"
```

Then guard the cascade-removal block. Replace:

```bash
shopt -s nullglob
for td in $TROOPER_DIR_GLOB; do
  if [[ "$PHASE" == research ]]; then
    rm -f "$td/findings.md"
  else
    rm -f "$td/verify.md"
  fi
done

# Cascade. Research phase invalidates downstream computation.
if [[ "$PHASE" == research ]]; then
  rm -f "$ART_DIR/diff.md" "$ART_DIR/rex_only_items.txt" "$ART_DIR/cody_only_items.txt"
fi
# Both phases invalidate the adjudication draft (which depends on both).
rm -f "$ART_DIR/adjudicated-draft.md"
```

with:

```bash
if (( ! KEEP_FINDINGS )); then
  shopt -s nullglob
  for td in $TROOPER_DIR_GLOB; do
    if [[ "$PHASE" == research ]]; then
      rm -f "$td/findings.md"
    else
      rm -f "$td/verify.md"
    fi
  done

  if [[ "$PHASE" == research ]]; then
    rm -f "$ART_DIR/diff.md" "$ART_DIR/rex_only_items.txt" "$ART_DIR/cody_only_items.txt"
  fi
  rm -f "$ART_DIR/adjudicated-draft.md"
fi

# Pending question payload is always removed (it's been handled).
rm -f "$ART_DIR/question-$COMMANDER.txt"
```

- [ ] **Step 4: Run test to verify it passes**

```bash
bash tests/test_consult_offset_reset_keep.sh
bash tests/test_consult_offset_reset.sh   # existing test — must still pass
```

Expected: both PASS. The existing `test_consult_offset_reset.sh` validates
the 3-arg signature is preserved (Codex Rev1 plan-finding #9 spot-check).

- [ ] **Step 5: Commit**

```bash
chmod +x tests/test_consult_offset_reset_keep.sh
git add bin/consult-offset-reset.sh tests/test_consult_offset_reset_keep.sh
git commit -m "feat(consult): consult-offset-reset.sh --keep-findings flag

Used by Pattern 4 (critical-question relay): advance the offset past a
handled question without nuking findings.md / cascade artifacts. Default
behavior unchanged. Always removes any pending question-<commander>.txt
since it has just been handled."
```

---

## Task 8: Directive — Step 3/5 redesign + Pattern 4

**Files:**
- Modify: `commands/consult.md`

- [ ] **Step 1: Read the current Step 3 + Pattern section**

Read `commands/consult.md` lines 130–270. Note the existing structure.

- [ ] **Step 2: Replace Step 3 — Parallel research wait**

Find the section starting `### Step 3 — Parallel research wait`. Replace its body with:

```markdown
### Step 3 — Parallel research wait (with question loop)

Both wait-script calls in PARALLEL. Each exits on the FIRST of:
done | error | question | timeout.

```
"$CLAUDE_PLUGIN_ROOT/bin/consult-research-wait.sh" "$CONSULT_TOPIC" rex  codex
"$CLAUDE_PLUGIN_ROOT/bin/consult-research-wait.sh" "$CONSULT_TOPIC" cody claude
```

After both return, read each commander's state file:

```
grep '^FS=' "$TOPIC_DIR/_consult/research-rex.txt"  | tail -1
grep '^FS=' "$TOPIC_DIR/_consult/research-cody.txt" | tail -1
```

For each commander whose `FS=question`:

1. Read the question payload — `_consult/question-<commander>.txt`. Use the
   Read tool, parse `TEXT=` and `OPTIONS=`.
2. **Read the trooper's findings-so-far** — `Read $TOPIC_DIR/<commander>-<model>/findings.md`
   (if it exists). This is required for non-critical answers; without it
   the directive is guessing blind.
3. Decide whether the question is **critical**:
   - critical = answer would change the topic interpretation (scope expansion,
     contradiction with an explicit user constraint, binary fork with no
     clear default given the findings-so-far).
   - non-critical = clarifying question, defaulting choice, language
     convention answerable from topic + findings.
4. Get an answer:
   - critical → `AskUserQuestion` with `TEXT` as question, `OPTIONS` as
     multiple-choice (or free-form if `OPTIONS` is empty).
   - non-critical → answer from topic context + findings yourself.
5. Send the answer (writes inbox.md + nudges trooper):
   ```
   /clone-wars:send <commander> "$CONSULT_TOPIC" "ANSWER: <the answer>

   (end of question response — resume your skill loop)
   END_OF_INSTRUCTION"
   ```
6. **Re-arm by re-running the wait-script ONLY**. Do NOT call
   `consult-research-send.sh` — that would overwrite the ANSWER inbox
   and rebuild the prompt. The wait-script's `source $STATE_FILE` picks
   up the OFFSET= line the previous wait-iteration appended past the
   question (last-wins).
   ```
   "$CLAUDE_PLUGIN_ROOT/bin/consult-research-wait.sh" "$CONSULT_TOPIC" \
      <commander> <model>
   ```
7. Loop back to the top of Step 3 if any trooper still has `FS=question`
   pending (rex's answer flow may have finished while cody is still
   waiting; both troopers re-run their wait-scripts on next iteration).

If both troopers raise FS=question simultaneously, handle them in iteration
order (rex first, then cody). The user sees critical prompts sequentially —
trooper-2's answer flow does not start until trooper-1's is complete.

Stop the loop when both are FS ∈ {ok, empty, missing, failed, timeout, malformed}.
For each non-question final state:
- `ok` / `empty` / `missing` → set tasks 1.3/1.4 → `completed`.
- `failed` / `timeout` / `malformed` → consider Pattern 1 (re-prompt) before
  proceeding; set tasks → `completed` if accepting the degraded result.
```

- [ ] **Step 3: Apply the same redesign to Step 5 — verify wait**

Find `### Step 5 — Parallel verify dispatch + wait`. Replace the body
analogously. The structure is identical except:
- `verify-<commander>.txt` instead of `research-<commander>.txt`
- `VS=question` instead of `FS=question`
- `consult-verify-wait.sh` instead of `consult-research-wait.sh`
- `consult-verify-send.sh` instead of `consult-research-send.sh`
- `verify` instead of `research` in the offset-reset call
- Fall-through to "consider Pattern 3 (all-UNCERTAIN re-prompt)" instead of Pattern 1

- [ ] **Step 4: Append Pattern 4 to Intervention patterns**

Find the `## Intervention patterns` section. After Pattern 3, append:

```markdown
### Pattern 4: Critical-question relay

When a wait-script reports `FS=question` (research) or `VS=question` (verify):

1. Read `_consult/question-<commander>.txt` — note `TEXT` and `OPTIONS`.
2. Read `$TROOPER_DIR/findings.md` (or `verify.md`) for findings-so-far context.
3. Classify:
   - critical → `AskUserQuestion(TEXT, OPTIONS)`.
   - non-critical → answer from topic + findings yourself.
4. Send the answer:
   ```
   /clone-wars:send <commander> "$CONSULT_TOPIC" "ANSWER: <answer>

   (end of question response — resume your skill loop)
   END_OF_INSTRUCTION"
   ```
5. Re-run the wait-script (no send-script, no offset-reset — wait-script
   already advanced OFFSET):
   ```
   "$CLAUDE_PLUGIN_ROOT/bin/consult-research-wait.sh" "$CONSULT_TOPIC" \
      <commander> <model>          # research
   # or:
   "$CLAUDE_PLUGIN_ROOT/bin/consult-verify-wait.sh" "$CONSULT_TOPIC" \
      <commander> <model>          # verify
   ```
6. Loop until the trooper reports `FS=ok` or `VS=ok`.

Both troopers may emit questions independently. The directive's loop
processes them in iteration order; the user sees critical prompts
sequentially.
```

- [ ] **Step 5: Add a brief explanation in the directive header**

Near the top of `commands/consult.md` (after the existing description),
insert a paragraph:

```markdown
v0.3 protocol: troopers may emit `{"event":"question",...}` events while
running superpowers skills. The Jedi general (this directive) catches
those, classifies critical vs. non-critical, answers from topic context
or escalates to the user via AskUserQuestion. See Step 3 / Step 5 for
the loop, and Pattern 4 for the recovery recipe.
```

- [ ] **Step 6: Smoke check**

The directive isn't unit-testable, but verify the wiring:

```bash
grep -n 'FS=question\|VS=question\|--keep-findings\|Pattern 4' commands/consult.md
```

Expected: at least 6 hits showing FS=question / VS=question / --keep-findings / Pattern 4 anchored to their sections.

- [ ] **Step 7: Commit**

```bash
git add commands/consult.md
git commit -m "feat(consult): directive Step 3/5 question loop + Pattern 4

Step 3 (research wait) and Step 5 (verify wait) now loop on FS/VS=question:
read payload → classify critical → answer or escalate → send + reset
--keep-findings → re-run wait. Pattern 4 documents the same recipe
parallel to Patterns 1 and 3."
```

---

## Task 9: End-to-end mocked round-trip test (multi-question + cross-phase)

**Files:**
- Create: `tests/test_consult_question_loop.sh`

- [ ] **Step 1: Write the test**

Create `tests/test_consult_question_loop.sh`:

```bash
#!/usr/bin/env bash
# tests/test_consult_question_loop.sh — full round-trip with mock outbox.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"
export CLAUDE_PLUGIN_ROOT="$(cd .. && pwd)"

source ../lib/state.sh
source ../lib/consult.sh

RH=$(cw_repo_hash)
TOPIC=$(../bin/consult-init.sh "design pattern for cache eviction" | sed -n '1p')
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"

# init wrote skill=brainstorming?
assert_eq "$(cat "$TD/_consult/skill.txt")" "brainstorming" "init wrote brainstorming skill"

# Stage trooper dir + outbox.
mkdir -p "$TD/rex-codex"
OUTBOX="$TD/rex-codex/outbox.jsonl"
: > "$OUTBOX"

# Phase 1: trooper emits ready then question.
echo '{"event":"ready"}' >> "$OUTBOX"
OFFSET_AT_QUESTION=$(wc -c < "$OUTBOX" | tr -d ' ')
echo '{"event":"question","text":"LRU or LFU?","options":["LRU","LFU"]}' >> "$OUTBOX"

# Stage the per-commander state file post research-send.
printf 'OFFSET=%s\n' "$OFFSET_AT_QUESTION" > "$TD/_consult/research-rex.txt"

# wait-script catches the question.
CW_CONSULT_RESEARCH_TIMEOUT_OVERRIDE=5 \
  ../bin/consult-research-wait.sh "$TOPIC" rex codex >/dev/null 2>&1
grep -q '^FS=question$' "$TD/_consult/research-rex.txt" \
  || { echo "FAIL: FS=question not set" >&2; exit 1; }
[[ -f "$TD/_consult/question-rex.txt" ]] \
  || { echo "FAIL: question payload missing" >&2; exit 1; }
pass "round-trip phase 1: wait-script caught question and wrote payload"

# === H1 closure regression (anchored AFTER Phase 1) ===
# Wait-script must have appended a SECOND OFFSET= line past the question.
# Test BEFORE any other action — we want to prove auto-bump worked, not
# whether subsequent steps clear the file.
OFFSET_LINES=$(grep -c '^OFFSET=' "$TD/_consult/research-rex.txt")
[[ "$OFFSET_LINES" -ge 2 ]] \
  || { echo "FAIL: state file should have ≥2 OFFSET lines (initial + post-question); got $OFFSET_LINES"; cat "$TD/_consult/research-rex.txt"; exit 1; }
SECOND_OFFSET=$(grep '^OFFSET=' "$TD/_consult/research-rex.txt" | tail -1 | cut -d= -f2)
OUTBOX_SIZE_AFTER_Q=$(wc -c < "$OUTBOX" | tr -d ' ')
[[ "$SECOND_OFFSET" == "$OUTBOX_SIZE_AFTER_Q" ]] \
  || { echo "FAIL: 2nd OFFSET=$SECOND_OFFSET should equal outbox size $OUTBOX_SIZE_AFTER_Q after question"; exit 1; }
pass "wait-script auto-bumped OFFSET past question (no offset-reset call)"

# Phase 2: directive simulates answering — writes inbox.md only (no state-file
# touch). cw_send is a no-op for state files, so we don't even need to call
# anything; the test just demonstrates the answer doesn't break the cursor.
# Verify the state file survived intact.
[[ -f "$TD/_consult/research-rex.txt" ]] \
  || { echo "FAIL: state file should survive simulated answer" >&2; exit 1; }
[[ -f "$TD/_consult/question-rex.txt" ]] \
  || { echo "FAIL: payload should still exist before re-arm" >&2; exit 1; }
pass "round-trip phase 2: simulated cw_send leaves state file + payload intact"

# Phase 3: trooper resumes. Append done event + findings; re-run wait-script.
# The wait-script must source the LATEST OFFSET (post-question) — it should
# NOT re-process the question. This is the H1 contract under test.
echo '{"event":"done"}' >> "$OUTBOX"
echo "stub findings" > "$TD/rex-codex/findings.md"
echo "[citation] sample claim" >> "$TD/rex-codex/findings.md"

CW_CONSULT_RESEARCH_TIMEOUT_OVERRIDE=5 \
  ../bin/consult-research-wait.sh "$TOPIC" rex codex >/dev/null 2>&1

FS_FINAL=$(grep '^FS=' "$TD/_consult/research-rex.txt" | tail -1 | cut -d= -f2)
[[ "$FS_FINAL" == "ok" ]] \
  || { echo "FAIL: expected FS=ok after resume; got '$FS_FINAL'" >&2; cat "$TD/_consult/research-rex.txt"; exit 1; }
pass "round-trip phase 3: trooper resumes via re-run wait-script (no offset-reset, no send-script — H1 closure)"

# === Multi-question loop: Q→A→Q→A→done ===
TD2_TOPIC=$(../bin/consult-init.sh "design pattern multi-q test" | sed -n '1p')
TD2="$CLONE_WARS_HOME/state/$RH/$TD2_TOPIC"
mkdir -p "$TD2/rex-codex"
OUTBOX2="$TD2/rex-codex/outbox.jsonl"
echo '{"event":"ready"}' >> "$OUTBOX2"
OFFSET_INIT=$(wc -c < "$OUTBOX2" | tr -d ' ')
echo '{"event":"question","text":"Q1?","options":[]}' >> "$OUTBOX2"
printf 'OFFSET=%s\n' "$OFFSET_INIT" > "$TD2/_consult/research-rex.txt"

# First question caught.
CW_CONSULT_RESEARCH_TIMEOUT_OVERRIDE=5 \
  ../bin/consult-research-wait.sh "$TD2_TOPIC" rex codex >/dev/null 2>&1
FS=$(grep '^FS=' "$TD2/_consult/research-rex.txt" | tail -1 | cut -d= -f2)
[[ "$FS" == "question" ]] || { echo "FAIL multi-q phase 1: FS=$FS"; exit 1; }

# Simulate answer + second question.
echo '{"event":"question","text":"Q2?","options":["A","B"]}' >> "$OUTBOX2"
CW_CONSULT_RESEARCH_TIMEOUT_OVERRIDE=5 \
  ../bin/consult-research-wait.sh "$TD2_TOPIC" rex codex >/dev/null 2>&1
FS=$(grep '^FS=' "$TD2/_consult/research-rex.txt" | tail -1 | cut -d= -f2)
[[ "$FS" == "question" ]] || { echo "FAIL multi-q phase 2: FS=$FS"; exit 1; }
Q2_TEXT=$(cw_consult_question_payload_read "$TD2/_consult/question-rex.txt" TEXT)
[[ "$Q2_TEXT" == "Q2?" ]] || { echo "FAIL multi-q: payload should be Q2 got '$Q2_TEXT'"; exit 1; }

# Final answer + done.
echo '{"event":"done"}' >> "$OUTBOX2"
echo "stub" > "$TD2/rex-codex/findings.md"; echo "[c] x" >> "$TD2/rex-codex/findings.md"
CW_CONSULT_RESEARCH_TIMEOUT_OVERRIDE=5 \
  ../bin/consult-research-wait.sh "$TD2_TOPIC" rex codex >/dev/null 2>&1
FS=$(grep '^FS=' "$TD2/_consult/research-rex.txt" | tail -1 | cut -d= -f2)
[[ "$FS" == "ok" ]] || { echo "FAIL multi-q done: FS=$FS"; exit 1; }
pass "multi-question loop: Q1→Q2→done, OFFSET advances each time, no send-script call"
```

- [ ] **Step 2: Run test**

```bash
chmod +x tests/test_consult_question_loop.sh
bash tests/test_consult_question_loop.sh
```

Expected: PASS — all 4 `pass` statements.

- [ ] **Step 3: Run full test suite**

```bash
bash tests/run.sh
```

Expected: all tests pass (existing 24 + 5 new files).

- [ ] **Step 4: Commit**

```bash
git add tests/test_consult_question_loop.sh
git commit -m "test(consult): end-to-end question round-trip + multi-question fixture

Mocks the outbox: trooper emits question → wait-script catches and
auto-advances OFFSET → directive cw_send ANSWER → wait-script re-runs
(no offset-reset, no send-script) → FS=ok. Also covers Q→A→Q→A→done
multi-question loop. Proves H1 closure end-to-end at the unit level
(complementing Task 10's real-CLI dogfood)."
```

---

## Task 10: Real-CLI dogfood — STRICT autonomy gate (H3 closure)

**Files:**
- Create: `tests/test_consult_question_dogfood_strict.sh`
- Create: `tests/test_consult_question_dogfood_default.sh`

**Why:** Task 9's mock test proves the IPC plumbing. It does NOT prove
the autonomy contract actually overrides `superpowers:brainstorming`'s
native AskUserQuestion call. Codex Rev2 review found Rev1's single
dogfood test was a non-gate (it accepted `FS=ok` without `[Q&A]` markers,
so a trooper could pass by ignoring the contract entirely).

Rev3 splits this into two tests:

- **`_strict.sh`** — release-blocking. Skips ONLY on missing binaries
  (`codex` / `tmux` / `$TMUX`). On any other path, MUST reach
  `FS=question`, MUST send ANSWER, MUST verify trooper resumed. Failure
  to reach `FS=question` is a test failure, not a permissive pass.
  This is the actual H3 gate.
- **`_default.sh`** — informational. Validates that a non-questioning
  default path still produces well-formed `findings.md`. Permissive on
  question vs no-question. Not release-blocking.

- [ ] **Step 1: Write the strict test**

Create `tests/test_consult_question_dogfood_strict.sh`:

```bash
#!/usr/bin/env bash
# tests/test_consult_question_dogfood_strict.sh — H3 closure GATE.
# Validates the autonomy contract is actually obeyed by a live codex
# trooper. Skips ONLY on missing binaries — once the harness can run,
# any failure to reach FS=question is a test failure (not a permissive
# pass). This is the test that gates v0.3.0 release.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

if ! command -v codex >/dev/null 2>&1; then
  echo "SKIP: codex CLI not installed — STRICT dogfood skipped (release gate not exercised)"
  exit 0
fi
if ! command -v tmux >/dev/null 2>&1; then
  echo "SKIP: tmux not installed — STRICT dogfood skipped"
  exit 0
fi
if [[ -z "${TMUX:-}" ]]; then
  echo "SKIP: not inside a tmux session — STRICT dogfood skipped"
  exit 0
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"
export CLAUDE_PLUGIN_ROOT="$(cd .. && pwd)"

source ../lib/state.sh
source ../lib/ipc.sh
source ../lib/consult.sh

RH=$(cw_repo_hash)

# Forced-fork brainstorming topic — should COMPEL the trooper to ask if
# the autonomy contract is being honored, because there's no sensible
# default to choose from topic context alone.
TOPIC=$(../bin/consult-init.sh \
  "decide between LRU and LFU eviction for the cache layer; both are valid; need explicit pick" \
  | sed -n '1p')
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
[[ "$(cat "$TD/_consult/skill.txt")" == "brainstorming" ]] \
  || { echo "FAIL: expected brainstorming classification"; exit 1; }

if ! ../bin/spawn.sh rex codex "$TOPIC" >/dev/null 2>&1; then
  echo "SKIP: codex spawn failed — STRICT dogfood skipped"
  exit 0
fi
trap 'rm -rf "$TMP"; ../bin/consult-teardown.sh "$TOPIC" >/dev/null 2>&1 || true' EXIT

../bin/consult-research-send.sh "$TOPIC" rex codex >/dev/null 2>&1

# Wait up to 120s for FS=question. STRICT: any FS other than 'question'
# in this loop fails the test.
T0=$(date +%s); DEADLINE=$((T0 + 120))
while (( $(date +%s) < DEADLINE )); do
  ../bin/consult-research-wait.sh "$TOPIC" rex codex >/dev/null 2>&1 || true
  FS=$(grep '^FS=' "$TD/_consult/research-rex.txt" 2>/dev/null | tail -1 | cut -d= -f2 || echo "")
  [[ -n "$FS" ]] && break
  sleep 2
done

# STRICT gate: FS MUST be question.
[[ "$FS" == "question" ]] \
  || { echo "FAIL: STRICT gate — expected FS=question on forced-fork topic; got '$FS'"
       echo "  outbox tail:"; tail -30 "$(cw_outbox_path rex codex "$TOPIC")" 2>/dev/null || true
       exit 1; }
pass "STRICT: real codex trooper emitted {event:question} via outbox (contract obeyed)"

# Verify payload extracted correctly.
[[ -f "$TD/_consult/question-rex.txt" ]] \
  || { echo "FAIL: question payload missing"; exit 1; }
Q_TEXT=$(cw_consult_question_payload_read "$TD/_consult/question-rex.txt" TEXT)
[[ -n "$Q_TEXT" ]] \
  || { echo "FAIL: question payload TEXT is empty"; exit 1; }
pass "STRICT: question payload extracted with non-empty TEXT"

# Send synthetic ANSWER. Verify trooper recognizes the ANSWER: prefix
# and resumes (not just any inbox change — must be ANSWER-line aware).
../bin/send.sh rex "$TOPIC" "ANSWER: pick LRU (Least Recently Used). Use a doubly-linked list + hashmap. Document this choice in findings.md.

(resume your skill loop)
END_OF_INSTRUCTION" >/dev/null 2>&1

T1=$(date +%s); DEADLINE2=$((T1 + 90))
while (( $(date +%s) < DEADLINE2 )); do
  ../bin/consult-research-wait.sh "$TOPIC" rex codex >/dev/null 2>&1 || true
  FS=$(grep '^FS=' "$TD/_consult/research-rex.txt" 2>/dev/null | tail -1 | cut -d= -f2 || echo "")
  [[ "$FS" == "ok" || "$FS" == "empty" || "$FS" == "missing" || "$FS" == "question" ]] && break
  sleep 2
done

case "$FS" in
  ok|empty|missing)
    pass "STRICT: trooper resumed after ANSWER, reached terminal state ($FS)"
    ;;
  question)
    # Multi-question loop is acceptable — but verify the new question is
    # different from the first (proves the trooper resumed, didn't stall).
    Q2_TEXT=$(cw_consult_question_payload_read "$TD/_consult/question-rex.txt" TEXT)
    [[ "$Q2_TEXT" != "$Q_TEXT" ]] \
      || { echo "FAIL: STRICT — trooper re-emitted SAME question; ANSWER not consumed"
           exit 1; }
    pass "STRICT: trooper resumed and asked a NEW question (multi-Q loop)"
    ;;
  *)
    echo "FAIL: STRICT — trooper did not resume after ANSWER; FS='$FS'"; exit 1
    ;;
esac

# Verify findings.md contains the LRU choice from the ANSWER (proves
# ANSWER text was actually parsed, not just "any inbox change resumes").
TROOPER_DIR=$(cw_trooper_dir rex codex "$TOPIC")
if [[ -f "$TROOPER_DIR/findings.md" ]]; then
  if grep -qiE 'LRU|Least Recently Used' "$TROOPER_DIR/findings.md"; then
    pass "STRICT: findings.md reflects ANSWER content (LRU choice) — ANSWER-line was parsed"
  else
    echo "FAIL: STRICT — ANSWER said LRU but findings.md does not mention it"
    echo "  findings.md:"; cat "$TROOPER_DIR/findings.md"
    exit 1
  fi
fi
```

- [ ] **Step 2: Write the permissive default-path test**

Create `tests/test_consult_question_dogfood_default.sh`:

```bash
#!/usr/bin/env bash
# tests/test_consult_question_dogfood_default.sh — informational dogfood.
# Validates the trooper produces well-formed findings on a topic with
# clear defaults (where NOT asking is also valid). NOT release-blocking.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

if ! command -v codex >/dev/null 2>&1 || ! command -v tmux >/dev/null 2>&1 \
   || [[ -z "${TMUX:-}" ]]; then
  echo "SKIP: codex / tmux / TMUX missing — default-path dogfood skipped"
  exit 0
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"
export CLAUDE_PLUGIN_ROOT="$(cd .. && pwd)"
source ../lib/state.sh
source ../lib/ipc.sh
source ../lib/consult.sh

RH=$(cw_repo_hash)

# Plain audit topic — should classify as 'none', no skill hint, no question.
TOPIC=$(../bin/consult-init.sh "review the auth middleware for token-refresh edge cases" | sed -n '1p')
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
[[ "$(cat "$TD/_consult/skill.txt")" == "none" ]] \
  || { echo "FAIL: expected 'none' classification on plain audit topic"; exit 1; }

if ! ../bin/spawn.sh rex codex "$TOPIC" >/dev/null 2>&1; then
  echo "SKIP: codex spawn failed"; exit 0
fi
trap 'rm -rf "$TMP"; ../bin/consult-teardown.sh "$TOPIC" >/dev/null 2>&1 || true' EXIT

../bin/consult-research-send.sh "$TOPIC" rex codex >/dev/null 2>&1

T0=$(date +%s); DEADLINE=$((T0 + 120))
while (( $(date +%s) < DEADLINE )); do
  ../bin/consult-research-wait.sh "$TOPIC" rex codex >/dev/null 2>&1 || true
  FS=$(grep '^FS=' "$TD/_consult/research-rex.txt" 2>/dev/null | tail -1 | cut -d= -f2 || echo "")
  [[ -n "$FS" ]] && break
  sleep 2
done

case "$FS" in
  ok|empty|missing) pass "default-path: trooper terminated normally (FS=$FS)" ;;
  *) echo "INFO: default-path trooper FS='$FS' (informational, not blocking)" ;;
esac
```

- [ ] **Step 3: Make executable + run (manual; skipped in CI)**

```bash
chmod +x tests/test_consult_question_dogfood_strict.sh
chmod +x tests/test_consult_question_dogfood_default.sh
bash tests/test_consult_question_dogfood_strict.sh
bash tests/test_consult_question_dogfood_default.sh
```

Expected outcomes:
- Strict — outside tmux or without codex: SKIP rc=0 (release gate not
  exercised; v0.3.0 should not ship without it passing manually). Inside
  tmux + codex: must reach FS=question, must consume ANSWER, must reflect
  LRU in findings.md. Otherwise FAIL.
- Default — same skip conditions; permissive on output shape.

**Release gate policy:** v0.3.0 ships only after `_strict.sh` PASSES at
least once on a real machine with codex+tmux. Document the run output in
the v0.3.0 release notes. SKIPs do not satisfy the gate.

- [ ] **Step 4: Commit**

```bash
git add tests/test_consult_question_dogfood_strict.sh tests/test_consult_question_dogfood_default.sh
git commit -m "test(consult): real-CLI dogfood — STRICT gate + permissive default-path

STRICT: forces a brainstorming topic with no sensible default (LRU vs LFU).
The trooper MUST emit {event:question} or fail the test. Then sends an
ANSWER referencing LRU and asserts findings.md reflects it (proves
ANSWER-line was parsed, not just 'any inbox change resumes'). Skips only
on missing tmux/codex.

DEFAULT: plain audit topic (skill=none); permissive on output shape.

Closes Codex Rev2 H3: Rev1's single dogfood test was a non-gate (accepted
FS=ok without [Q&A] markers — trooper could pass by ignoring contract).
Rev3 splits the test so the gate exists separately from informational
default-path coverage."
to ok/empty/missing.

Gated on tmux + codex + \$TMUX. Skipped (not failed) when missing.
Mocked unit coverage stays in test_consult_question_loop.sh."
```

(That commit message text was the Rev2 plan; superseded by the strict+
default split commit above. Kept here for diff-reading clarity only.)

---

## Task 11: v0.3.0 release polish

**Files:**
- Modify: `.claude-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json`
- Modify: `README.md`
- Modify: `CLAUDE.md` (status section)

- [ ] **Step 1: Bump version in plugin manifests**

In `.claude-plugin/plugin.json`, change `"version": "0.2.1"` → `"version": "0.3.0"`.

In `.claude-plugin/marketplace.json`, change `"version": "0.2.1"` → `"version": "0.3.0"`.

- [ ] **Step 2: README — add v0.3 section**

Append to `README.md` (under the existing version-history section, or as a new "What's new" block):

```markdown
## v0.3.0 — trooper question protocol + skill routing

The `consult` command now lets troopers ask questions back to the Jedi
general while running `superpowers:brainstorming` or `superpowers:systematic-debugging`
skills. Most questions are answered inline by the general; only critical
ones (option-forks that would change the topic interpretation) reach the
user via `AskUserQuestion`.

- One skill is auto-picked per consult run based on topic shape:
  - design / "how should" / "decide between" → `superpowers:brainstorming`
  - "why" / "broken" / "edge case" / "regression" → `superpowers:systematic-debugging`
  - default → no skill (plain research)
- Override the auto-pick by editing `_consult/skill.txt` after `consult-init`.
- The autonomy contract in the inbox prompt keeps question volume low.
- Question serialization across two troopers falls out of the directive's
  single-threaded shell flow — the user never sees interleaved prompts.

See `docs/superpowers/specs/2026-04-29-clone-wars-consult-question-protocol-design.md`
for the full design.
```

- [ ] **Step 3: CLAUDE.md status update**

In `CLAUDE.md`, in the `## Status` section:
- Replace `- [x] Tag v0.2.1` (or wherever the latest line is) with the
  v0.3.0 milestone line.

Actual edit: replace the most recent shipped line and add:

```markdown
- [x] v0.3.0 shipped — trooper question protocol + skill routing
```

- [ ] **Step 4: Run full suite one last time**

```bash
bash tests/run.sh
```

Expected: ALL tests pass. Note total count (existing + new).

- [ ] **Step 5: Commit**

```bash
git add .claude-plugin/plugin.json .claude-plugin/marketplace.json README.md CLAUDE.md
git commit -m "release: v0.3.0 — trooper question protocol + skill routing

Adds {event:question} outbox protocol, topic classifier (brainstorming/
systematic-debugging/none), skill-hint files with autonomy contract,
--keep-findings flag on offset-reset (Patterns 1/3 only), and Pattern 4
critical-question relay. Existing v0.2.1 dogfood path unchanged when
topic classifies as 'none'.

Closes Codex Rev1 findings: H1 (no double-inbox-write on re-arm),
H2 (wait-script branches on actual matched event), H3 (real-CLI dogfood
test gated on codex+tmux), M4 (systematic-debugging not debugging),
M5 (validate JSON before treating as question).

Spec: docs/superpowers/specs/2026-04-29-clone-wars-consult-question-protocol-design.md"
```

---

## Test summary

| Test | Status | Coverage |
|---|---|---|
| `test_consult_classify_topic.sh` | new | regex matches, word-boundary, M-tier trigger refinement |
| `test_consult_skill_hint.sh` | new | hint files + append, override env-var, PLUGIN_ROOT, skill resolution |
| `test_consult_question_event.sh` | new | payload helpers, wait-script catches event, malformed-input fixtures (M5) |
| `test_consult_question_event_priority.sh` | new (H2) | wait-script branches on actual matched event; question→error / question→done / multi-question |
| `test_consult_offset_reset_keep.sh` | new | `--keep-findings` flag (Patterns 1/3 only) |
| `test_consult_question_loop.sh` | new | mock round-trip + Q→A→Q→A→done multi-question |
| `test_consult_question_dogfood.sh` | new (H3) | real-CLI dogfood; gated on codex+tmux |
| `test_consult_init.sh` | extended | skill.txt assertion |
| `test_consult_research_wait.sh` | extended | capture-MATCHED + question-event case |
| `test_consult_verify_wait.sh` | extended | capture-MATCHED + question-event case |
| `test_consult_offset_reset.sh` | extended | pin existing 3-arg signature post Task 7 |

---

## Branch + PR plan

- All 11 tasks land on `feat/v0.3-question-protocol`.
- Each task is one commit. PR opens after Task 11.
- Bisect-safe: every commit through Task 10 keeps existing v0.2.1 paths green
  (skill.txt missing → `none` → no append; question event optional;
  Task 7 arg-parser preserves the 3-arg signature).
- v0.2.1 must merge first; rebase `feat/v0.3-question-protocol` onto post-merge
  main before opening the PR.

---

## Self-review against Rev2 spec

Codex Rev1 closures verified:

- ✅ **H1** (re-arm double-write): Task 6's wait-script appends `OFFSET=` on
  question match; Task 8 directive recipe drops `consult-research-send.sh`
  from re-arm; Task 9 fixture asserts ≥2 OFFSET= lines in state file
  without offset-reset call.
- ✅ **H2** (matched-event branch): Task 6 captures MATCHED, parses event,
  case-arms; new `test_consult_question_event_priority.sh` covers
  question→error / question→done / multi-question / malformed.
- ✅ **H3** (real-CLI test): new Task 10 spawns live codex trooper, validates
  autonomy-contract behavior; gated on tmux + codex.
- ✅ **M4** (systematic-debugging): renamed throughout; Task 3 test asserts
  hint skill-names resolve to installed `SKILL.md`.
- ✅ **M5** (JSON validation): Task 5 adds validator + extractor; Task 6
  routes invalid payloads to FS=failed not FS=question; fixtures cover
  missing-text, empty-text, escaped-quote, empty-options, non-JSON.

Lower-tier tightening verified:

- ✅ Task 1 trigger refinement: "design"/"structure"/"approach" alone do not match.
- ✅ Task 4 helper asserts `PLUGIN_ROOT`/`CLAUDE_PLUGIN_ROOT` set; fixture pins it.
- ✅ Task 4 helper respects `CW_CONSULT_SKILL_OVERRIDE=none`; fixture pins it.
- ✅ Task 8 directive recipe explicitly Reads findings.md/verify.md before classify.

Implementation-mechanics:

- ✅ Spec coverage: every Rev2 spec section has implementation tasks.
- ✅ Type/symbol consistency: `cw_consult_classify_topic`,
  `cw_consult_skill_hint_append`, `cw_consult_question_payload_{read,write}`,
  `cw_consult_question_validate_line`, `cw_consult_question_extract_to_payload`
  named identically across spec and plan. Old `cw_consult_question_extract_from_outbox`
  is **NOT** introduced (replaced by `_extract_to_payload` directly in wait-script).
- ✅ Both research and verify paths covered symmetrically (Tasks 4, 6, 8).
- ✅ Backwards-compat: Task 4 (missing skill.txt → none); Task 7 (3-arg signature preserved).
- ✅ Every code step shows actual code; no placeholders.
- ✅ Every test step shows actual assertions; no "similar to above".
