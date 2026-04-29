# /clone-wars:consult v0.3 — Trooper Question Protocol + Skill Routing

**Status:** Design — Revision 2 (post-Codex adversarial review, 2026-04-29)
**Date:** 2026-04-29
**Target version:** v0.3.0
**Builds on:** v0.2.1 (split orchestrator + Jedi general pool)
**Spec it extends:** `docs/superpowers/specs/2026-04-29-clone-wars-consult-v2-design.md`

## Revision 2 changelog (closes Codex adversarial findings)

| # | Codex Rev1 finding | Resolution in this revision |
|---|---|---|
| H1 | Re-arm step double-writes inbox (`cw_send` ANSWER then phase send-script overwrites the same `inbox.md` and nudges again) | Answer-resume path no longer calls the phase send-script. Wait-script auto-advances `OFFSET=` in the per-commander state file when a `question` event is matched. Directive's recipe is: `cw_send ANSWER → consult-research-wait.sh` (no send-script invocation). `consult-offset-reset.sh --keep-findings` removed from Pattern 4 — the flag stays only for Patterns 1/3 cascade resets. |
| H2 | Wait-script ignores the matched event and rescans for `question` from the original offset, masking trailing `done`/`error` | Wait-script now captures `cw_outbox_wait_since` stdout (the matched JSON line), parses `event=…`, and branches on the actual matched event. No standalone rescan. New fixtures cover `question→error`, `question→done`, multi-question windows. |
| H3 | Task 9 mocks the protocol it's meant to prove (no real trooper, no real skill) | New Task 10 (real-CLI dogfood) gated on `command -v codex && command -v tmux`: spawns a live trooper with the autonomy contract + brainstorming-shaped task, asserts it actually emits `event=question`, answers via cw_send, asserts trooper resumes and emits `done`. Mock test stays as Task 9 for fast unit coverage. |
| M4 | Hint referenced `superpowers:debugging`, but the installed skill is `superpowers:systematic-debugging` | Renamed everywhere: classifier emits `systematic-debugging` (not `debugging`); hint file is `config/skill-hints/systematic-debugging.md`. Test asserts every skill name in hint files resolves to an installed `SKILL.md` under `~/.claude/plugins/cache/.../superpowers/.../skills/<name>/`. |
| M5 | JSON-via-sed extractor accepts malformed payloads, escaped quotes truncate text, missing `text` still yields non-empty extraction | Extractor validates: `text` must be present and non-empty. Missing/unparsable `text` → `FS=failed`/`VS=failed` (not `question`). New fixtures: escaped-quote, missing-text, embedded-backslash, empty-options, malformed-JSON. |

Lower-severity tightening from the same review:

- Helper `cw_consult_skill_hint_append` asserts `PLUGIN_ROOT` (or `CLAUDE_PLUGIN_ROOT`) is set; fail loud, not silent no-append.
- Directive Step 3/5 explicitly Reads `$TROOPER_DIR/findings.md` (or `verify.md`) BEFORE classifying critical/non-critical — without that, the classifier has no findings-so-far context.
- `CW_CONSULT_SKILL_OVERRIDE=none` env var bypasses the classifier (kill-switch). Send-scripts respect it; covered by a unit test.

---

## Goal

Let troopers ask questions back to the Jedi general during the research and
verify phases, so that `superpowers:brainstorming` and `superpowers:systematic-debugging`
can run inside a trooper without deadlocking on their question loops.

Two outcomes:

1. **Most questions never reach the user.** The general (the Claude Code
   session running the slash directive) classifies each question and answers
   it autonomously when it has enough context.
2. **Critical questions reach the user, serialized.** When a question would
   change the topic's interpretation (option-fork, contradiction with a
   user-stated constraint), the general escalates via `AskUserQuestion`.
   If both troopers escalate at once, the general handles them one at a time
   in arrival order — never interleaved.

The `/superpowers` plugin is installed for both providers in this plugin's
target environment (Claude Code and Codex CLI both ship with it). v0.3
exposes that capability inside the consult lifecycle.

---

## Motivation

