# /clone-wars:consult Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `/clone-wars:consult <topic>` — the first orchestration command on top of the spawn/send/collect/teardown primitives. Conductor spawns rex+codex and cody+claude, both research independently, conductor diffs and dispatches cross-verify back through the same panes, then adjudicates and synthesizes a four-section report.

**Architecture:** Pure bash + tmux + file IPC, matching the existing `bin/*.sh` + `lib/*.sh` + `commands/*.md` pattern. Two-call lifecycle per trooper (research + verify) reusing the same pane. New `lib/consult.sh` carries diff/verify-prompt/parse/synthesis helpers. New `bin/consult.sh` orchestrates Phases 1–7. Slash directive at `commands/consult.md` delegates via `--args-file` envelope.

**Tech Stack:** bash 4.2+, tmux 3.0+, awk/sed/grep, pure-bash test harness (`tests/run.sh`), file-based IPC (inbox.md / outbox.jsonl / findings.md / verify.md).

**Spec:** `docs/superpowers/specs/2026-04-28-clone-wars-consult-design.md`

---

## File structure

| File | Responsibility | Action |
|---|---|---|
| `lib/ipc.sh` | Add `cw_outbox_wait_since` and `cw_outbox_wait_all` cursor-aware helpers | Modify |
| `lib/consult.sh` | All consult-specific logic: paths, parsers, diff, verify-prompt builder, synthesizer | Create |
| `lib/contracts.sh` | Add `cw_consult_timeout` reader for the `consult:` block | Modify |
| `config/contracts.yaml` | Add `consult:` block with research + verify timeouts | Modify |
| `config/identity-template.md` | Add one sentence: write findings to inbox-specified path | Modify |
| `bin/consult.sh` | Orchestrator: validate → spawn → research → diff → verify → adjudicate → synthesize → teardown | Create |
| `commands/consult.md` | Slash directive (markdown) | Create |
| `tests/test_outbox_cursor.sh` | Cover `cw_outbox_wait_since` + `cw_outbox_wait_all` | Create |
| `tests/test_consult_findings_parse.sh` | Parser unit tests | Create |
| `tests/test_consult_diff.sh` | Diff-bucketing unit tests | Create |
| `tests/test_consult_verify_prompt.sh` | Verify-prompt builder unit tests | Create |
| `tests/test_consult_synthesis.sh` | Synthesis assembler unit tests | Create |
| `tests/test_send_at_file.sh` | Regression test for `@file` arg in send.sh | Create |
| `tests/test_identity_template.sh` | Add assertion for findings-path language | Modify |
| `README.md` | Add `/clone-wars:consult` section | Modify |
| `.claude-plugin/plugin.json` | Bump version to 0.1.0 | Modify |
| `.claude-plugin/marketplace.json` | Bump version to 0.1.0 | Modify |

Total: 4 modified libs + 1 new lib + 1 new bin + 1 new command + 6 new tests + 1 modified test + 3 doc/manifest touches = **17 file changes** across **17 tasks** (one task per file change is too coarse — see decomposition below).

---

## Task decomposition (16 tasks)

Tasks are ordered so the test suite stays green at every commit (bisect-safe). Prereq tasks 1–6 ship first; orchestrator tasks 7–13 build on them; docs + version bump 14–16 close the release.

---

### Task 1: `cw_outbox_wait_since` — cursor-aware outbox wait

**Why:** The conductor sends two tasks per pane (research + verify). The existing `cw_outbox_wait` matches anywhere in the file, so the second wait would re-trigger on the first task's `done`. We need to wait for the next `done` after a known byte offset.

**Files:**
- Test: `tests/test_outbox_cursor.sh` (new)
- Modify: `lib/ipc.sh` (append new function after `cw_outbox_wait`)

- [ ] **Step 1: Write the failing test**

Create `tests/test_outbox_cursor.sh`:

```bash
#!/usr/bin/env bash
# tests/test_outbox_cursor.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/state.sh
source ../lib/ipc.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"
cd /tmp  # ensure repo_hash is stable

cw_state_init alpha codex demo
OUTBOX=$(cw_outbox_path alpha codex demo)

# 1. cursor=0, first done event matched.
echo '{"event":"done","ts":"t1","summary":"first"}' >> "$OUTBOX"
got=$(cw_outbox_wait_since alpha codex demo 0 done 5)
assert_eq "$(echo "$got" | grep -o '"summary":"first"')" '"summary":"first"' "first done matched at offset 0"
pass "cw_outbox_wait_since matches at offset 0"

# 2. cursor past first done; wait returns the next one.
OFFSET=$(stat -c '%s' "$OUTBOX")
echo '{"event":"done","ts":"t2","summary":"second"}' >> "$OUTBOX"
got=$(cw_outbox_wait_since alpha codex demo "$OFFSET" done 5)
assert_eq "$(echo "$got" | grep -o '"summary":"second"')" '"summary":"second"' "second done matched after offset"
pass "cw_outbox_wait_since skips events before offset"

# 3. cursor past everything; wait times out with rc=1.
OFFSET=$(stat -c '%s' "$OUTBOX")
out=$(cw_outbox_wait_since alpha codex demo "$OFFSET" done 1) && rc=0 || rc=$?
assert_eq "$out" "" "no event past end-of-file"
[[ "$rc" -eq 1 ]] || { echo "FAIL: expected rc=1 on timeout, got $rc" >&2; exit 1; }
pass "cw_outbox_wait_since rc=1 on timeout"

# 4. multi-event accepted between offset and timeout (mirrors cw_outbox_wait varargs).
OFFSET=$(stat -c '%s' "$OUTBOX")
echo '{"event":"error","ts":"t3","message":"boom"}' >> "$OUTBOX"
got=$(cw_outbox_wait_since alpha codex demo "$OFFSET" done error 5)
assert_eq "$(echo "$got" | grep -o '"event":"error"')" '"event":"error"' "error matched in multi-event call"
pass "cw_outbox_wait_since accepts multi-event varargs"
```

- [ ] **Step 2: Run the test, expect failure**

```bash
bash tests/run.sh test_outbox_cursor.sh
```

Expected: FAIL with "cw_outbox_wait_since: command not found".

- [ ] **Step 3: Add `cw_outbox_wait_since` to `lib/ipc.sh`**

Insert AFTER the `cw_outbox_wait` function (right before `cw_outbox_dump`):

```bash
# cw_outbox_wait_since <commander> <model> <topic> <byte-offset> <event1> [<event2> ...] <timeout>
# Like cw_outbox_wait, but only considers content AFTER <byte-offset>. Use this
# when a trooper takes multiple sequential tasks: capture the outbox size before
# nudging, then wait for the NEXT matching event past that offset.
#
#   OFFSET=$(stat -c '%s' "$(cw_outbox_path c m t)")
#   cw_send ... ; cw_outbox_wait_since c m t "$OFFSET" done error 600
#
# Returns the matching JSON line; rc=0 on match, rc=1 on timeout, rc=2 on bad args.
cw_outbox_wait_since() {
  local commander="$1" model="$2" topic="$3" offset="$4"
  shift 4
  (( $# >= 2 )) || { echo "cw_outbox_wait_since: need at least one event and a timeout" >&2; return 2; }
  local timeout="${!#}"
  set -- "${@:1:$#-1}"
  local events=("$@")
  [[ "$offset"  =~ ^[0-9]+$ ]] || { echo "cw_outbox_wait_since: offset must be a non-negative integer; got '$offset'" >&2; return 2; }
  [[ "$timeout" =~ ^[0-9]+$ ]] || { echo "cw_outbox_wait_since: timeout must be a non-negative integer; got '$timeout'" >&2; return 2; }
  local outbox; outbox=$(cw_outbox_path "$commander" "$model" "$topic")
  local i event pat tail_size tail_content
  for ((i = 0; i < timeout; i++)); do
    if [[ -f "$outbox" ]]; then
      tail_size=$(stat -c '%s' "$outbox")
      if (( tail_size > offset )); then
        # Read everything after the offset; line-based scan with anchored regex.
        tail_content=$(tail -c "+$((offset + 1))" "$outbox")
        for event in "${events[@]}"; do
          pat=$(cw_event_match_pattern "$event")
          if printf '%s\n' "$tail_content" | grep -qE "$pat"; then
            printf '%s\n' "$tail_content" | grep -E "$pat" | tail -n1
            return 0
          fi
        done
      fi
    fi
    sleep 1
  done
  return 1
}
```

- [ ] **Step 4: Run the test, expect pass**

```bash
bash tests/run.sh test_outbox_cursor.sh
```

Expected: PASS for all four assertions.

- [ ] **Step 5: Run the full suite to confirm no regressions**

```bash
bash tests/run.sh
```

Expected: every test passes (16 existing + 1 new).

- [ ] **Step 6: Commit**

```bash
git add lib/ipc.sh tests/test_outbox_cursor.sh
git commit -m "feat(ipc): cw_outbox_wait_since cursor-aware outbox wait

Multi-task troopers (consult Phase 4 verify after Phase 2 research) need
the conductor to wait for the NEXT done event past a known offset, not
re-trigger on the previous task's done. Captures the outbox byte-size
before the inbox nudge, scans only the suffix.

Mirrors cw_outbox_wait's varargs + anchored event matcher."
```

---

### Task 2: `cw_outbox_wait_all` — block until N troopers all emit done

**Why:** The conductor needs to wait for both troopers to finish Phase 2 before bucketing claims, and both to finish Phase 4 before adjudication. A single helper that loops over `cw_outbox_wait_since` keeps the orchestrator readable.

