# /clone-wars:consult v0.3 — Trooper Question Protocol + Skill Routing

**Status:** Design — initial draft, 2026-04-29
**Date:** 2026-04-29
**Target version:** v0.3.0
**Builds on:** v0.2.1 (split orchestrator + Jedi general pool)
**Spec it extends:** `docs/superpowers/specs/2026-04-29-clone-wars-consult-v2-design.md`

---

## Goal

Let troopers ask questions back to the Jedi general during the research and
verify phases, so that `superpowers:brainstorming` and `superpowers:debugging`
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
awaited event set:

- v0.2: `cw_outbox_wait_since … done error <timeout>`
- v0.3: `cw_outbox_wait_since … done error question <timeout>`

After waiting, the script reads the matched event (or absence) and writes
the appropriate `FS=` (research) or `VS=` (verify) value to the per-commander
state file:

| matched event | FS / VS value |
|---|---|
| `done` | `ok` (existing) — set after parsing findings.md / verify.md |
| `error` | `failed` (existing) |
| `question` | `question` (new) — also writes `_consult/question-<commander>.txt` with the question payload |
| timeout (no event) | `timeout` (existing) |
| no findings.md / verify.md after `done` | `empty` / `missing` (existing) |

The wait-script captures the **byte offset of the matched line** so that
later re-arms (after the question is answered) read from the right cursor.
The state file gains a second `OFFSET=` line (newest wins) when re-armed.

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

| Skill value | Triggers |
|---|---|
| `brainstorming` | topic contains "design", "approach", "how should", "what's the best way", "structure", "decide between" |
| `debugging` | topic contains "why", "broken", "failing", "regression", "edge case", "bug", "doesn't work" |
| `none` | default — narrow review/audit topics |

Triggers are checked case-insensitively against word boundaries. First match
wins (`brainstorming` checked before `debugging`). When neither matches,
`none` is written.

The classifier is intentionally simple regex matching — not LLM-based. The
choice is logged but is overridable: a user can edit `_consult/skill.txt`
before Step 2 if they disagree with the auto-pick. This is documented in
the directive but not common-path.

---

## Skill hint in inbox prompts

`bin/consult-research-send.sh` and `bin/consult-verify-send.sh` append a
skill-hint block to the inbox prompt they generate. The block is read from
`config/skill-hints/<skill>.md` (a new directory). Three files ship:

- `config/skill-hints/brainstorming.md` — invokes `superpowers:brainstorming`,
  includes the autonomy contract.
- `config/skill-hints/debugging.md` — invokes `superpowers:debugging`,
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
         CRITICAL = directive_classify(Q.TEXT, $CONSULT_TOPIC, findings-so-far)
         if CRITICAL:
            ANS = AskUserQuestion(Q.TEXT, Q.OPTIONS)
         else:
            ANS = directive_answer(Q.TEXT, $CONSULT_TOPIC)
         cw_send $COMMANDER "ANSWER: $ANS\n\n…\nEND_OF_INSTRUCTION"
         consult-offset-reset.sh $TOPIC $COMMANDER research --keep-findings
         (re-arm: trooper resumes, will eventually emit done|question|error)
         # do NOT mark done; loop iterates
      *)  unknown FS — log + treat as failed ;;
    esac
done
```

The `consult-offset-reset.sh --keep-findings` flag is new (see below). It
advances the offset past the just-handled question event so the next
wait-iteration does not see the same question again, but does NOT delete
findings.md (which the trooper is still iteratively building).

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

Existing `bin/consult-offset-reset.sh <topic> <commander> <phase>` removes
the per-commander state file plus cascade artifacts. v0.3 adds a flag:

```
bin/consult-offset-reset.sh <topic> <commander> <phase> --keep-findings
```

When `--keep-findings`:

- Does NOT remove `findings.md` (research) or `verify.md` (verify).
- Does NOT remove the cascade artifacts (`diff.md`, `*_only_items.txt`,
  `adjudicated-draft.md`).
- Re-reads the trooper's outbox.jsonl, advances `OFFSET=` past the matched
  question line, rewrites `research-<commander>.txt` (or
  `verify-<commander>.txt`) with the new offset and `FS=`/`VS=` cleared.

Without `--keep-findings`, behaviour is unchanged from v0.2 (full cascade
removal — used for malformed-findings and all-UNCERTAIN intervention
patterns).

---

## Intervention Pattern 4: Critical-question relay

Added to `commands/consult.md` next to existing Patterns 1 and 3:

```
### Pattern 4: Critical-question relay

When a wait-script reports FS=question (research) or VS=question (verify):

1. Read _consult/question-<commander>.txt for TEXT and OPTIONS.
2. Classify:
   - critical → AskUserQuestion(TEXT, OPTIONS)
   - non-critical → answer from topic context yourself
3. Send the answer:
   /clone-wars:send <commander> "$CONSULT_TOPIC" "ANSWER: <answer>
      …
      END_OF_INSTRUCTION"
4. Reset the offset past the question:
   $CLAUDE_PLUGIN_ROOT/bin/consult-offset-reset.sh "$CONSULT_TOPIC" \
      <commander> <phase> --keep-findings
5. Re-run the matching wait-script:
   $CLAUDE_PLUGIN_ROOT/bin/consult-research-wait.sh "$CONSULT_TOPIC" \
      <commander> <model>
6. Loop until the trooper reports FS=ok / VS=ok.

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
  debugging.md               ← skill-pick + autonomy contract for bug-hunt topics
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

Five new test files plus extensions to existing ones:

1. `tests/test_consult_classify_topic.sh` — covers the classifier's regex
   matches across brainstorming/debugging/none, including edge cases
   (substring without word boundary should not trigger; case-insensitivity
   verified; "design pattern" triggers brainstorming, "designed by" does
   not).
2. `tests/test_consult_skill_hint.sh` — covers send-script appending the
   right hint file to the prompt; covers `skill=none` (no append) and
   missing `skill.txt` (default to `none`).
3. `tests/test_consult_question_event.sh` — covers a wait-script that
   sees a `question` outbox event: writes `question-<commander>.txt`
   with correct TEXT/OPTIONS/ASKED_AT/PHASE; sets `FS=question`.
4. `tests/test_consult_offset_reset_keep.sh` — covers the new
   `--keep-findings` flag: does NOT delete findings.md / verify.md /
   cascade artifacts; advances offset past the matched line; existing
   v0.2 behaviour still works without the flag.
5. `tests/test_consult_question_loop.sh` — fixture-level test of one
   trooper-question round-trip: simulate trooper emitting `question`,
   wait-script catching it, directive's answer being received, trooper
   resuming and emitting `done`. Uses a mock-pane (no real codex).

Extensions to existing tests:

- `test_consult_init.sh` — adds assertion that `skill.txt` is created with
  one of the three values, plus content checks against trigger phrases.
- `test_consult_research_wait.sh` — adds case that `question` event is
  caught alongside existing `done`/`error`/`timeout` cases.
- `test_consult_verify_wait.sh` — same.

---

## Open issues

None at draft time. The autonomy contract phrasing in the skill hints will
likely need a tightening pass after the first dogfood run; that is a copy
edit, not a design change.

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