In the v0.2 dogfood, both troopers produced reasonable findings without ever
asking a question — but only because the prompts were narrow ("review
function X for edge cases"). For broader prompts ("how should we approach Y"),
`superpowers:brainstorming` is the natural shape, and it asks one design
question at a time. With no question-back channel, the trooper would either:

- block forever waiting for the conductor (deadlock — the v0.2 wait-script
  only watches for `done` / `error`), or
- skip the skill and produce un-grounded findings (defeats the point).

v0.3 adds the channel, plus a skill-hint that tells the trooper which
superpower-skill is appropriate for the topic shape, plus the autonomy
contract so the trooper does not pile up trivial questions.

---

## Non-goals

- **Implementation handoff.** The consult is design-only; v0.3 does not invoke
  `superpowers:writing-plans` after synthesis. The user explicitly rejected
  that integration on 2026-04-29.
- **Fan-out beyond two troopers.** The question protocol is symmetric for the
  two-trooper consult; multi-trooper or multi-question-batch is out of scope.
- **Persistent question history.** Questions live in the consult state dir
  for the duration of the run, then archive with the rest of `_consult/`.
  We do not build a separate question log.
- **Skill mid-phase switching.** One skill per consult run, picked once at
  init. Switching skills mid-run means a fresh consult.

---

## Architecture

```
slash directive
   │
   │  Step 0 (existing): consult-init.sh classifies topic → skill.txt
   │  Step 1 (existing): parallel spawn
   │  Step 2 (existing): parallel research-send (now appends skill hint + autonomy block)
   │
   ▼
Step 3 (REDESIGNED): research-wait loop
   │
   │  while not (rex_done && cody_done):
   │    parallel: consult-research-wait.sh × 2
   │      (each exits on FIRST of: done | error | question | timeout)
   │    for trooper in [rex, cody] with FS=question:
   │       q = read question-<commander>.txt
   │       critical = general.classify(q)        ← directive does the call
   │       if critical:
   │         a = AskUserQuestion(q.text, q.options)
   │       else:
   │         a = general.answer(q)               ← directive does the call
   │       cw_send <commander> "$a"              ← writes to inbox
   │    troopers with FS=ok|failed → mark done
   │
   ▼
Steps 4–10 (existing): diff, verify (same loop), adjudicate, synthesize, …
```

The redesign touches only Step 3 and Step 5 (research-wait and verify-wait).
The question loop is identical in both phases.

---

## Protocol additions

### New outbox event: `question`

Trooper appends one line of JSON to `outbox.jsonl`:

```json
{"event":"question","text":"<the question>","options":["A","B"]}
```

- `text` (required) — the natural-language question.
- `options` (optional) — if the trooper sees a forced binary/n-ary choice,
  it lists the options so the general can pattern-match faster. Free-form
  questions omit this field.
- The trooper MUST set `status.json.state = "blocked"` before emitting and
  MUST poll its inbox until a fresh write replaces the previous content.
  Once the inbox is rewritten, the trooper resumes and updates status to
  `working`.

The trooper sends one question at a time — no batching. After receiving the
answer, it may emit another `question` event if the skill needs more.

Existing event types (`ready`, `ack`, `done`, `error`) are unchanged.

### Wait-script change

`bin/consult-research-wait.sh` and `bin/consult-verify-wait.sh` change their
awaited event set AND start capturing the matched line:

- v0.2: `cw_outbox_wait_since … done error <timeout> >/dev/null` (stdout discarded)
- v0.3: `MATCHED=$(cw_outbox_wait_since … done error question <timeout>)` (stdout captured)

`cw_outbox_wait_since` already prints the matched JSON line on success
(`lib/ipc.sh:209`). The wait-script parses the event field from that line
and branches on the **actually-matched event** — never on a standalone
rescan of the outbox:

```bash
MATCHED=$(cw_outbox_wait_since "$COMMANDER" "$MODEL" "$TOPIC" "$OFFSET" \
                                done error question "$TIMEOUT" || true)
EVENT=$(printf '%s' "$MATCHED" | sed -n 's/.*"event":"\([^"]*\)".*/\1/p')
NEW_OFFSET=$(wc -c < "$OUTBOX" | tr -d ' ')

case "$EVENT" in
  question)
    # Validate text exists before treating as question.
    cw_consult_question_validate_line "$MATCHED" || {
      log_warn "[wait] $COMMANDER malformed question event; treating as failed"
      printf 'FS=failed\n' >> "$STATE_FILE"
      exit 0
    }
    cw_consult_question_extract_to_payload "$MATCHED" \
        "$ART_DIR/question-$COMMANDER.txt" "research"
    printf 'OFFSET=%s\n' "$NEW_OFFSET" >> "$STATE_FILE"   # last-wins on re-arm
    printf 'FS=question\n' >> "$STATE_FILE"
    ;;
  done)
    FS=$(cw_consult_findings_status "$TROOPER_DIR/findings.md")
    printf 'FS=%s\n' "$FS" >> "$STATE_FILE"
    ;;
  error)
    printf 'FS=failed\n' >> "$STATE_FILE"
    ;;
  '')   # timeout — no match within window
    printf 'FS=timeout\n' >> "$STATE_FILE"
    ;;
  *)    # unknown event leaked into the awaited set
    log_warn "[wait] $COMMANDER unknown event '$EVENT'; treating as failed"
    printf 'FS=failed\n' >> "$STATE_FILE"
    ;;
esac
```

Final FS / VS values:

| matched event | FS / VS value | Notes |
|---|---|---|
| `done` (findings.md present + parsable) | `ok` | existing v0.2 behavior |
| `done` (findings.md missing/empty/malformed) | `missing`/`empty`/`malformed` | existing v0.2 behavior |
| `error` | `failed` | existing v0.2 behavior |
| `question` (text validates) | `question` (NEW) | also writes `_consult/question-<commander>.txt`; appends `OFFSET=<post-question-byte>` to state file |
| `question` (malformed payload, missing text) | `failed` | M5 closure — never `question` on garbage |
| no match within timeout | `timeout` | existing v0.2 behavior |

**Re-arm contract (H1 closure):** when `FS=question`, the wait-script has
already advanced `OFFSET=` past the matched question line. The directive's
recovery is just `cw_send ANSWER → re-run consult-research-wait.sh`. The
re-run's `source $STATE_FILE` picks up the latest `OFFSET=` (last-wins).
**The phase send-script (`consult-research-send.sh`) is NOT called again** —
calling it would overwrite `inbox.md` (clobbering the ANSWER) and rebuild
the prompt from scratch.

### Critical-question file format

`_consult/question-<commander>.txt` is read by the directive. Plain key=value
lines, atomic write (tmp + rename):

```
TEXT=<one-line, percent-encoded if it contains newlines>
OPTIONS=A|B|C       # pipe-separated; absent if free-form
ASKED_AT=<unix-ts>
PHASE=research      # or verify
```

The directive parses this with `awk -F=` — no JSON parser dependency.
`TEXT` is decoded with a tiny `printf '%b'` step on `%xx` sequences (only
`%0A` for newlines is supported).

### Inbox-answer format

The general's reply is plain text written to the trooper's `inbox.md` via
existing `cw_send`:

```
ANSWER: <the resolved answer text>

(end of question response — resume your skill loop)
END_OF_INSTRUCTION
```

Format-pinned so the trooper can parse it deterministically. The leading
`ANSWER:` token is the resume signal; the trooper reads the line and resumes
the skill loop with that text as the question response.

The trooper does NOT see whether the answer came from the user or from the
general — both are opaque from its perspective. This keeps trooper-side
logic identical regardless of escalation path.

---

## Topic classifier

`bin/consult-init.sh` gains a classifier step. After it picks the slug and
the Jedi general, it inspects the topic text and writes one of three values
to `_consult/skill.txt`:

| Skill value | Triggers (word-boundary, case-insensitive) |
|---|---|
| `brainstorming` | "design pattern", "how should", "what's the best way", "what is the best way", "decide between" |
| `systematic-debugging` | "why", "broken", "failing", "regression", "edge case", "bug", "doesn't work", "does not work" |
| `none` | default — narrow review/audit topics, anything not matching above |

Trigger refinements (M-tier from Codex Rev1):

- `"design"` alone is too broad — "designed by Alice last quarter" should
  not classify. Trigger requires `"design pattern"` or pairs with
  `"how should"`/`"decide between"`.
- `"structure"` is dropped from triggers entirely — "review the auth
  middleware structure" is plain audit, not design.
- `"approach"` is dropped — "approach to error handling" is too generic.
- "audit X for bugs" → `systematic-debugging` wins because `"bug"`
  matches and `"design pattern"` does not.
- "review the database structure" → `none` (no triggers match).

Triggers are checked case-insensitively against word boundaries (space-
or punctuation-fenced — see Task 1 in the plan for exact bash). First
match wins, brainstorming checked before systematic-debugging. When
neither matches, `none` is written.

The classifier is intentionally simple regex matching — not LLM-based. The
choice is logged but is overridable two ways:

1. **Static override:** edit `_consult/skill.txt` before Step 2 to one of
   `brainstorming` / `systematic-debugging` / `none`.
2. **Env-var kill-switch (NEW):** `CW_CONSULT_SKILL_OVERRIDE=none` in the
   directive's environment forces send-scripts to use `none.md` regardless
   of `skill.txt`. Used to disable the protocol mid-incident without
   editing files. Send-scripts test for it; covered by a unit test.

---

## Skill hint in inbox prompts

`bin/consult-research-send.sh` and `bin/consult-verify-send.sh` append a
skill-hint block to the inbox prompt they generate. The block is read from
`config/skill-hints/<skill>.md` (a new directory). Three files ship:

- `config/skill-hints/brainstorming.md` — invokes `superpowers:brainstorming`,
  includes the autonomy contract.
- `config/skill-hints/systematic-debugging.md` — invokes `superpowers:systematic-debugging`,
  includes the autonomy contract.
- `config/skill-hints/none.md` — empty file (no skill hint appended).

The send-script reads `_consult/skill.txt`, then concatenates the matching
hint file onto the existing prompt. If `skill.txt` is missing (older state
dirs), it defaults to `none.md` (empty append) — backwards compatible.

### The autonomy contract

This block is shared between the brainstorming and debugging hint files
(by literal duplication — keeping each hint file standalone is more robust
than a partial-include macro):

```
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
   critical (option-fork that affects >50% of findings, or contradiction
   with the topic). Otherwise the general answers from topic context.
```

The block is identical for both skills; only the leading "Use this skill"
line differs.

---

## Directive Step 3 — research wait loop (redesigned)

Pseudocode that the directive translates into bash + tool calls:

```
rex_done=false
cody_done=false
while ! ($rex_done && $cody_done); do
  # PARALLEL Bash calls (one per still-running trooper)
  if ! $rex_done;  then run consult-research-wait.sh $TOPIC rex  codex   in background
  if ! $cody_done; then run consult-research-wait.sh $TOPIC cody claude  in background
  # both are short-lived (each exits on first event/timeout)

  # After both return, read FS values
  REX_FS  = grep '^FS=' research-rex.txt  | tail -1 | cut -d= -f2
  CODY_FS = grep '^FS=' research-cody.txt | tail -1 | cut -d= -f2

  for trooper in [rex (codex), cody (claude)]:
    case $FS in
      ok|empty|missing)        mark done ;;
      failed|timeout|malformed) mark done with-warning ;;
      question)
         Q = read _consult/question-<commander>.txt
         # H1 + low-tier closure: directive MUST Read findings-so-far
         # before classifying — without it, "findings-so-far context"
         # is fictional.
         FINDINGS = Read $TROOPER_DIR/findings.md (if exists)
         CRITICAL = directive_classify(Q.TEXT, $CONSULT_TOPIC, FINDINGS)
         if CRITICAL:
            ANS = AskUserQuestion(Q.TEXT, Q.OPTIONS)
         else:
            ANS = directive_answer(Q.TEXT, $CONSULT_TOPIC, FINDINGS)
         cw_send $COMMANDER "ANSWER: $ANS\n\n…\nEND_OF_INSTRUCTION"
         # H1 closure: re-arm = re-run wait-script ONLY. Do NOT call
         # consult-research-send.sh — it would overwrite inbox.md
         # (clobbering ANSWER) and reset OFFSET to a fresh value.
         (next loop iteration re-runs wait-script for this trooper;
          the wait-script's source of state-file picks up the
          OFFSET= line the prior wait appended past the question)
         # do NOT mark done; loop iterates
      *)  unknown FS — log + treat as failed ;;
    esac
done
```

**Re-arm contract (H1 closure):** the answer-resume path is exactly:
1. `cw_send <commander> "ANSWER: …"` — writes inbox.md + nudges pane.
2. Re-run `consult-research-wait.sh <topic> <commander> <model>`.

That's it. The wait-script's first action is `source $STATE_FILE`; bash's
last-assignment-wins on `OFFSET=` means it picks up the post-question
offset the previous wait-iteration appended. The phase send-script is
**never** called as part of the question loop — it's only used for the
initial dispatch (Step 2) and for full-cascade re-prompts (Patterns 1 / 3).

### Critical classification — who decides

The directive (the Jedi general's reasoning) decides. Heuristics it uses:

- **Critical** if the answer would change a section already committed to
  `_consult/topic.txt` (e.g., topic says "review the auth middleware";
  question is "should I include the rate-limiter too?" — yes, this expands
  the scope, ask the user).
- **Critical** if the question contradicts an explicit user statement
  (e.g., topic says "do not consider Redis"; question is "use Redis or
  Memcached for caching?" — escalate; the user may want to relax the
  constraint).
- **Critical** if there is a binary fork with no clear default
  (e.g., "synchronous or eventual consistency?" with no domain context
  pointing one way).
- **Non-critical** if it's a defaulting question
  (e.g., "use camelCase or snake_case for API field names?" — pick the
  language's convention from the topic).
- **Non-critical** if it's a clarifying question already answered by
  topic context (e.g., topic says "Python service"; question is "what
  language are we in?" — answer "Python", do not escalate).

There is no fixed budget. The directive trusts itself to escalate
appropriately. If the directive misjudges, the user can ctrl-c and edit
`_consult/skill.txt` to `none` to disable skill-driven questioning entirely.

### Serialization across troopers

Both wait-scripts can exit simultaneously with `FS=question` (both troopers
asked questions in the same window). The directive's loop processes them
sequentially:

```
for trooper in [rex, cody]:    # ordered iteration
  if FS=question:
    handle (classify + answer/escalate + cw_send)
```

The user-facing AskUserQuestion is single-channel — by the time the
directive moves to trooper #2, trooper #1's answer is already sent.
The user sees one prompt at a time.

---

## `cw_consult_offset_reset --keep-findings` (helper extension)

The `--keep-findings` flag is **NOT** part of the question-loop path
(H1 closure — the wait-script auto-advances `OFFSET=` itself, so no
caller needs to reset offsets in that path). The flag exists for
**Patterns 1 and 3** (malformed-findings re-prompt, all-UNCERTAIN re-prompt)
where the conductor wants to reset the per-commander state file but
preserve work done in adjudicated.md.

```
bin/consult-offset-reset.sh <topic> <commander> <phase> --keep-findings
```

When `--keep-findings`:

- Removes `_consult/<phase>-<commander>.txt` (the per-commander state).
- Always removes `_consult/question-<commander>.txt` if pending.
- Does NOT remove `findings.md` (research) or `verify.md` (verify).
- Does NOT remove the cascade artifacts (`diff.md`, `*_only_items.txt`,
  `adjudicated-draft.md`).

Without `--keep-findings` (default), behavior is unchanged from v0.2:
full cascade removal. Used for full re-prompts (Patterns 1 / 3).

---

## Intervention Pattern 4: Critical-question relay

Added to `commands/consult.md` next to existing Patterns 1 and 3:

```
### Pattern 4: Critical-question relay

When a wait-script reports FS=question (research) or VS=question (verify):

1. Read _consult/question-<commander>.txt for TEXT and OPTIONS.
2. Read $TROOPER_DIR/findings.md (or verify.md) for findings-so-far context.
3. Classify:
   - critical → AskUserQuestion(TEXT, OPTIONS)
   - non-critical → answer from topic context + findings-so-far yourself
4. Send the answer:
   /clone-wars:send <commander> "$CONSULT_TOPIC" "ANSWER: <answer>
      …
      END_OF_INSTRUCTION"
5. Re-run the matching wait-script (NO send-script, NO offset-reset):
   $CLAUDE_PLUGIN_ROOT/bin/consult-research-wait.sh "$CONSULT_TOPIC" \
      <commander> <model>
6. Loop until the trooper reports FS=ok / VS=ok.

The wait-script already advanced OFFSET= past the question on the first
match; the re-run picks up the new cursor via source $STATE_FILE.

Both troopers may emit questions independently. Process them in iteration
order; the user sees critical prompts sequentially.
```

The directive's Step 3 already encodes this loop programmatically; Pattern 4
is the documented per-step recovery recipe (parallel with Patterns 1 and 3).

---

## File layout additions

```
config/skill-hints/
  brainstorming.md           ← skill-pick + autonomy contract for design topics
  systematic-debugging.md    ← skill-pick + autonomy contract for bug-hunt topics
  none.md                    ← empty (no append)

state-dir/_consult/
  skill.txt                  ← classifier output (one of: brainstorming|debugging|none)
  question-<commander>.txt   ← TEXT/OPTIONS/ASKED_AT/PHASE while a question is pending
                                (deleted by consult-offset-reset.sh after handling)

commands/consult.md          ← Step 3 + Step 5 redesigned to encode the question loop;
                                Pattern 4 added to intervention section
```

`research-<commander>.txt` and `verify-<commander>.txt` schemas extend with
`FS=question` / `VS=question` as a new value; existing values unchanged.

---

## Backwards compatibility

- **State dirs from v0.2** without `_consult/skill.txt` get treated as
  `skill=none` by send scripts; behaviour is identical to v0.2.
- **Troopers that never emit `question`** are unaffected — the wait-script
  still handles `done`/`error`/timeout the same way.
- **The `--keep-findings` flag** is opt-in; existing offset-reset callers
  (Patterns 1, 3) do not pass it and still get full cascade.
- **`AskUserQuestion`** is already a Claude Code tool the directive can
  call; no new tool dependency.

---

## Testing strategy

Six new test files plus extensions to existing ones:

1. `tests/test_consult_classify_topic.sh` — covers the classifier's regex
   matches across brainstorming/systematic-debugging/none, including
   refined trigger discipline (M-tier from Codex Rev1):
   - "designed by" → none, "design pattern" → brainstorming
   - "review the database structure" → none ("structure" dropped from triggers)
   - "audit X for bugs" → systematic-debugging (bug match, no design match)
   - "approach to error handling" → none ("approach" dropped)
2. `tests/test_consult_skill_hint.sh` — send-script appending the right
   hint file; `skill=none` (no append); missing `skill.txt` (default to none);
   `CW_CONSULT_SKILL_OVERRIDE=none` env-var override; PLUGIN_ROOT must be
   set (asserts loud failure if unset). NEW: every skill name in hint
   files resolves to an installed `SKILL.md` (M4 closure).
3. `tests/test_consult_question_event.sh` — wait-script catches `question`
   event, writes payload, appends `OFFSET=<post-question>` then
   `FS=question`. NEW: malformed-payload fixtures (M5 closure):
   - missing `text` field → FS=failed, no payload written
   - escaped quotes in text → text extracted up to escape (or FS=failed)
   - empty options array → OPTIONS empty (not garbage)
   - non-JSON line tagged `event=question` → FS=failed
4. `tests/test_consult_question_event_priority.sh` (NEW — H2 closure) —
   wait-script branches on the actual matched event:
   - outbox: `ack`, `question`, `error` (in order) → FS=failed (last match wins)
   - outbox: `ack`, `question`, `done` → FS=ok (last match wins; question gets ignored)
   - outbox: two `question` events back-to-back → only the FIRST is captured;
     OFFSET advances past it; second is captured on next wait
5. `tests/test_consult_offset_reset_keep.sh` — `--keep-findings` flag:
   removes state file + question payload, preserves findings.md /
   cascade artifacts. (Note: this flag is for Patterns 1/3 only, NOT
   the question loop.)
6. `tests/test_consult_question_loop.sh` — mock-pane round-trip
   (fast unit coverage). Trooper outbox simulated; verifies wait-script
   catch → directive cw_send → wait-script resume → FS=ok. ALSO covers
   multi-question (Q→A→Q→A→done) and FS=question + VS=question in
   adjacent phases.
7. `tests/test_consult_question_dogfood.sh` (NEW — H3 closure) — gated
   on `command -v codex && command -v tmux`. Spawns a real codex trooper
   via `bin/spawn.sh`, sends an inbox prompt with the brainstorming
   autonomy contract + a forced-fork brainstorming task, waits up to
   90s for `event=question` in the trooper's outbox, sends ANSWER via
   cw_send, waits for `event=done`, asserts the trooper's findings.md
   contains a `[Q&A]` block. Skipped (not failed) if codex/tmux missing
   or if the codex spawn returns non-zero. This is the only test that
   proves the autonomy contract actually overrides the skill's native
   AskUserQuestion call.

Extensions to existing tests:

- `test_consult_init.sh` — assertion that `skill.txt` is created with
  one of `brainstorming` / `systematic-debugging` / `none`; content checks
  against trigger phrases.
- `test_consult_research_wait.sh` — captures `MATCHED` from wait_since;
  branches on actual event; existing `done`/`error`/`timeout` cases pinned.
- `test_consult_verify_wait.sh` — same.
- `test_consult_offset_reset.sh` — verify Task 7's new arg-parser does
  not break the existing 3-arg call signature.

---

## Open issues

The autonomy contract's effectiveness is empirical — only the real-CLI
dogfood test (Task 10) confirms whether `superpowers:brainstorming` and
`superpowers:systematic-debugging` actually obey the inbox prompt's
override of their native AskUserQuestion behavior. If the dogfood fails:

- **First fallback:** strengthen the autonomy contract preamble (move the
  "ask GENERAL via outbox, NOT user via TUI" instruction to the very top
  of the inbox prompt, repeat at the bottom).
- **Second fallback:** the directive treats trooper-side TUI prompts as
  a separate failure mode — the trooper sits idle expecting a TUI reply.
  The directive can detect this via outbox silence + status=working past
  a threshold and either (a) send a synthetic ANSWER guessing the
  question, or (b) escalate to user with "trooper appears to be asking
  inside its TUI; check pane and respond directly".
- **Third fallback:** drop skill routing entirely (revert to v0.2.1
  `none.md`-equivalent prompt). The question protocol stays — just
  without the brainstorming/debugging skill invocation. This keeps the
  IPC additions useful for hand-crafted Q&A flows.

The dogfood test reports its result; the spec stays as written until it
fails.

---

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Trooper asks a malformed `question` event (missing `text`) | Wait-script validates payload; treats malformed as `error`, sets `FS=failed`, logs reason. Trooper has to retry. |
| Trooper emits multiple `question` events back-to-back without waiting | Wait-script catches the first, exits; second sits in outbox until next iteration's `cw_outbox_wait_since` advances offset past it. Effectively serialized at the offset cursor. |
| General misjudges critical/non-critical | Logged in `findings.md` as `[Q&A]`. User can review post-hoc and re-run the consult with `skill=none` if needed. |
| Question loops forever (skill in question-storm) | No hard cap, but the trooper documents each Q&A in findings.md. If `[Q&A]` count exceeds ~10, the directive nudges via cw_send: "wrap up — produce findings.md from current state". |
| User dismisses the AskUserQuestion prompt | Directive treats dismissal as "use your best default" — answers the trooper from topic context anyway. The user retains override by editing `findings.md` post-hoc. |

---

## Summary

v0.3 adds one event (`question`), one state value (`FS=question`/`VS=question`),
one helper-flag (`--keep-findings`), one classifier (regex over topic text),
two skill-hint files, and one intervention pattern. Existing scripts gain a
short read-question/escalate/answer/re-arm loop in their wait phase. The
trooper protocol is a thin Q&A round-trip over existing IPC.

Skill routing is symmetric (same skill for both troopers), classifier-driven,
and overridable via `_consult/skill.txt` edit. The autonomy contract keeps
question volume low while preserving the escape hatch for genuinely
user-relevant forks. Question serialization across two troopers falls out
of the directive's single-threaded shell flow.