**Files:**
- Test: `tests/test_outbox_cursor.sh` (extend, don't replace)
- Modify: `lib/ipc.sh` (append after `cw_outbox_wait_since`)

- [ ] **Step 1: Append failing test**

Append to `tests/test_outbox_cursor.sh`:

```bash
# 5. wait_all matches one trooper, then the second.
cw_state_init bravo codex demo2
B_OUTBOX=$(cw_outbox_path bravo codex demo2)

# Both troopers will emit done concurrently; build the inputs file once.
cat > "$TMP/troopers.txt" <<EOF
alpha:codex:demo:0
bravo:codex:demo2:0
EOF

# Pre-populate alpha's done; bravo emits during the wait via background.
echo '{"event":"done","ts":"t10","summary":"alpha-done"}' >> "$OUTBOX"
( sleep 1; echo '{"event":"done","ts":"t11","summary":"bravo-done"}' >> "$B_OUTBOX" ) &

cw_outbox_wait_all "$TMP/troopers.txt" done 10
rc=$?
[[ "$rc" -eq 0 ]] || { echo "FAIL: wait_all rc=$rc, expected 0" >&2; exit 1; }
pass "cw_outbox_wait_all matches all listed troopers within timeout"

# 6. wait_all returns rc=1 if any trooper times out.
cw_state_init charlie codex demo3
cat > "$TMP/troopers2.txt" <<EOF
alpha:codex:demo:$(stat -c '%s' "$OUTBOX")
charlie:codex:demo3:0
EOF
out=$(cw_outbox_wait_all "$TMP/troopers2.txt" done 1) && rc=0 || rc=$?
[[ "$rc" -eq 1 ]] || { echo "FAIL: wait_all rc=$rc, expected 1 on partial timeout" >&2; exit 1; }
pass "cw_outbox_wait_all rc=1 if any trooper times out"
```

- [ ] **Step 2: Run, expect failure**

```bash
bash tests/run.sh test_outbox_cursor.sh
```

Expected: FAIL with "cw_outbox_wait_all: command not found".

- [ ] **Step 3: Implement `cw_outbox_wait_all`**

Append to `lib/ipc.sh` after `cw_outbox_wait_since`:

```bash
# cw_outbox_wait_all <troopers-file> <event1> [<event2> ...] <timeout>
# Block until every trooper listed in <troopers-file> emits one of the named
# events past its captured offset. Returns 0 if all matched within the global
# timeout; 1 if any trooper timed out; 2 on bad args.
#
# <troopers-file> format: one trooper per line, colon-delimited:
#   <commander>:<model>:<topic>:<byte-offset>
#
# Each line's offset is the size the outbox had at the moment the conductor
# nudged that trooper — captured BEFORE the send so any new event past the
# offset belongs to the dispatched task.
cw_outbox_wait_all() {
  local file="$1"
  shift 1
  (( $# >= 2 )) || { echo "cw_outbox_wait_all: need at least one event and a timeout" >&2; return 2; }
  local timeout="${!#}"
  set -- "${@:1:$#-1}"
  local events=("$@")
  [[ -f "$file" ]]              || { echo "cw_outbox_wait_all: file not found: $file" >&2; return 2; }
  [[ "$timeout" =~ ^[0-9]+$ ]]  || { echo "cw_outbox_wait_all: timeout must be a non-negative integer" >&2; return 2; }

  # Collect lines into an array (skip blanks).
  mapfile -t lines < <(grep -v '^[[:space:]]*$' "$file")
  (( ${#lines[@]} > 0 )) || { echo "cw_outbox_wait_all: empty troopers file" >&2; return 2; }

  local deadline=$(( $(date +%s) + timeout ))
  local line commander model topic offset remaining
  for line in "${lines[@]}"; do
    IFS=':' read -r commander model topic offset <<< "$line"
    [[ -n "$commander" && -n "$model" && -n "$topic" && -n "$offset" ]] || {
      echo "cw_outbox_wait_all: malformed line: $line" >&2; return 2; }
    remaining=$(( deadline - $(date +%s) ))
    (( remaining > 0 )) || return 1
    cw_outbox_wait_since "$commander" "$model" "$topic" "$offset" "${events[@]}" "$remaining" >/dev/null || return 1
  done
  return 0
}
```

- [ ] **Step 4: Run, expect pass**

```bash
bash tests/run.sh test_outbox_cursor.sh
```

Expected: PASS for assertions 5 and 6 (plus 1–4 from Task 1).

- [ ] **Step 5: Full suite**

```bash
bash tests/run.sh
```

Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add lib/ipc.sh tests/test_outbox_cursor.sh
git commit -m "feat(ipc): cw_outbox_wait_all blocks until N troopers all done

Conductor needs to wait for both consult troopers' research events
(Phase 2) and both verify events (Phase 4) before proceeding. Reads a
colon-delimited troopers file (commander:model:topic:offset per line)
and loops over cw_outbox_wait_since, sharing one global deadline."
```

---

### Task 3: Identity template — write findings to inbox-specified path

**Why:** The Phase 2 / Phase 4 inbox prompts will instruct the trooper to write its output to a specific path (`<state-dir>/findings.md` or `verify.md`). The identity template should reinforce: "follow the inbox-specified output path; emit done only after the file exists."

**Files:**
- Modify: `config/identity-template.md` (one new line)
- Modify: `tests/test_identity_template.sh` (one new assertion)

- [ ] **Step 1: Add failing assertion**

Append to `tests/test_identity_template.sh` (before any final exit):

```bash
# Multi-task discipline: when the inbox specifies an output path, the trooper
# must write to it BEFORE emitting done. Without this language, troopers fold
# their findings into the done event's summary field (truncated, hard to parse).
grep -q 'inbox.*specifies.*output path' "$IDENTITY" \
  || { echo "FAIL: identity missing inbox-specified output-path discipline" >&2; exit 1; }
pass "identity tells trooper to write output to inbox-specified path"
```

(`$IDENTITY` is the path to the rendered identity.md set up earlier in the test — verify by reading the file first.)

- [ ] **Step 2: Run, expect failure**

```bash
bash tests/run.sh test_identity_template.sh
```

Expected: FAIL on the new assertion.

- [ ] **Step 3: Update `config/identity-template.md`**

Insert after line 20 (the existing "Stay in your pane" paragraph):

```markdown
When the inbox specifies an output path (e.g., "write your findings to
`<state-dir>/findings.md`"), write to that path BEFORE emitting `done`. The
`done` event's `summary` field is for a one-line headline; the full output
goes in the file you wrote.
```

- [ ] **Step 4: Run the identity test, expect pass**

```bash
bash tests/run.sh test_identity_template.sh
```

Expected: PASS.

- [ ] **Step 5: Full suite — including the live triple-trooper smoke if available**

```bash
bash tests/run.sh
```

The identity-template change is observed in test_identity_template only. Existing tracer-bullet smoke remains valid because the new sentence describes opt-in behavior (inbox-specified path) — old single-task troopers without that instruction continue to work.

- [ ] **Step 6: Commit**

```bash
git add config/identity-template.md tests/test_identity_template.sh
git commit -m "feat(identity): instruct troopers to write output to inbox-specified path

Consult Phase 2/4 prompts ask each trooper to write findings.md /
verify.md into its state dir before emitting done. The identity prompt
reinforces this so troopers don't fold the full output into the
truncated done.summary field."
```

---

### Task 4: `consult:` block in contracts.yaml + `cw_consult_timeout` reader

**Why:** Two timeouts — research (10 min default) and verify (5 min default) — drive the conductor's outbox waits. Storing them in `contracts.yaml` keeps user override simple (edit one file).

**Files:**
- Modify: `config/contracts.yaml` (append `consult:` block)
- Modify: `lib/contracts.sh` (add `cw_consult_timeout` reader)
- Test: `tests/test_contracts.sh` (extend with consult-block assertions)

- [ ] **Step 1: Add failing test**

Append to `tests/test_contracts.sh` (before final blank line):

```bash
# === consult: block ===

cat > "$TMP_C/contracts.yaml" <<YAML
codex:
  binary: codex
  modes:
    full: [--bypass]
  default_mode: full
  ready_timeout_s: 30
  bootstrap_sleep_s: 8

consult:
  research_timeout_s: 600
  verify_timeout_s: 300
YAML
got=$(CLONE_WARS_HOME="$TMP_C" cw_consult_timeout research)
assert_eq "$got" "600" "consult research_timeout_s reads back"
got=$(CLONE_WARS_HOME="$TMP_C" cw_consult_timeout verify)
assert_eq "$got" "300" "consult verify_timeout_s reads back"
pass "consult timeouts read back from contracts.yaml"

# Default fallback when block missing.
cat > "$TMP_C/contracts.yaml" <<YAML
codex:
  binary: codex
  modes: { full: [--bypass] }
  default_mode: full
  ready_timeout_s: 30
YAML
got=$(CLONE_WARS_HOME="$TMP_C" cw_consult_timeout research)
assert_eq "$got" "600" "research default = 600 when consult: block missing"
got=$(CLONE_WARS_HOME="$TMP_C" cw_consult_timeout verify)
assert_eq "$got" "300" "verify default = 300 when consult: block missing"
pass "consult timeout defaults applied when block missing"
```

- [ ] **Step 2: Run, expect failure**

```bash
bash tests/run.sh test_contracts.sh
```

Expected: FAIL with "cw_consult_timeout: command not found".

- [ ] **Step 3: Add `cw_consult_timeout` to `lib/contracts.sh`**

Append:

```bash
# cw_consult_timeout <kind>
# Print the configured consult timeout in seconds for <kind> ∈ {research, verify}.
# Reads the consult: block in contracts.yaml; falls back to defaults
# (research=600, verify=300) when the block or field is absent.
cw_consult_timeout() {
  local kind="$1" key default
  case "$kind" in
    research) key=research_timeout_s; default=600 ;;
    verify)   key=verify_timeout_s;   default=300 ;;
    *) echo "cw_consult_timeout: kind must be 'research' or 'verify'; got '$kind'" >&2; return 2 ;;
  esac
  local path; path=$(cw_contracts_path)
  [[ -f "$path" ]] || { printf '%s\n' "$default"; return 0; }
  local v
  v=$(awk -v key="$key" '
    /^consult:/         { in_consult = 1; next }
    /^[a-z]/            { in_consult = 0 }
    in_consult && $1 == key":" { print $2; exit }
  ' "$path")
  [[ -n "$v" && "$v" =~ ^[0-9]+$ ]] || v="$default"
  printf '%s\n' "$v"
}
```

- [ ] **Step 4: Append `consult:` block to `config/contracts.yaml`**

Append at end of file:

```yaml

