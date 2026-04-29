# /clone-wars:consult v0.3 — Question Protocol Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the trooper-question protocol and skill routing defined in `docs/superpowers/specs/2026-04-29-clone-wars-consult-question-protocol-design.md`.

**Architecture:** Extend existing per-phase sub-scripts (no new commands). Add one outbox event (`question`), one helper flag (`--keep-findings`), one classifier, two skill-hint files. Directive's wait-step gains a question-handling loop.

**Tech Stack:** pure bash + tmux + file IPC (unchanged). No new dependencies.

**Branch:** `feat/v0.3-question-protocol` off `main` (after v0.2.1 merges).

**Total tasks:** 10. TDD throughout; every task includes a failing test, the implementation, the passing test, and a commit.

---

## File structure

| Path | Action | Why |
|---|---|---|
| `lib/consult.sh` | modify | Add `cw_consult_classify_topic`, `cw_consult_question_payload_write`, `cw_consult_question_payload_read` |
| `bin/consult-init.sh` | modify | After picking the general, classify topic and write `_consult/skill.txt` |
| `bin/consult-research-send.sh` | modify | Read `_consult/skill.txt`, append `config/skill-hints/<skill>.md` to prompt |
| `bin/consult-verify-send.sh` | modify | Same skill-hint append |
| `bin/consult-research-wait.sh` | modify | Add `question` to awaited events; on match, write question payload + set `FS=question` |
| `bin/consult-verify-wait.sh` | modify | Same for `VS=question` |
| `bin/consult-offset-reset.sh` | modify | Add `--keep-findings` flag |
| `commands/consult.md` | modify | Step 3 + Step 5 redesign (question loop); Pattern 4 added |
| `config/skill-hints/brainstorming.md` | create | Brainstorming-skill prompt + autonomy contract |
| `config/skill-hints/debugging.md` | create | Debugging-skill prompt + autonomy contract |
| `config/skill-hints/none.md` | create | Empty file (no-op append) |
| `tests/test_consult_classify_topic.sh` | create | Classifier coverage |
| `tests/test_consult_skill_hint.sh` | create | Send-script appends correct hint file |
| `tests/test_consult_question_event.sh` | create | Wait-script catches `question` event |
| `tests/test_consult_offset_reset_keep.sh` | create | `--keep-findings` flag behavior |
| `tests/test_consult_question_loop.sh` | create | End-to-end mocked round-trip |
| `tests/test_consult_init.sh` | modify | Assert `skill.txt` written |
| `tests/test_consult_research_wait.sh` | modify | Add question-event case |
| `tests/test_consult_verify_wait.sh` | modify | Add question-event case |
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

# brainstorming triggers
assert_eq "$(cw_consult_classify_topic 'how should we design the auth flow')" "brainstorming" "design+how-should"
assert_eq "$(cw_consult_classify_topic 'design pattern review')"               "brainstorming" "design pattern"
assert_eq "$(cw_consult_classify_topic 'what is the best way to structure X')"  "brainstorming" "best way"
assert_eq "$(cw_consult_classify_topic 'decide between Postgres and Mongo')"    "brainstorming" "decide between"
assert_eq "$(cw_consult_classify_topic 'How Should We Approach This?')"          "brainstorming" "case-insensitive"
pass "brainstorming triggers fire on design-shaped topics"

# debugging triggers
assert_eq "$(cw_consult_classify_topic 'why is the consult timing out')"   "debugging" "why"
assert_eq "$(cw_consult_classify_topic 'find edge cases in the parser')"   "debugging" "edge case"
assert_eq "$(cw_consult_classify_topic 'login is broken after the merge')" "debugging" "broken"
assert_eq "$(cw_consult_classify_topic 'regression in checkout flow')"     "debugging" "regression"
assert_eq "$(cw_consult_classify_topic 'token-refresh bug fixture')"       "debugging" "bug"
pass "debugging triggers fire on bug-hunt topics"