consult:
  research_timeout_s: 600   # 10 min — generous for a full research turn
  verify_timeout_s:   300   # 5 min — narrower task (grade N items)
```

- [ ] **Step 5: Run, expect pass**

```bash
bash tests/run.sh test_contracts.sh
```

Expected: PASS for new assertions.

- [ ] **Step 6: Full suite**

```bash
bash tests/run.sh
```

Expected: all green.

- [ ] **Step 7: Commit**

```bash
git add lib/contracts.sh config/contracts.yaml tests/test_contracts.sh
git commit -m "feat(contracts): consult: block with research/verify timeouts

cw_consult_timeout reads contracts.yaml's consult: block; falls back to
research=600s, verify=300s when missing. Drives bin/consult.sh's
outbox waits in Phase 2 and Phase 4."
```

---

### Task 5: `lib/consult.sh` — paths + findings parser

**Why:** Both findings.md and verify.md need a single canonical path helper, and the conductor's diff logic needs a parser that extracts numbered claims with their citations from a well-formed findings.md.

**Files:**
- Create: `lib/consult.sh`
- Test: `tests/test_consult_findings_parse.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test_consult_findings_parse.sh`:

```bash
#!/usr/bin/env bash
# tests/test_consult_findings_parse.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/state.sh
source ../lib/ipc.sh
source ../lib/consult.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

# Path helpers
cw_state_init alpha codex demo
DIR=$(cw_trooper_dir alpha codex demo)
assert_eq "$(cw_consult_findings_path alpha codex demo)" "$DIR/findings.md" "findings path shape"
assert_eq "$(cw_consult_verify_path   alpha codex demo)" "$DIR/verify.md"   "verify path shape"
pass "consult path helpers"

# Parse a well-formed findings.md
cat > "$DIR/findings.md" <<'MD'
# Findings: review auth code

## Summary
Token storage is plaintext; refresh has no retry.

## Claims
1. [src/auth/store.py:42] Tokens are stored in plaintext.
2. [src/auth/refresh.py:15-30] No retry logic on refresh.
3. [https://datatracker.ietf.org/doc/html/rfc6749#section-10.4] OAuth2 RFC requires retry policy.

## Notes
free-form addendum, ignored by parser
MD

mapfile -t CLAIMS < <(cw_consult_parse_claims "$DIR/findings.md")
[[ "${#CLAIMS[@]}" -eq 3 ]] || { echo "FAIL: expected 3 claims, got ${#CLAIMS[@]}" >&2; exit 1; }

# Each line is "<citation>\t<text>"
assert_eq "${CLAIMS[0]%%$'\t'*}" "src/auth/store.py:42" "claim 1 citation"
assert_eq "${CLAIMS[0]##*$'\t'}" "Tokens are stored in plaintext." "claim 1 text"
assert_eq "${CLAIMS[2]%%$'\t'*}" "https://datatracker.ietf.org/doc/html/rfc6749#section-10.4" "URL citation preserved"
pass "well-formed findings parsed into 3 claims"

# Empty claims block → 0 claims, no error.
cat > "$DIR/findings.md" <<'MD'
# Findings: x
## Summary
nothing found
## Claims
## Notes
MD

mapfile -t CLAIMS < <(cw_consult_parse_claims "$DIR/findings.md")
[[ "${#CLAIMS[@]}" -eq 0 ]] || { echo "FAIL: expected 0 claims, got ${#CLAIMS[@]}" >&2; exit 1; }
pass "empty claims block parses to 0 claims"

# Malformed claims (no citation) — skipped, not crashed.
cat > "$DIR/findings.md" <<'MD'
# Findings: x
## Summary
mixed bag
## Claims
1. Claim with no citation, just prose.
2. [src/x.py:1] Real claim.
3. another bare claim
## Notes
MD

mapfile -t CLAIMS < <(cw_consult_parse_claims "$DIR/findings.md")
[[ "${#CLAIMS[@]}" -eq 1 ]] || { echo "FAIL: expected 1 valid claim, got ${#CLAIMS[@]}" >&2; exit 1; }
assert_eq "${CLAIMS[0]%%$'\t'*}" "src/x.py:1" "only the citation-bearing claim survived"
pass "malformed claims silently skipped"
```

- [ ] **Step 2: Run, expect failure**

```bash
bash tests/run.sh test_consult_findings_parse.sh
```

Expected: FAIL with `lib/consult.sh: No such file or directory`.

- [ ] **Step 3: Create `lib/consult.sh`**

```bash
# lib/consult.sh — /clone-wars:consult orchestration helpers.
# Sourced. Depends on lib/state.sh, lib/ipc.sh, lib/contracts.sh.
#
# Provides:
#   cw_consult_findings_path / cw_consult_verify_path  — file path helpers
#   cw_consult_parse_claims / cw_consult_parse_verdicts — markdown parsers
#   cw_consult_diff                                     — bucket claims into AGREE/REX_ONLY/CODY_ONLY
#   cw_consult_build_research_prompt / cw_consult_build_verify_prompt — prompt builders
#   cw_consult_synthesize                               — assemble the final report

# --- Path helpers --------------------------------------------------------

cw_consult_findings_path() {
  printf '%s/findings.md\n' "$(cw_trooper_dir "$1" "$2" "$3")"
}

cw_consult_verify_path() {
  printf '%s/verify.md\n' "$(cw_trooper_dir "$1" "$2" "$3")"
}

# --- Parsers -------------------------------------------------------------

# cw_consult_parse_claims <findings.md path>
# Print one TAB-delimited line per claim: "<citation>\t<text>".
# A claim line in the source is:    `N. [<citation>] <text>`
# Lines without the [<citation>] prefix are silently skipped.
cw_consult_parse_claims() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  awk '
    /^## Claims/      { in_claims = 1; next }
    /^## /            { in_claims = 0 }
    in_claims && /^[0-9]+\. \[[^]]+\] / {
      # Extract everything between the first [ and ] as citation.
      match($0, /\[[^]]+\]/)
      cite = substr($0, RSTART + 1, RLENGTH - 2)
      # Text is everything after the closing ] and one space.
      text = substr($0, RSTART + RLENGTH + 1)
      sub(/^[ \t]+/, "", text)
      printf "%s\t%s\n", cite, text
    }
  ' "$file"
}
```

- [ ] **Step 4: Run, expect pass**

```bash
bash tests/run.sh test_consult_findings_parse.sh
```

Expected: PASS for all assertions.

- [ ] **Step 5: Full suite**

```bash
bash tests/run.sh
```

Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add lib/consult.sh tests/test_consult_findings_parse.sh
git commit -m "feat(consult): paths + claims parser for findings.md

lib/consult.sh houses all consult-specific helpers (will grow with
diff, prompt builders, synthesizer in subsequent tasks).

cw_consult_parse_claims extracts numbered claims with [citation]
prefixes; skips malformed lines silently so a partially-formatted
findings.md degrades to fewer claims rather than crashing."
```

---

### Task 6: `cw_consult_diff` — bucket claims into AGREE / REX_ONLY / CODY_ONLY

**Why:** Phase 3 of the orchestrator needs to compare two findings files and emit three lists. Pure-bash matching: a claim from REX matches a claim from CODY iff their citations are identical (string equality after trimming).

**Files:**
- Modify: `lib/consult.sh` (append `cw_consult_diff`)
- Test: `tests/test_consult_diff.sh` (new)

- [ ] **Step 1: Failing test**

Create `tests/test_consult_diff.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/state.sh
source ../lib/ipc.sh
source ../lib/consult.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Build two findings files with overlap + disjoint citations.
REX="$TMP/rex.md"; CODY="$TMP/cody.md"

cat > "$REX" <<'MD'
# Findings: x
## Summary
.
## Claims
1. [src/auth/store.py:42] Plaintext storage.
2. [src/auth/refresh.py:15-30] No retry logic.
3. [src/util/log.py:7] Logger leaks tokens.
## Notes
MD

cat > "$CODY" <<'MD'
# Findings: x
## Summary
.
## Claims
1. [src/auth/store.py:42] Tokens not encrypted.
2. [src/oauth/callback.py:88] State param unvalidated.
## Notes
MD

OUT="$TMP/diff.md"
cw_consult_diff "$REX" "$CODY" "$OUT"

# Three sections in fixed order.
grep -q '^## Agreed'    "$OUT" || { echo "FAIL: missing ## Agreed"    >&2; exit 1; }
grep -q '^## Rex-only'  "$OUT" || { echo "FAIL: missing ## Rex-only"  >&2; exit 1; }
grep -q '^## Cody-only' "$OUT" || { echo "FAIL: missing ## Cody-only" >&2; exit 1; }
pass "diff emits three sections in fixed order"

# Agreed section contains the shared citation.
agreed=$(awk '/^## Agreed/{f=1;next} /^## /{f=0} f' "$OUT" | grep -c '\[src/auth/store.py:42\]')
[[ "$agreed" -eq 1 ]] || { echo "FAIL: expected 1 agreed line for store.py:42, got $agreed" >&2; exit 1; }
pass "shared citation lands in Agreed"

# Rex-only contains both rex-unique claims.
rex_only=$(awk '/^## Rex-only/{f=1;next} /^## /{f=0} f' "$OUT" | grep -c '^- \[src/')
[[ "$rex_only" -eq 2 ]] || { echo "FAIL: expected 2 rex-only entries, got $rex_only" >&2; exit 1; }
pass "Rex-only has 2 unique claims"

# Cody-only contains the cody-unique claim.
cody_only=$(awk '/^## Cody-only/{f=1;next} /^## /{f=0} f' "$OUT" | grep -c '^- \[src/oauth/')
[[ "$cody_only" -eq 1 ]] || { echo "FAIL: expected 1 cody-only entry, got $cody_only" >&2; exit 1; }
pass "Cody-only has the disjoint claim"

# Edge: empty findings file pair → all sections empty, no crash.
echo '# x' > "$TMP/empty1.md"
echo '# x' > "$TMP/empty2.md"
cw_consult_diff "$TMP/empty1.md" "$TMP/empty2.md" "$TMP/diff2.md"
grep -q '^## Agreed'    "$TMP/diff2.md"
grep -q '^## Rex-only'  "$TMP/diff2.md"
grep -q '^## Cody-only' "$TMP/diff2.md"
pass "empty inputs still emit all three section headers"
```

- [ ] **Step 2: Run, expect failure**

```bash
bash tests/run.sh test_consult_diff.sh
```

Expected: FAIL with `cw_consult_diff: command not found`.

- [ ] **Step 3: Implement `cw_consult_diff`**

Append to `lib/consult.sh`:

```bash
# cw_consult_diff <rex-findings> <cody-findings> <out-path>
# Bucket claims by citation match. Two claims agree iff their citations are
# byte-identical after trim. Output:
#   ## Agreed
#   - [<cite>] <rex-text> | <cody-text>
#   ## Rex-only
#   - [<cite>] <text>
#   ## Cody-only
#   - [<cite>] <text>
# All three section headers always present, even when empty (so downstream
# parsers don't have to handle missing sections).
cw_consult_diff() {
  local rex="$1" cody="$2" out="$3"
  local tmp_rex tmp_cody
  tmp_rex=$(mktemp); tmp_cody=$(mktemp)
  cw_consult_parse_claims "$rex"  > "$tmp_rex"
  cw_consult_parse_claims "$cody" > "$tmp_cody"

  {
    printf '## Agreed\n'
    # Citation in $1 of join's TSV; both texts kept side-by-side.
    sort -t$'\t' -k1,1 "$tmp_rex"  > "$tmp_rex.s"
    sort -t$'\t' -k1,1 "$tmp_cody" > "$tmp_cody.s"
    join -t$'\t' -1 1 -2 1 -o '0,1.2,2.2' "$tmp_rex.s" "$tmp_cody.s" 2>/dev/null \
      | awk -F'\t' '{ printf "- [%s] %s | %s\n", $1, $2, $3 }'

    printf '\n## Rex-only\n'
    join -t$'\t' -1 1 -2 1 -v 1 "$tmp_rex.s" "$tmp_cody.s" 2>/dev/null \
      | awk -F'\t' '{ printf "- [%s] %s\n", $1, $2 }'

    printf '\n## Cody-only\n'
    join -t$'\t' -1 1 -2 1 -v 2 "$tmp_rex.s" "$tmp_cody.s" 2>/dev/null \
      | awk -F'\t' '{ printf "- [%s] %s\n", $1, $2 }'
  } > "$out"

  rm -f "$tmp_rex" "$tmp_cody" "$tmp_rex.s" "$tmp_cody.s"
}
```

- [ ] **Step 4: Run, expect pass**

```bash
bash tests/run.sh test_consult_diff.sh
```

Expected: PASS for all assertions.

- [ ] **Step 5: Full suite**

```bash
bash tests/run.sh
```

- [ ] **Step 6: Commit**

```bash
git add lib/consult.sh tests/test_consult_diff.sh
git commit -m "feat(consult): cw_consult_diff buckets claims by citation match

Byte-identical citation match for AGREE; set difference for the two
*_ONLY buckets. All three section headers are always emitted so the
downstream synthesizer has a stable schema."
```

---

### Task 7: Verdict parser + verify-prompt builder

**Why:** Phase 4's verify-prompt asks the trooper to grade N items and write `verify.md` in a fixed format. The conductor parses that file in Phase 5 to drive adjudication. Both the prompt builder and the parser live in lib/consult.sh.

**Files:**
- Modify: `lib/consult.sh` (append two functions)
- Test: `tests/test_consult_verify_prompt.sh` (new)

- [ ] **Step 1: Failing test**

Create `tests/test_consult_verify_prompt.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/state.sh
source ../lib/ipc.sh
source ../lib/consult.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Builder: takes a list of "[<cite>] <text>" lines + a write-to path; emits the
# full inbox prompt ending with END_OF_INSTRUCTION.
ITEMS_FILE="$TMP/items.txt"
cat > "$ITEMS_FILE" <<'EOF'
[src/auth/refresh.py:15-30] No retry logic.
[src/oauth/callback.py:88] State param unvalidated.
EOF

PROMPT=$(cw_consult_build_verify_prompt "$ITEMS_FILE" "/state/verify.md")
echo "$PROMPT" | grep -q 'END_OF_INSTRUCTION$' \
  || { echo "FAIL: prompt missing END_OF_INSTRUCTION" >&2; exit 1; }
echo "$PROMPT" | grep -q 'AGREE / DISPUTE / UNCERTAIN' \
  || { echo "FAIL: prompt missing verdict tags" >&2; exit 1; }
echo "$PROMPT" | grep -q '/state/verify.md' \
  || { echo "FAIL: prompt missing output-path injection" >&2; exit 1; }
pass "verify prompt has sentinel, verdict tags, output path"

# Parser: given a well-formed verify.md, returns "<tag>\t<citation>\t<other-side text>"
VERIFY="$TMP/v.md"
cat > "$VERIFY" <<'MD'
# Verify

## Verdicts
1. AGREE [src/auth/refresh.py:15-30] No retry logic.
   src/auth/refresh.py:25 — try block has no except RetryError handler
2. DISPUTE [src/oauth/callback.py:88] State param unvalidated.
   src/oauth/callback.py:88 reads state from session; assert_eq line 91
3. UNCERTAIN [src/util/x.py:10] Some claim.
   no test reproduces this; cannot tell from static reading
MD

mapfile -t VERDICTS < <(cw_consult_parse_verdicts "$VERIFY")
[[ "${#VERDICTS[@]}" -eq 3 ]] || { echo "FAIL: expected 3 verdicts, got ${#VERDICTS[@]}" >&2; exit 1; }

IFS=$'\t' read -r tag cite text <<< "${VERDICTS[0]}"
assert_eq "$tag"  "AGREE" "verdict 1 tag"
assert_eq "$cite" "src/auth/refresh.py:15-30" "verdict 1 cite"
pass "verdict parser splits tag/cite/text correctly"

IFS=$'\t' read -r tag cite text <<< "${VERDICTS[1]}"
assert_eq "$tag" "DISPUTE" "verdict 2 tag"
IFS=$'\t' read -r tag cite text <<< "${VERDICTS[2]}"
assert_eq "$tag" "UNCERTAIN" "verdict 3 tag"
pass "all three verdict tags recognized"

# Malformed verdict line (no tag) → silently skipped.
cat > "$VERIFY" <<'MD'
# Verify
## Verdicts
1. UNKNOWN [src/x.py:1] Garbled.
2. AGREE [src/y.py:5] Real verdict.
MD
mapfile -t VERDICTS < <(cw_consult_parse_verdicts "$VERIFY")
[[ "${#VERDICTS[@]}" -eq 1 ]] || { echo "FAIL: expected 1 valid verdict, got ${#VERDICTS[@]}" >&2; exit 1; }
pass "unknown verdict tags filtered out"
```

- [ ] **Step 2: Run, expect failure**

```bash
bash tests/run.sh test_consult_verify_prompt.sh
```

Expected: FAIL with `cw_consult_build_verify_prompt: command not found`.

- [ ] **Step 3: Implement both functions**

Append to `lib/consult.sh`:

```bash
# cw_consult_build_verify_prompt <items-file> <write-to-path>
# Print the full inbox prompt that asks a trooper to verify each item with one
# of {AGREE, DISPUTE, UNCERTAIN} and write verdicts to <write-to-path>.
# Trailing END_OF_INSTRUCTION sentinel is required by cw_inbox_write convention.
cw_consult_build_verify_prompt() {
  local items_file="$1" write_to="$2"
  cat <<EOF
You researched a topic in your previous turn. Below are claims the OTHER researcher raised that you did not. For EACH item, do ONE of:

  AGREE     — confirm with your own evidence (cite a file/line/source)
  DISPUTE   — explain why it's wrong, with counter-evidence
  UNCERTAIN — you cannot tell from available evidence; say so

Items to verify:
$(cat "$items_file" | nl -ba -w1 -s'. ')

Write your verdicts to $write_to in this exact format:

  # Verify
  ## Verdicts
  1. <TAG> <original [citation] and text>
     <one-line evidence>
  2. ...

Then emit {"event":"done", "summary":"verified N items", "ts":"<iso>"} to your outbox.

END_OF_INSTRUCTION
EOF
}

# cw_consult_parse_verdicts <verify.md path>
# Print one TAB-delimited line per verdict: "<tag>\t<citation>\t<text>".
# Tag must be one of AGREE / DISPUTE / UNCERTAIN; lines with other tags
# (or no tag) are silently skipped.
cw_consult_parse_verdicts() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  awk '
    /^## Verdicts/                         { in_v = 1; next }
    /^## /                                 { in_v = 0 }
    in_v && /^[0-9]+\. (AGREE|DISPUTE|UNCERTAIN) \[[^]]+\] / {
      sub(/^[0-9]+\. /, "")            # drop "N. "
      tag = $1
      sub(/^[A-Z]+ /, "")              # drop tag and space
      match($0, /\[[^]]+\]/)
      cite = substr($0, RSTART + 1, RLENGTH - 2)
      text = substr($0, RSTART + RLENGTH + 1)
      sub(/^[ \t]+/, "", text)
      printf "%s\t%s\t%s\n", tag, cite, text
    }
  ' "$file"
}
```