# none default
assert_eq "$(cw_consult_classify_topic 'review the auth middleware')"     "none" "plain review"
assert_eq "$(cw_consult_classify_topic 'audit lib/state.sh helpers')"     "none" "audit"
assert_eq "$(cw_consult_classify_topic 'document the IPC protocol')"      "none" "doc task"
pass "none is the default for narrow review topics"

# brainstorming wins over debugging when both substrings present
assert_eq "$(cw_consult_classify_topic 'design fix for broken login')" "brainstorming" "brainstorming priority"
pass "brainstorming priority over debugging when both phrases match"

# word-boundary check: "designed by" must NOT trigger brainstorming
assert_eq "$(cw_consult_classify_topic 'designed by Alice last quarter')" "none" "word boundary on design"
assert_eq "$(cw_consult_classify_topic 'whyever it happened')"            "none" "word boundary on why"
pass "word-boundary discipline (designed/whyever do not match)"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_consult_classify_topic.sh`
Expected: FAIL — `cw_consult_classify_topic: command not found`.

- [ ] **Step 3: Implement `cw_consult_classify_topic`**

Append to `lib/consult.sh`:

```bash
# cw_consult_classify_topic <topic-text>
# Echo one of: brainstorming | debugging | none.
# Brainstorming wins ties. Triggers are case-insensitive, word-boundary-anchored.
cw_consult_classify_topic() {
  local topic="$1"
  local lower
  lower=$(printf '%s' "$topic" | tr '[:upper:]' '[:lower:]')

  # Word-boundary regex: surround triggers with explicit boundary classes.
  # Bash =~ uses POSIX ERE — \b is not portable. Use space/punct fences instead.
  local fenced=" $lower "
  fenced=${fenced//[[:punct:]]/ }   # punctuation acts as word boundary
  fenced=$(printf '%s' "$fenced" | tr -s ' ')

  local brain_re='( design | how should | best way | structure | decide between | what.s the best way | what is the best way )'
  local debug_re='( why | broken | failing | regression | edge case | bug | doesn.t work | does not work )'

  if [[ "$fenced" =~ $brain_re ]]; then
    printf 'brainstorming\n'
  elif [[ "$fenced" =~ $debug_re ]]; then
    printf 'debugging\n'
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
git commit -m "feat(consult): cw_consult_classify_topic — brainstorming/debugging/none

Regex-based topic classifier with word-boundary discipline. Brainstorming
wins ties. Used by consult-init to pick a skill hint per consult run."
```

---

## Task 2: `consult-init.sh` writes `_consult/skill.txt`

**Files:**
- Modify: `bin/consult-init.sh`
- Test: `tests/test_consult_init.sh` (extend)

- [ ] **Step 1: Extend the test (failing case)**

Open `tests/test_consult_init.sh`. Add after the existing `general.txt` block:

```bash
# 2c. skill.txt holds one of {brainstorming, debugging, none}.
skill=$(cat "$CLONE_WARS_HOME/state/$RH/$topic/_consult/skill.txt")
[[ "$skill" =~ ^(brainstorming|debugging|none)$ ]] || { echo "FAIL: skill='$skill' not in pool" >&2; exit 1; }
pass "skill.txt holds a valid classifier value"

# 2d. brainstorming-shaped topic produces skill=brainstorming.
topic_brain=$(init_topic "how should we design the cache layer")
skill_brain=$(cat "$CLONE_WARS_HOME/state/$RH/$topic_brain/_consult/skill.txt")
assert_eq "$skill_brain" "brainstorming" "brainstorming topic classified"
pass "brainstorming-shaped topic auto-selects brainstorming skill"

# 2e. debugging-shaped topic produces skill=debugging.
topic_dbg=$(init_topic "why is the test suite failing on macOS")
skill_dbg=$(cat "$CLONE_WARS_HOME/state/$RH/$topic_dbg/_consult/skill.txt")
assert_eq "$skill_dbg" "debugging" "debugging topic classified"
pass "debugging-shaped topic auto-selects debugging skill"
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

## Task 3: Skill-hint files (brainstorming, debugging, none)

**Files:**
- Create: `config/skill-hints/brainstorming.md`
- Create: `config/skill-hints/debugging.md`
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

[[ -f "$HINTS/brainstorming.md" ]] || { echo "FAIL: brainstorming.md missing" >&2; exit 1; }
[[ -f "$HINTS/debugging.md"     ]] || { echo "FAIL: debugging.md missing"     >&2; exit 1; }
[[ -f "$HINTS/none.md"          ]] || { echo "FAIL: none.md missing"          >&2; exit 1; }
pass "all three skill-hint files exist"

# none.md must be empty (or whitespace only).
[[ ! -s "$HINTS/none.md" ]] || [[ -z "$(tr -d '[:space:]' < "$HINTS/none.md")" ]] \
  || { echo "FAIL: none.md must be empty for no-op append" >&2; exit 1; }
pass "none.md is empty"

# brainstorming + debugging must mention the autonomy contract.
grep -q 'AUTONOMY CONTRACT'  "$HINTS/brainstorming.md" || { echo "FAIL: brainstorming.md missing autonomy contract" >&2; exit 1; }
grep -q 'AUTONOMY CONTRACT'  "$HINTS/debugging.md"     || { echo "FAIL: debugging.md missing autonomy contract"     >&2; exit 1; }
pass "brainstorming + debugging hints both contain autonomy contract"

# Both must mention the question event format.
grep -q '"event":"question"' "$HINTS/brainstorming.md" || { echo "FAIL: brainstorming.md missing question event format" >&2; exit 1; }
grep -q '"event":"question"' "$HINTS/debugging.md"     || { echo "FAIL: debugging.md missing question event format"     >&2; exit 1; }
pass "question event format documented in both hints"

# Both must mention the ANSWER: parse contract.
grep -q 'ANSWER:' "$HINTS/brainstorming.md" || { echo "FAIL: brainstorming.md missing ANSWER: contract" >&2; exit 1; }
grep -q 'ANSWER:' "$HINTS/debugging.md"     || { echo "FAIL: debugging.md missing ANSWER: contract"     >&2; exit 1; }
pass "ANSWER: response contract documented in both hints"
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

3. Do not pre-classify questions as critical/non-critical. The general
   makes that call. Just ask plainly.

4. Be concrete. "Should we use Postgres or DynamoDB?" is good.
   "What database?" is too open — answer it yourself with a default.

5. Document each Q&A in your findings.md as:
     [Q&A] question: <q> // answer: <a> (resolved by general)
   This lets the consult reader see the design choices that shaped the
   findings.

6. If the skill says "ask the user X", you ask the GENERAL X via this
   protocol. The general will relay to the user only if the question is
   critical. Otherwise the general answers from topic context.
```

Create `config/skill-hints/debugging.md`:

```markdown
SKILL HINT — this consult is bug-hunt shaped.

Use the `superpowers:debugging` skill to structure your investigation.
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

3. Do not pre-classify questions as critical/non-critical. The general
   makes that call. Just ask plainly.

4. Be concrete. "Is the error from the Postgres driver or our wrapper?"
   is good. "What's wrong?" is too open — investigate first.

5. Document each Q&A in your findings.md as:
     [Q&A] question: <q> // answer: <a> (resolved by general)

6. If the skill says "ask the user X", you ask the GENERAL X via this
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
git commit -m "feat(consult): skill-hint files for brainstorming/debugging/none

Three files under config/skill-hints/. Brainstorming + debugging share
the autonomy contract by literal duplication (more robust than partial
include). none.md is empty for no-op append."
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_consult_skill_hint.sh`
Expected: FAIL — `cw_consult_skill_hint_append: command not found`.

- [ ] **Step 3: Add the lib helper**

Append to `lib/consult.sh`:

```bash
# cw_consult_skill_hint_append <skill-txt-path> <base-prompt>
# Echoes base-prompt followed by the skill-hint content (if any).
# Missing skill.txt or skill=none produces base-prompt unchanged.
cw_consult_skill_hint_append() {
  local skill_path="$1"
  local base="$2"
  local skill="none"
  [[ -f "$skill_path" ]] && skill=$(tr -d '[:space:]' < "$skill_path")
  case "$skill" in
    brainstorming|debugging) : ;;
    *) printf '%s' "$base"; return 0 ;;
  esac
  local hint_file="$PLUGIN_ROOT/config/skill-hints/$skill.md"
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
  # Encode newlines as %0A. Bash parameter expansion handles this in-place.
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
```

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

## Task 6: Wait-scripts handle the `question` event

**Files:**
- Modify: `bin/consult-research-wait.sh`
- Modify: `bin/consult-verify-wait.sh`
- Modify: `lib/consult.sh` (add `cw_consult_question_extract_from_outbox`)
- Test: `tests/test_consult_question_event.sh` (extend)
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

- [ ] **Step 3: Add `cw_consult_question_extract_from_outbox` helper**

Append to `lib/consult.sh`:

```bash
# cw_consult_question_extract_from_outbox <outbox-path> <byte-offset>
# Find the FIRST {"event":"question",...} line after byte-offset.
# Echoes "TEXT|OPTIONS" (pipe-separated; OPTIONS empty if absent).
# rc=0 on found, rc=1 on not found.
cw_consult_question_extract_from_outbox() {
  local outbox="$1" offset="$2"
  [[ -f "$outbox" ]] || return 1
  # Read from offset, find first question line.
  local line
  line=$(tail -c +$((offset + 1)) "$outbox" | grep -m1 '"event":"question"' || true)
  [[ -n "$line" ]] || return 1
  # Extract text via grep -oP-style without perl: use sed.
  local text opts
  text=$(printf '%s' "$line" | sed -n 's/.*"text":"\([^"]*\)".*/\1/p')
  opts=$(printf '%s' "$line" | sed -n 's/.*"options":\[\([^]]*\)\].*/\1/p' \
                              | sed 's/"//g; s/, */|/g; s/,/|/g')
  printf '%s|%s\n' "$text" "$opts"
}
```

- [ ] **Step 4: Update `bin/consult-research-wait.sh`**

Replace the `cw_outbox_wait_since` line:

```bash
cw_outbox_wait_since "$COMMANDER" "$MODEL" "$TOPIC" "$OFFSET" done error "$TIMEOUT" >/dev/null || true
```

with:

```bash
cw_outbox_wait_since "$COMMANDER" "$MODEL" "$TOPIC" "$OFFSET" done error question "$TIMEOUT" >/dev/null || true
```

Replace the FS-write block (after the wait):

```bash
TROOPER_DIR=$(cw_trooper_dir "$COMMANDER" "$MODEL" "$TOPIC")
FS=$(cw_consult_findings_status "$TROOPER_DIR/findings.md")
printf 'FS=%s\n' "$FS" >> "$STATE_FILE"
```

with:

```bash
TROOPER_DIR=$(cw_trooper_dir "$COMMANDER" "$MODEL" "$TOPIC")
OUTBOX="$TROOPER_DIR/outbox.jsonl"

# Question events take priority — if there's a question after OFFSET, route
# to the question path even if findings.md happens to be present.
Q_EXTRACT=$(cw_consult_question_extract_from_outbox "$OUTBOX" "$OFFSET" || true)
if [[ -n "$Q_EXTRACT" ]]; then
  Q_TEXT="${Q_EXTRACT%|*}"
  Q_OPTS="${Q_EXTRACT##*|}"
  cw_consult_question_payload_write \
    "$ART_DIR/question-$COMMANDER.txt" "$Q_TEXT" "$Q_OPTS" "research"
  printf 'FS=question\n' >> "$STATE_FILE"
  log_info "[research-wait] $COMMANDER FS=question"
  exit 0
fi

FS=$(cw_consult_findings_status "$TROOPER_DIR/findings.md")
printf 'FS=%s\n' "$FS" >> "$STATE_FILE"
log_info "[research-wait] $COMMANDER FS=$FS"
```

- [ ] **Step 5: Update `bin/consult-verify-wait.sh` symmetrically**

Same two changes, but `verify` instead of `research`, and `VS=question` instead of `FS=question`. Use `cw_consult_verify_status` instead of `cw_consult_findings_status`. The trooper-output filename is `verify.md` not `findings.md`.

- [ ] **Step 6: Run tests**

```bash
bash tests/test_consult_question_event.sh
bash tests/test_consult_research_wait.sh
bash tests/test_consult_verify_wait.sh
```

Expected: all PASS. Existing wait-script tests already cover `done`/`error`/`timeout`/`empty` paths — those should still pass.

- [ ] **Step 7: Commit**

```bash
git add bin/consult-research-wait.sh bin/consult-verify-wait.sh \
        lib/consult.sh tests/test_consult_question_event.sh
git commit -m "feat(consult): wait-scripts catch question events → FS/VS=question

cw_outbox_wait_since now matches done|error|question. On question match,
the wait-script writes _consult/question-<commander>.txt with payload
and appends FS=question (research) or VS=question (verify) to its state
file. Existing done/error/timeout paths unchanged."
```

---

## Task 7: `--keep-findings` flag for `consult-offset-reset.sh`

**Files:**
- Modify: `bin/consult-offset-reset.sh`
- Test: `tests/test_consult_offset_reset_keep.sh`

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

Expected: both PASS.

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
2. Decide whether the question is **critical** based on the consult topic
   and findings-so-far context (you have full context as the directive):
   - critical = answer would change the topic interpretation (scope expansion,
     contradiction with explicit user constraint, binary fork with no clear
     default).
   - non-critical = clarifying question, defaulting choice, language convention.
3. Get an answer:
   - critical → `AskUserQuestion` with `TEXT` as question, `OPTIONS` as
     multiple-choice (or free-form if `OPTIONS` is empty).
   - non-critical → answer from topic context yourself (no user prompt).
4. Send the answer:
   ```
   /clone-wars:send <commander> "$CONSULT_TOPIC" "ANSWER: <the answer>

   (end of question response — resume your skill loop)
   END_OF_INSTRUCTION"
   ```
5. Reset the offset past the question, preserving findings:
   ```
   "$CLAUDE_PLUGIN_ROOT/bin/consult-offset-reset.sh" "$CONSULT_TOPIC" \
      <commander> research --keep-findings
   "$CLAUDE_PLUGIN_ROOT/bin/consult-research-send.sh" "$CONSULT_TOPIC" \
      <commander> <model>
   ```
6. Loop back to the top of Step 3 (re-run BOTH wait-scripts; the unblocked
   trooper proceeds, the other is unaffected).

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
2. Classify:
   - critical → `AskUserQuestion(TEXT, OPTIONS)`.
   - non-critical → answer from topic context (the consult topic plus any
     findings-so-far you've read).
3. Send the answer:
   ```
   /clone-wars:send <commander> "$CONSULT_TOPIC" "ANSWER: <answer>

   (end of question response — resume your skill loop)
   END_OF_INSTRUCTION"
   ```
4. Reset the offset past the question, preserving findings:
   ```
   "$CLAUDE_PLUGIN_ROOT/bin/consult-offset-reset.sh" "$CONSULT_TOPIC" \
      <commander> <phase> --keep-findings
   ```
5. Re-arm the wait:
   ```
   "$CLAUDE_PLUGIN_ROOT/bin/consult-research-send.sh" "$CONSULT_TOPIC" \
      <commander> <model>          # research
   # or:
   "$CLAUDE_PLUGIN_ROOT/bin/consult-verify-send.sh" "$CONSULT_TOPIC" \
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

## Task 9: End-to-end mocked round-trip test

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

# Phase 2: directive simulates answering. Reset --keep-findings, advance offset.
../bin/consult-offset-reset.sh "$TOPIC" rex research --keep-findings
[[ ! -f "$TD/_consult/question-rex.txt" ]] \
  || { echo "FAIL: payload should be cleared after offset-reset" >&2; exit 1; }
pass "round-trip phase 2: offset-reset --keep-findings clears payload"

# Phase 3: trooper resumes, emits done. New offset starts after the question line.
OFFSET_AFTER_Q=$(wc -c < "$OUTBOX" | tr -d ' ')
echo '{"event":"done"}' >> "$OUTBOX"
echo "stub findings" > "$TD/rex-codex/findings.md"
echo "[citation] sample claim" >> "$TD/rex-codex/findings.md"

# Re-stage state file to mirror what consult-research-send would do post-reset.
printf 'OFFSET=%s\n' "$OFFSET_AFTER_Q" > "$TD/_consult/research-rex.txt"

CW_CONSULT_RESEARCH_TIMEOUT_OVERRIDE=5 \
  ../bin/consult-research-wait.sh "$TOPIC" rex codex >/dev/null 2>&1

FS_FINAL=$(grep '^FS=' "$TD/_consult/research-rex.txt" | tail -1 | cut -d= -f2)
[[ "$FS_FINAL" == "ok" ]] \
  || { echo "FAIL: expected FS=ok after resume; got '$FS_FINAL'" >&2; exit 1; }
pass "round-trip phase 3: trooper resumes after answer, FS=ok"
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
git commit -m "test(consult): end-to-end question round-trip fixture

Mocks the outbox and walks through trooper emits question → wait-script
catches → offset-reset --keep-findings → trooper resumes → FS=ok. Proves
the v0.3 protocol is wired end-to-end."
```

---

## Task 10: v0.3.0 release polish

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
general while running `superpowers:brainstorming` or `superpowers:debugging`
skills. Most questions are answered inline by the general; only critical
ones (option-forks that would change the topic interpretation) reach the
user via `AskUserQuestion`.

- One skill is auto-picked per consult run based on topic shape:
  - design / "how should" / "decide between" → `superpowers:brainstorming`
  - "why" / "broken" / "edge case" / "regression" → `superpowers:debugging`
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
debugging/none), skill-hint files with autonomy contract, --keep-findings
flag on offset-reset, and Pattern 4 critical-question relay. Existing
v0.2.1 dogfood path unchanged when topic classifies as 'none'.

Spec: docs/superpowers/specs/2026-04-29-clone-wars-consult-question-protocol-design.md"
```

---

## Test summary

| Test | Status | Coverage |
|---|---|---|
| `test_consult_classify_topic.sh` | new | regex matches, word-boundary, priority ties |
| `test_consult_skill_hint.sh` | new | hint files + send-script append, none default |
| `test_consult_question_event.sh` | new | payload helpers, wait-script catches event |
| `test_consult_offset_reset_keep.sh` | new | --keep-findings flag |
| `test_consult_question_loop.sh` | new | end-to-end mock round-trip |
| `test_consult_init.sh` | extended | skill.txt assertion |
| `test_consult_research_wait.sh` | extended | question-event case |
| `test_consult_verify_wait.sh` | extended | question-event case |

---

## Branch + PR plan

- All 10 tasks land on `feat/v0.3-question-protocol`.
- Each task is one commit. PR opens after Task 10.
- Bisect-safe: every commit through Task 9 keeps existing v0.2.1 paths green
  (skill.txt missing → `none` → no append; question event optional).
- v0.2.1 must merge first; rebase `feat/v0.3-question-protocol` onto post-merge
  main before opening the PR.

---

## Self-review against spec

- ✅ All 5 spec sections (protocol, classifier, skill hints, directive loop, intervention pattern) have implementation tasks.
- ✅ All 5 spec test specifications have matching test files (Tasks 1, 3, 6, 7, 9).
- ✅ The `--keep-findings` flag covered in Task 7 matches the spec contract (preserve trooper output + cascade artifacts; clear payload).
- ✅ Both research and verify paths covered symmetrically (Tasks 4, 6, 8).
- ✅ Backwards-compat tests included (Task 4: missing skill.txt; Task 7: existing offset-reset behavior unchanged).
- ✅ The autonomy contract from the spec is reproduced verbatim in Task 3's hint files.
- ✅ Every code step shows the actual code; no placeholders.
- ✅ Every test step shows the actual assertions; no "similar to above".
- ✅ Type/symbol consistency: `cw_consult_classify_topic`, `cw_consult_skill_hint_append`, `cw_consult_question_payload_{read,write}`, `cw_consult_question_extract_from_outbox` all named identically across spec and plan.