- [ ] **Step 4: Run, expect pass**

```bash
bash tests/run.sh test_consult_verify_prompt.sh
```

- [ ] **Step 5: Full suite**

```bash
bash tests/run.sh
```

- [ ] **Step 6: Commit**

```bash
git add lib/consult.sh tests/test_consult_verify_prompt.sh
git commit -m "feat(consult): verify-prompt builder + verdict parser

Phase 4 dispatches a verify task to each trooper; the prompt template
asks for AGREE/DISPUTE/UNCERTAIN per item and a fixed verify.md
schema. Parser is strict: only the three known tags survive."
```

---

### Task 8: Research-prompt builder

**Why:** Phase 2 dispatches a research task with a topic + the explicit findings.md path the trooper should write to. One helper avoids duplication between the two trooper dispatches.

**Files:**
- Modify: `lib/consult.sh` (append `cw_consult_build_research_prompt`)
- Test: extend `tests/test_consult_verify_prompt.sh` (rename to `test_consult_prompts.sh`)

- [ ] **Step 1: Rename test file + add research-prompt assertion**

```bash
git mv tests/test_consult_verify_prompt.sh tests/test_consult_prompts.sh
```

Append to `tests/test_consult_prompts.sh`:

```bash
# Research prompt: takes topic + write-to path; emits prompt with topic, format
# instruction, write-to path, and the END_OF_INSTRUCTION sentinel.
PROMPT=$(cw_consult_build_research_prompt "review src/auth for token edge cases" "/state/findings.md")
echo "$PROMPT" | grep -q 'review src/auth for token edge cases' \
  || { echo "FAIL: research prompt missing topic" >&2; exit 1; }
echo "$PROMPT" | grep -q '/state/findings.md' \
  || { echo "FAIL: research prompt missing output path" >&2; exit 1; }
echo "$PROMPT" | grep -q '## Claims' \
  || { echo "FAIL: research prompt missing format anchor (## Claims)" >&2; exit 1; }
echo "$PROMPT" | grep -q 'END_OF_INSTRUCTION$' \
  || { echo "FAIL: research prompt missing sentinel" >&2; exit 1; }
pass "research prompt has topic, output path, format anchor, sentinel"
```

- [ ] **Step 2: Run, expect failure**

```bash
bash tests/run.sh test_consult_prompts.sh
```

Expected: FAIL on `cw_consult_build_research_prompt: command not found`.

- [ ] **Step 3: Implement**

Append to `lib/consult.sh`:

```bash
# cw_consult_build_research_prompt <topic> <write-to-path>
# Inbox prompt for Phase 2 research. Asks the trooper to investigate <topic>
# and write structured findings to <write-to-path> before emitting done.
cw_consult_build_research_prompt() {
  local topic="$1" write_to="$2"
  cat <<EOF
Investigate the following topic and produce structured findings.

Topic: $topic

Output requirements — write to $write_to with this EXACT structure:

  # Findings: $topic

  ## Summary
  <2-3 sentence overview, free-form prose>

  ## Claims
  1. [<source citation>] <one-sentence claim>
  2. [<source citation>] <one-sentence claim>
  ...

  ## Notes
  <any free-form additions; not parsed by conductor>

Citation format options:
  - <file path>:<line>          e.g. src/auth/store.py:42
  - <file path>:<line-range>    e.g. src/auth/refresh.py:15-30
  - <URL>                       e.g. https://datatracker.ietf.org/doc/html/rfc6749
  - runtime: <command>          e.g. runtime: pytest tests/test_auth.py

Each claim must have a citation in [brackets]. Claims without citations
will be silently dropped by the conductor.

Then emit {"event":"done", "summary":"researched $topic", "ts":"<iso>"} to your outbox.

END_OF_INSTRUCTION
EOF
}
```

- [ ] **Step 4: Run, expect pass**

```bash
bash tests/run.sh test_consult_prompts.sh
```

- [ ] **Step 5: Full suite**

```bash
bash tests/run.sh
```

- [ ] **Step 6: Commit**

```bash
git add lib/consult.sh tests/test_consult_prompts.sh
git commit -m "feat(consult): research-prompt builder

Phase 2 dispatch shares one prompt template across both troopers; the
template anchors output schema (## Claims) so cw_consult_parse_claims
in Phase 3 has a stable input to read."
```

---

### Task 9: Synthesis assembler

**Why:** Phase 6 reads the four trooper artifacts (rex/cody × findings/verify), the diff buckets, and conductor adjudication notes, and produces synthesis.md. This is the last library helper before the orchestrator wires everything together.

**Files:**
- Modify: `lib/consult.sh` (append `cw_consult_synthesize`)
- Test: `tests/test_consult_synthesis.sh` (new)

- [ ] **Step 1: Failing test**

Create `tests/test_consult_synthesis.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/state.sh
source ../lib/ipc.sh
source ../lib/consult.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Build inputs.
DIFF="$TMP/diff.md"
cat > "$DIFF" <<'MD'
## Agreed
- [src/auth/store.py:42] Tokens stored in plaintext. | Tokens not encrypted.

## Rex-only
- [src/auth/refresh.py:15-30] No retry logic.
- [src/util/log.py:7] Logger leaks tokens.

## Cody-only
- [src/oauth/callback.py:88] State param unvalidated.
MD

ADJUDICATED="$TMP/adj.md"
cat > "$ADJUDICATED" <<'MD'
## Cross-verified
- [src/auth/refresh.py:15-30] No retry logic. — CODY confirmed (src/auth/refresh.py:25)

## Adjudicated
- CONFIRMED: [src/oauth/callback.py:88] State param unvalidated. — REX disputed but src/oauth/callback.py:88 indeed reads from request not session

## Contested
- [src/util/log.py:7] Logger leaks tokens. — REX raised, CODY disputed; conductor could not confirm
MD

OUT="$TMP/synthesis.md"
cw_consult_synthesize "review auth code" "$DIFF" "$ADJUDICATED" "/state/rex" "/state/cody" "$OUT"

# Header + four mandatory sections.
grep -q '^# Consultation: review auth code' "$OUT"      || { echo "FAIL: missing title"; exit 1; }
grep -q '^## Agreed findings'                  "$OUT"   || { echo "FAIL: missing agreed section"; exit 1; }
grep -q '^## Cross-verified'                   "$OUT"   || { echo "FAIL: missing cross-verified section"; exit 1; }
grep -q '^## Adjudicated'                      "$OUT"   || { echo "FAIL: missing adjudicated section"; exit 1; }
grep -q '^## Contested'                        "$OUT"   || { echo "FAIL: missing contested section"; exit 1; }
grep -q '^## Trooper artifacts'                "$OUT"   || { echo "FAIL: missing artifacts section"; exit 1; }
pass "synthesis has title + 5 sections"

# Trooper artifact paths surface in the report.
grep -q '/state/rex'   "$OUT" || { echo "FAIL: missing rex artifact path";  exit 1; }
grep -q '/state/cody'  "$OUT" || { echo "FAIL: missing cody artifact path"; exit 1; }
pass "synthesis references both troopers' state dirs"
```

- [ ] **Step 2: Run, expect failure**

```bash
bash tests/run.sh test_consult_synthesis.sh
```

- [ ] **Step 3: Implement**

Append to `lib/consult.sh`:

```bash
# cw_consult_synthesize <topic> <diff.md> <adjudicated.md> <rex-state-dir> <cody-state-dir> <out>
# Compose the final synthesis.md. <diff.md> supplies the Agreed section verbatim;
# <adjudicated.md> supplies the Cross-verified, Adjudicated, and Contested
# sections (built by the orchestrator from verify.md + conductor judgement).
cw_consult_synthesize() {
  local topic="$1" diff="$2" adj="$3" rex_dir="$4" cody_dir="$5" out="$6"
  {
    printf '# Consultation: %s\n\n' "$topic"

    printf '## Agreed findings (both raised independently)\n'
    awk '/^## Agreed/{f=1;next} /^## /{f=0} f' "$diff"
    printf '\n'

    # Cross-verified, Adjudicated, Contested come from the adjudicated.md the
    # orchestrator already structured. Pass through verbatim section blocks.
    awk '/^## Cross-verified/{f=1} /^## Adjudicated/{f=1} /^## Contested/{f=1} f' "$adj"
    printf '\n'

    printf '## Trooper artifacts\n'
    printf -- '- REX research:  %s/findings.md\n' "$rex_dir"
    printf -- '- REX verify:    %s/verify.md\n'   "$rex_dir"
    printf -- '- CODY research: %s/findings.md\n' "$cody_dir"
    printf -- '- CODY verify:   %s/verify.md\n'   "$cody_dir"
  } > "$out"
}
```

- [ ] **Step 4: Run, expect pass**

```bash
bash tests/run.sh test_consult_synthesis.sh
```

- [ ] **Step 5: Full suite**

```bash
bash tests/run.sh
```

- [ ] **Step 6: Commit**

```bash
git add lib/consult.sh tests/test_consult_synthesis.sh
git commit -m "feat(consult): synthesis assembler

Composes the final report from diff.md (Agreed), adjudicated.md
(Cross-verified/Adjudicated/Contested), and per-trooper state-dir
pointers. The orchestrator builds adjudicated.md from verify.md
parses + conductor judgement before calling synthesize."
```

---

### Task 10: `bin/send.sh` `@file` regression test

**Why:** Spec prereq P3 — verify `@file` survives the `--args-file` round-trip. Existing functionality, but no automated test today, so a refactor could silently break it.

**Files:**
- Test: `tests/test_send_at_file.sh` (new)

- [ ] **Step 1: Write the test**

```bash
#!/usr/bin/env bash
# tests/test_send_at_file.sh — guard the @file argument flow through args-file.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

# Static wiring: bin/send.sh must read @-prefixed args via the file branch.
grep -q 'MSG_OR_FILE.*@\*'             ../bin/send.sh \
  || { echo "FAIL: bin/send.sh lost @-prefix detection" >&2; exit 1; }
grep -q 'TASK="\$(cat "\$task_file")"' ../bin/send.sh \
  || { echo "FAIL: bin/send.sh lost @file body load" >&2; exit 1; }
pass "bin/send.sh keeps @file branch wired"

# args-file round-trip: a token starting with @ stays a single token after
# args-file load (no shell expansion / wordsplit).
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
ARGS="$TMP/args.txt"
cat > "$ARGS" <<'EOF'
rex
demo
@/tmp/some prompt with spaces.md
EOF
mapfile -t TOK < <(bash -c '
  source ../lib/argsfile.sh
  cw_args_file_load "$1"
' _ "$ARGS")
[[ "${#TOK[@]}" -eq 3 ]] || { echo "FAIL: expected 3 tokens, got ${#TOK[@]}" >&2; exit 1; }
assert_eq "${TOK[2]}" "@/tmp/some prompt with spaces.md" "third token survives intact"
pass "args-file preserves @path-with-spaces as a single token"
```

- [ ] **Step 2: Run, expect pass (functionality already exists)**

```bash
bash tests/run.sh test_send_at_file.sh
```

Expected: PASS — this is a regression guard, not a new feature.

- [ ] **Step 3: Full suite**

```bash
bash tests/run.sh
```

- [ ] **Step 4: Commit**

```bash
git add tests/test_send_at_file.sh
git commit -m "test(send): regression guard for @file argument flow

Static check on bin/send.sh + an args-file round-trip assertion that
@/path/with spaces stays a single token. Pure regression test — no
behavior change."
```

---

### Task 11: `bin/consult.sh` — orchestrator skeleton (validate + spawn)

**Why:** First half of the orchestrator: argument parsing, slug derivation, double-trooper spawn, ready wait. Subsequent tasks layer in research, verify, adjudicate, synthesize.

**Files:**
- Create: `bin/consult.sh` (executable)

- [ ] **Step 1: Stand up the bin script with validation + spawn**

Create `bin/consult.sh`:

```bash
#!/usr/bin/env bash
# bin/consult.sh — orchestrate /clone-wars:consult.
#
# Usage:
#   bin/consult.sh <topic>                       # free-form text
#   bin/consult.sh --args-file <path>            # via slash directive
#
# Spec: docs/superpowers/specs/2026-04-28-clone-wars-consult-design.md

set -uo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deps.sh"
source "$PLUGIN_ROOT/lib/contracts.sh"
source "$PLUGIN_ROOT/lib/commanders.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/tmux.sh"
source "$PLUGIN_ROOT/lib/argsfile.sh"
source "$PLUGIN_ROOT/lib/consult.sh"

if [[ "${1:-}" == "--args-file" ]]; then
  [[ -n "${2:-}" ]] || { echo "--args-file requires a path" >&2; exit 2; }
  args_file="$2"; shift 2
  mapfile -t _TOKENS < <(cw_args_file_load "$args_file")
  set -- "${_TOKENS[@]}" "$@"
fi

usage() { echo "Usage: $0 <topic>" >&2; }

[[ $# -ge 1 ]] || { usage; exit 2; }
TOPIC_TEXT="$*"

# ------------------------------------------------------------ Slug derivation
SLUG=$(printf '%s' "$TOPIC_TEXT" \
  | tr '[:upper:]' '[:lower:]' \
  | tr -c 'a-z0-9-' '-' \
  | sed 's/--*/-/g; s/^-//; s/-$//' \
  | cut -c1-32)
[[ -n "$SLUG" ]] || { log_error "topic produced empty slug; provide alphanumerics"; exit 2; }

CONSULT_TOPIC="consult-$SLUG"
TOPIC_DIR="$(cw_state_root)/state/$(cw_repo_hash)/$CONSULT_TOPIC"
n=2
while [[ -d "$TOPIC_DIR" ]]; do
  CONSULT_TOPIC="consult-$SLUG-$n"
  TOPIC_DIR="$(cw_state_root)/state/$(cw_repo_hash)/$CONSULT_TOPIC"
  n=$((n + 1))
done

log_info "consultation topic: $CONSULT_TOPIC"
log_info "  artifacts dir: $TOPIC_DIR"

# ------------------------------------------------------------ Spawn troopers
REX=rex; CODY=cody
log_info "spawning $REX-codex"
"$PLUGIN_ROOT/bin/spawn.sh" "$REX" codex "$CONSULT_TOPIC" >/dev/null \
  || { log_error "rex spawn failed"; exit 1; }
log_info "spawning $CODY-claude"
"$PLUGIN_ROOT/bin/spawn.sh" "$CODY" claude "$CONSULT_TOPIC" >/dev/null \
  || { log_error "cody spawn failed; tearing down rex"; "$PLUGIN_ROOT/bin/teardown.sh" "$REX" "$CONSULT_TOPIC" >/dev/null 2>&1 || true; exit 1; }
log_ok "both troopers ready"

REX_DIR=$(cw_trooper_dir  "$REX"  codex  "$CONSULT_TOPIC")
CODY_DIR=$(cw_trooper_dir "$CODY" claude "$CONSULT_TOPIC")
mkdir -p "$TOPIC_DIR/_consult"
ART_DIR="$TOPIC_DIR/_consult"

cat <<EOF
  topic:         $CONSULT_TOPIC
  rex state:     $REX_DIR
  cody state:    $CODY_DIR
  artifacts dir: $ART_DIR

(orchestrator skeleton — Phase 2+ wiring in subsequent commits)
EOF
```

- [ ] **Step 2: chmod + smoke**

```bash
chmod +x bin/consult.sh
# Static smoke: usage line on no args.
bin/consult.sh 2>&1 | grep -q 'Usage:' || { echo "FAIL"; exit 1; }
# Static smoke: empty slug rejected.
bin/consult.sh "@@@" 2>&1 | grep -q 'empty slug' || { echo "FAIL"; exit 1; }
echo "ok"
```

(No live spawn smoke yet — that exercises tmux/codex/claude. Tasks 12+ add live integration.)

- [ ] **Step 3: Full suite**

```bash
bash tests/run.sh
```

Expected: existing tests still green (no new test added in this task; orchestrator integration is exercised live in Task 16's dogfood).

- [ ] **Step 4: Commit**

```bash
git add bin/consult.sh
git commit -m "feat(consult): orchestrator skeleton — validate + double-spawn

Slug derivation, conflict resolver, and the spawn-rex-then-cody flow
with rex teardown if cody fails. Phases 2-7 are stubbed pending the
next commits."
```

---

### Task 12: `bin/consult.sh` — Phase 2 research dispatch

**Why:** Send each trooper its research prompt, capture outbox offsets pre-nudge, wait for both done events past the offsets.

**Files:**
- Modify: `bin/consult.sh` (extend with Phase 2 block)

- [ ] **Step 1: Extend the orchestrator**

Replace the closing `cat <<EOF ... EOF` placeholder block in `bin/consult.sh` with:

```bash
# ============================================================ Phase 2 research

log_info "[Phase 2] dispatching research to both troopers"

REX_RESEARCH_PROMPT_FILE="$ART_DIR/rex_research_prompt.md"
CODY_RESEARCH_PROMPT_FILE="$ART_DIR/cody_research_prompt.md"
cw_consult_build_research_prompt "$TOPIC_TEXT" "$REX_DIR/findings.md"  > "$REX_RESEARCH_PROMPT_FILE"
cw_consult_build_research_prompt "$TOPIC_TEXT" "$CODY_DIR/findings.md" > "$CODY_RESEARCH_PROMPT_FILE"

REX_OUTBOX=$(cw_outbox_path  "$REX"  codex  "$CONSULT_TOPIC")
CODY_OUTBOX=$(cw_outbox_path "$CODY" claude "$CONSULT_TOPIC")
REX_OFFSET=$(stat -c '%s' "$REX_OUTBOX")
CODY_OFFSET=$(stat -c '%s' "$CODY_OUTBOX")

"$PLUGIN_ROOT/bin/send.sh" "$REX"  "$CONSULT_TOPIC" "@$REX_RESEARCH_PROMPT_FILE"  >/dev/null \
  || { log_error "rex send failed"; "$PLUGIN_ROOT/bin/teardown.sh" "$CONSULT_TOPIC" >/dev/null 2>&1; exit 1; }
"$PLUGIN_ROOT/bin/send.sh" "$CODY" "$CONSULT_TOPIC" "@$CODY_RESEARCH_PROMPT_FILE" >/dev/null \
  || { log_error "cody send failed"; "$PLUGIN_ROOT/bin/teardown.sh" "$CONSULT_TOPIC" >/dev/null 2>&1; exit 1; }

RESEARCH_TIMEOUT=$(cw_consult_timeout research)
log_info "[Phase 2] waiting up to ${RESEARCH_TIMEOUT}s for both done events"

cat > "$ART_DIR/wait_research.txt" <<EOF
$REX:codex:$CONSULT_TOPIC:$REX_OFFSET
$CODY:claude:$CONSULT_TOPIC:$CODY_OFFSET
EOF

cw_outbox_wait_all "$ART_DIR/wait_research.txt" done error "$RESEARCH_TIMEOUT" \
  || { log_error "[Phase 2] timeout or error before both troopers reported done"; "$PLUGIN_ROOT/bin/teardown.sh" "$CONSULT_TOPIC" >/dev/null 2>&1; exit 1; }

[[ -s "$REX_DIR/findings.md"  ]] || { log_error "rex did not produce findings.md";  "$PLUGIN_ROOT/bin/teardown.sh" "$CONSULT_TOPIC" >/dev/null 2>&1; exit 1; }
[[ -s "$CODY_DIR/findings.md" ]] || { log_error "cody did not produce findings.md"; "$PLUGIN_ROOT/bin/teardown.sh" "$CONSULT_TOPIC" >/dev/null 2>&1; exit 1; }
log_ok "[Phase 2] both findings captured"

cat <<EOF
  topic:         $CONSULT_TOPIC
  rex findings:  $REX_DIR/findings.md
  cody findings: $CODY_DIR/findings.md

(Phase 3+ wiring in subsequent commits)
EOF
```

- [ ] **Step 2: Static smoke (no live tmux)**

```bash
# Validate bash parses the script.
bash -n bin/consult.sh && echo "ok"
```

- [ ] **Step 3: Full suite**

```bash
bash tests/run.sh
```

- [ ] **Step 4: Commit**

```bash
git add bin/consult.sh
git commit -m "feat(consult): Phase 2 research dispatch + wait

Captures pre-nudge outbox offsets so cw_outbox_wait_all only sees
events from the dispatched task. Aborts and tears down both panes if
either trooper times out, errors, or fails to write findings.md."
```

---

### Task 13: `bin/consult.sh` — Phase 3 (diff) + Phase 4 (verify dispatch)

**Why:** Bucket the two findings, dispatch the cross-verify items back through the same panes, and wait for both verify done events.

**Files:**
- Modify: `bin/consult.sh` (extend with Phase 3 + Phase 4)

- [ ] **Step 1: Extend the orchestrator**

Replace the trailing placeholder `cat <<EOF` block with:

```bash
# ============================================================ Phase 3 diff

log_info "[Phase 3] bucketing claims"
DIFF="$ART_DIR/diff.md"
cw_consult_diff "$REX_DIR/findings.md" "$CODY_DIR/findings.md" "$DIFF"

# Pull the two _ONLY lists into items files for the verify dispatch.
REX_ONLY="$ART_DIR/rex_only_items.txt"
CODY_ONLY="$ART_DIR/cody_only_items.txt"
awk '/^## Rex-only/{f=1;next} /^## /{f=0} f && /^- /{ sub(/^- /,""); print }'   "$DIFF" > "$REX_ONLY"
awk '/^## Cody-only/{f=1;next} /^## /{f=0} f && /^- /{ sub(/^- /,""); print }'  "$DIFF" > "$CODY_ONLY"

# ============================================================ Phase 4 verify

if [[ -s "$REX_ONLY" || -s "$CODY_ONLY" ]]; then
  log_info "[Phase 4] dispatching cross-verify"

  # Cross: rex verifies cody-only items; cody verifies rex-only items.
  REX_VERIFY_PROMPT="$ART_DIR/rex_verify_prompt.md"
  CODY_VERIFY_PROMPT="$ART_DIR/cody_verify_prompt.md"
  cw_consult_build_verify_prompt "$CODY_ONLY" "$REX_DIR/verify.md"  > "$REX_VERIFY_PROMPT"
  cw_consult_build_verify_prompt "$REX_ONLY"  "$CODY_DIR/verify.md" > "$CODY_VERIFY_PROMPT"

  REX_OFFSET2=$(stat -c '%s' "$REX_OUTBOX")
  CODY_OFFSET2=$(stat -c '%s' "$CODY_OUTBOX")

  if [[ -s "$CODY_ONLY" ]]; then
    "$PLUGIN_ROOT/bin/send.sh" "$REX"  "$CONSULT_TOPIC" "@$REX_VERIFY_PROMPT"  >/dev/null
  fi
  if [[ -s "$REX_ONLY" ]]; then
    "$PLUGIN_ROOT/bin/send.sh" "$CODY" "$CONSULT_TOPIC" "@$CODY_VERIFY_PROMPT" >/dev/null
  fi

  VERIFY_TIMEOUT=$(cw_consult_timeout verify)
  cat > "$ART_DIR/wait_verify.txt" <<EOF2
$([[ -s "$CODY_ONLY" ]] && echo "$REX:codex:$CONSULT_TOPIC:$REX_OFFSET2")
$([[ -s "$REX_ONLY"  ]] && echo "$CODY:claude:$CONSULT_TOPIC:$CODY_OFFSET2")
EOF2
  cw_outbox_wait_all "$ART_DIR/wait_verify.txt" done error "$VERIFY_TIMEOUT" \
    || log_warn "[Phase 4] one or both verify dispatches timed out — proceeding with partial verification"
else
  log_info "[Phase 4] no cross-verify needed (no Rex-only / Cody-only items)"
fi

cat <<EOF
  diff:          $DIFF
  rex verify:    $REX_DIR/verify.md   (may be absent if no cody-only items)
  cody verify:   $CODY_DIR/verify.md  (may be absent if no rex-only items)

(Phase 5-7 in subsequent commits)
EOF
```

- [ ] **Step 2: Static smoke**

```bash
bash -n bin/consult.sh && echo "ok"
```

- [ ] **Step 3: Full suite**

```bash
bash tests/run.sh
```

- [ ] **Step 4: Commit**

```bash
git add bin/consult.sh
git commit -m "feat(consult): Phase 3 diff + Phase 4 cross-verify dispatch

Conductor buckets via cw_consult_diff, builds per-side verify prompts
from the disjoint claim lists, captures fresh outbox offsets, sends
each side ONLY if its peer's _ONLY list is non-empty (skips the
verify call when one side has no unique items).

Verify timeout failure degrades to partial verification (log warn);
synthesis (next commit) handles missing verify.md gracefully."
```

---

### Task 14: `bin/consult.sh` — Phases 5–7 (adjudicate + synthesize + teardown)

**Why:** Assemble adjudicated.md from the verify outputs (with a conductor-judgement section drawn from in-process logic), call `cw_consult_synthesize`, print the report, and tear down.

**Files:**
- Modify: `bin/consult.sh` (extend with final phases)

- [ ] **Step 1: Extend the orchestrator**

Replace the trailing placeholder `cat <<EOF` block with:

```bash
# ============================================================ Phase 5 adjudicate

log_info "[Phase 5] adjudicating verify verdicts"
ADJ="$ART_DIR/adjudicated.md"
{
  printf '## Cross-verified\n'
  # Pairs: rex-only items where cody returned AGREE (and vice versa).
  if [[ -f "$CODY_DIR/verify.md" ]]; then
    cw_consult_parse_verdicts "$CODY_DIR/verify.md" \
      | awk -F'\t' '$1 == "AGREE" { printf "- [%s] %s — CODY confirmed: %s\n", $2, $3, $3 }'
  fi
  if [[ -f "$REX_DIR/verify.md" ]]; then
    cw_consult_parse_verdicts "$REX_DIR/verify.md" \
      | awk -F'\t' '$1 == "AGREE" { printf "- [%s] %s — REX confirmed: %s\n", $2, $3, $3 }'
  fi

  printf '\n## Adjudicated\n'
  # DISPUTE / UNCERTAIN: conductor cannot itself read source files in pure
  # bash without delegating to the calling Claude Code session. We emit each
  # contested item as CONTESTED with the verdict and original claim, deferring
  # the read-the-source-and-decide step to the conductor's text response (the
  # Claude Code session that invoked /clone-wars:consult).
  printf '(Conductor: read each cited source and rewrite this section with CONFIRMED / REFUTED labels.)\n'
  if [[ -f "$CODY_DIR/verify.md" ]]; then
    cw_consult_parse_verdicts "$CODY_DIR/verify.md" \
      | awk -F'\t' '$1 != "AGREE" { printf "- %s: [%s] %s — CODY %s: %s\n", "PENDING", $2, $3, $1, $3 }'
  fi
  if [[ -f "$REX_DIR/verify.md" ]]; then
    cw_consult_parse_verdicts "$REX_DIR/verify.md" \
      | awk -F'\t' '$1 != "AGREE" { printf "- %s: [%s] %s — REX %s: %s\n", "PENDING", $2, $3, $1, $3 }'
  fi

  printf '\n## Contested\n'
  printf '(Items the conductor could not resolve from cited sources.)\n'
} > "$ADJ"

# ============================================================ Phase 6 synthesize

log_info "[Phase 6] synthesizing report"
SYN="$ART_DIR/synthesis.md"
cw_consult_synthesize "$TOPIC_TEXT" "$DIFF" "$ADJ" "$REX_DIR" "$CODY_DIR" "$SYN"

cat <<EOF

============================================================
  CONSULTATION REPORT (draft)
============================================================
EOF
cat "$SYN"
cat <<EOF
============================================================

  artifacts:
    diff:          $DIFF
    adjudicated:   $ADJ
    synthesis:     $SYN
    rex findings:  $REX_DIR/findings.md
    cody findings: $CODY_DIR/findings.md

  next: read the cited sources for any "PENDING" items in the
  Adjudicated section, decide CONFIRMED / REFUTED / CONTESTED,
  and rewrite \$ADJ. The conductor (the Claude Code session that
  invoked /clone-wars:consult) is responsible for this step;
  the bash orchestrator stops here.

EOF

# ============================================================ Phase 7 teardown

log_info "[Phase 7] tearing down troopers"
"$PLUGIN_ROOT/bin/teardown.sh" "$CONSULT_TOPIC" >/dev/null 2>&1 || true
log_ok "consultation $CONSULT_TOPIC complete"
```

- [ ] **Step 2: Static smoke**

```bash
bash -n bin/consult.sh && echo "ok"
```

- [ ] **Step 3: Full suite**

```bash
bash tests/run.sh
```

- [ ] **Step 4: Commit**

```bash
git add bin/consult.sh
git commit -m "feat(consult): Phases 5-7 adjudicate + synthesize + teardown

Adjudication pre-fills CONTESTED items with PENDING tags; the
conductor (the calling Claude Code session) is responsible for the
read-the-source-and-decide step that turns each PENDING into
CONFIRMED / REFUTED / CONTESTED.

Synthesis prints the draft inline so the conductor sees the full
report without opening files. Teardown runs unconditionally — even
if synthesis produced a degraded report, the panes are released."
```

---

### Task 15: Slash directive at `commands/consult.md`

**Why:** Final user-facing surface. Same pattern as the other five commands: directive markdown writes the user's argument to an args-file, then bash-invokes `bin/consult.sh --args-file <path>`.

**Files:**
- Create: `commands/consult.md`

- [ ] **Step 1: Create the directive**

```markdown
---
description: Spawn rex+codex and cody+claude on a topic; cross-verify their findings; produce a synthesized report
argument-hint: <topic — what the troopers should research>
---

# /clone-wars:consult

Run a cross-verified dual-model investigation on `$ARGUMENTS`. The conductor
spawns one codex pane (rex) and one claude pane (cody), dispatches an
independent research task to each, diffs their findings, dispatches each side's
unique claims to the OTHER for verification, then adjudicates and synthesizes
the four-section report.

Both panes stay attached for the entire run — you can `tmux select-pane` and
watch each model work live.

Spec: `docs/superpowers/specs/2026-04-28-clone-wars-consult-design.md`

## Steps

The user's `$ARGUMENTS` may contain shell metacharacters. To prevent injection,
write it via the Write tool, then invoke the bin script with `--args-file`.

1. Use the Bash tool to resolve the args-file path:

   ```
   ARGS_DIR="${CLONE_WARS_HOME:-$HOME/.clone-wars}/_args"
   mkdir -p "$ARGS_DIR"
   echo "$ARGS_DIR/consult.txt"
   ```

2. Use the Write tool to put `$ARGUMENTS` into that path:

   - `file_path`: the absolute path printed by step 1
   - `content`: the literal value of `$ARGUMENTS`

3. Use the Bash tool to invoke consult:

   ```
   "$CLAUDE_PLUGIN_ROOT/bin/consult.sh" --args-file "$ARGS_DIR/consult.txt"
   ```

4. Show the script's output to the user. The output ends with a draft synthesis.md
   that may have **PENDING** items in the Adjudicated section.

5. **Conductor responsibility — the read-the-source step.** For each PENDING item:
   - Read the cited source (file:line or URL).
   - Decide whether REX or CODY's original claim holds.
   - Rewrite that line in the synthesis with `CONFIRMED:` / `REFUTED:` /
     `CONTESTED:` and a one-line evidence note.

6. Show the user the final synthesis (after PENDING resolution).
```

- [ ] **Step 2: Sanity-check it loads with the rest of the plugin**

(Manual — no test for slash-directive metadata.)

- [ ] **Step 3: Full suite**

```bash
bash tests/run.sh
```

- [ ] **Step 4: Commit**

```bash
git add commands/consult.md
git commit -m "feat(commands): /clone-wars:consult slash directive

Writes \$ARGUMENTS to args-file, invokes bin/consult.sh, then makes
the conductor (the Claude Code session running this command)
responsible for the read-the-source PENDING resolution step before
showing the user the final synthesis."
```

---

### Task 16: README + version bump to v0.1.0

**Why:** Final release polish — user-facing docs, marketplace version. Mirrors the v0.0.4–v0.0.6 release pattern.

**Files:**
- Modify: `README.md`
- Modify: `.claude-plugin/plugin.json` (version 0.0.6 → 0.1.0)
- Modify: `.claude-plugin/marketplace.json` (version 0.0.6 → 0.1.0)

- [ ] **Step 1: Add a `/clone-wars:consult` section to README.md**

Insert after the existing "Commands" table, before "Visual identity":

```markdown
---

## Orchestration: `/clone-wars:consult`

`/clone-wars:consult <topic>` is the first orchestration command built on top
of the spawn/send/collect/teardown primitives. Use it when you want a
cross-verified investigation:

1. The conductor spawns **rex (codex)** and **cody (claude)** on a fresh topic.
2. Both research the topic independently, writing structured findings.
3. The conductor diffs the findings into Agreed / Rex-only / Cody-only.
4. Each side's unique claims get dispatched back to the OTHER trooper for
   AGREE / DISPUTE / UNCERTAIN verification — using the SAME pane (the codex
   and claude TUIs preserve in-session memory across the two calls).
5. The conductor adjudicates disputed items by reading the cited sources
   directly, then synthesizes a four-section report (Agreed / Cross-verified /
   Adjudicated / Contested).

```
/clone-wars:consult "review src/auth/oauth.py for token-refresh edge cases"
```

The full spec is at `docs/superpowers/specs/2026-04-28-clone-wars-consult-design.md`.

---
```

- [ ] **Step 2: Bump version manifests**

In `.claude-plugin/plugin.json`:

```json
"version": "0.1.0",
```

In `.claude-plugin/marketplace.json` (TWO occurrences — top-level and inside the plugins array):

```json
"version": "0.1.0",
```

- [ ] **Step 3: Full suite + medic + dogfood**

```bash
bash tests/run.sh        # all green
bash bin/medic.sh        # verdict: OK
# Live dogfood (manual):
# /clone-wars:consult "review tests/test_consult_diff.sh for edge cases"
# Verify: both panes spawn → both produce findings.md → diff buckets visible →
# both verify → synthesis prints with PENDING items → conductor resolves PENDINGs.
```

- [ ] **Step 4: Commit**

```bash
git add README.md .claude-plugin/plugin.json .claude-plugin/marketplace.json
git commit -m "release: v0.1.0 — /clone-wars:consult cross-verified dual-model research

First orchestration command on top of the v0.0.x primitives. Spawns
rex+codex and cody+claude, diffs findings, cross-verifies through the
same panes (TUI memory preserved), adjudicates disputes from source,
synthesizes a four-section report."
```

---

## Self-review

**1. Spec coverage**

| Spec section | Plan coverage |
|---|---|
| Phases 1–7 DAG | Tasks 11–14 (orchestrator) |
| Two-call lifecycle per pane | Tasks 12 + 13 use `cw_outbox_wait_since` to wait for the SECOND done |
| Findings format (## Claims, [citation] prefix) | Task 8 (research prompt) writes the format; Task 5 (parser) reads it |
| Verify format (AGREE/DISPUTE/UNCERTAIN) | Task 7 (verify prompt + verdict parser) |
| Diff bucketing | Task 6 |
| Adjudication outcome (CONFIRMED / REFUTED / CONTESTED) | Task 14 emits PENDING; conductor (Claude Code session) finalizes |
| Synthesis four sections | Task 9 + Task 14 |
| State layout `consult-<slug>/_consult/` | Task 11 creates `$ART_DIR=$TOPIC_DIR/_consult` |
| Failure modes | Task 11 (rex spawn fail), Task 12 (research timeout/error abort), Task 13 (verify partial degradation), Task 14 (synthesis ships even with empty verify outputs) |
| Prerequisite P1 (multi-task identity) | Task 3 |
| Prerequisite P2 (cw_outbox_wait_since) | Task 1 |
| Prerequisite P3 (@file regression) | Task 10 |
| Prerequisite P4 (findings/verify path helpers) | Task 5 |
| Prerequisite P5 (cw_outbox_wait_all) | Task 2 |
| Out-of-scope items (literature, mode selection, grading) | Not in any task — confirmed dropped per spec |

No gaps. Every spec requirement maps to a task.

**2. Placeholder scan**

Searched the plan for "TBD", "TODO", "implement later", "fill in", "Add appropriate", "Similar to Task". None found. Every code block contains complete code. Every command has expected output.

**3. Type consistency**

- `cw_consult_findings_path / verify_path / parse_claims / parse_verdicts / diff / build_research_prompt / build_verify_prompt / synthesize` — used identically across Tasks 5–9 and 11–14.
- `cw_outbox_wait_since` (Task 1) and `cw_outbox_wait_all` (Task 2) — same arg shape: `<...> <event...> <timeout>`. Reused identically in Tasks 12 + 13.
- `cw_consult_timeout research` / `cw_consult_timeout verify` — defined Task 4, used Tasks 12 + 13.
- `$REX_DIR / $CODY_DIR / $ART_DIR / $CONSULT_TOPIC` — established Task 11, reused unchanged through Task 14.
- TSV claim format `<citation>\t<text>` — defined Task 5, consumed Task 6, never deviated.
- TSV verdict format `<tag>\t<citation>\t<text>` — defined Task 7, consumed Task 14.

All type/signature consistent.

---

## Execution

Plan complete and saved to `docs/superpowers/plans/2026-04-28-clone-wars-consult-plan.md`.

**Recommended execution mode:** subagent-driven-development.

Tasks 1–10 are mechanical (test → impl → commit) and well-suited to a fast model. Tasks 11–14 are integration tasks touching the orchestrator script — they need a standard model. Task 16 is a bump+commit.

Per the v0.0.4–v0.0.6 hardening pattern: invoke `codex:adversarial-review` on this plan before dispatching any implementation subagents. Codex consistently catches design holes (signature mismatches, missing offset cursors, prompt-injection paths) at the plan stage; same gate applies here.
