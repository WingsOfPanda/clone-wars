# /clone-wars:consult Implementation Plan

> **Revised 2026-04-28 post-Codex adversarial review.** Six findings closed: slug-length spawn fail (Task 11), citation overlap matcher (Task 6), PENDING handoff via two-stage bash (Tasks 14 + 15), NOT_VERIFIED tagging (Tasks 13 + 9), malformed-findings degraded path (Tasks 5 + 9), `_consult/` archive (Task 15).

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `/clone-wars:consult <topic>` — the first orchestration command on top of the spawn/send/collect/teardown primitives. Conductor spawns rex+codex and cody+claude, both research independently, conductor diffs and dispatches cross-verify back through the same panes, then adjudicates and synthesizes a four-section report.

**Architecture:** Pure bash + tmux + file IPC. Two-stage execution: `bin/consult.sh` runs Phases 1–5 and writes `adjudicated.md` containing PENDING items; the slash directive (`commands/consult.md`) makes the conductor (Claude Code session) read each cited source and resolve PENDINGs in-place; then `bin/consult-finalize.sh` runs Phases 6–7 (synthesis + teardown + archive of `_consult/`). New `lib/consult.sh` carries paths/parsers/diff/prompt-builders/synthesizer.

**Tech Stack:** bash 4.2+, tmux 3.0+, awk/sed/grep, pure-bash test harness.

**Spec:** `docs/superpowers/specs/2026-04-28-clone-wars-consult-design.md`

---

## File structure

| File | Responsibility | Action |
|---|---|---|
| `lib/ipc.sh` | `cw_outbox_wait_since` + `cw_outbox_wait_all` | Modify |
| `lib/consult.sh` | Paths, parsers, citation-overlap matcher, diff, prompt builders, synthesizer | Create |
| `lib/contracts.sh` | `cw_consult_timeout` reader | Modify |
| `config/contracts.yaml` | `consult:` block with timeouts | Modify |
| `config/identity-template.md` | Inbox-specified output-path discipline | Modify |
| `bin/consult.sh` | Orchestrator Phases 1–5 (writes `adjudicated.md` with PENDINGs) | Create |
| `bin/consult-finalize.sh` | Orchestrator Phases 6–7 (synthesize + teardown + `_consult/` archive) | Create |
| `bin/teardown.sh` | Stays unchanged — `consult-finalize.sh` archives `_consult/` itself | (n/a) |
| `commands/consult.md` | Slash directive (drives conductor through resolve → finalize) | Create |
| 8 new test files + 1 modified | See per-task list | Create/Modify |
| `README.md` + `.claude-plugin/plugin.json` + `.claude-plugin/marketplace.json` | Release polish | Modify |

---

## Task summary (17 tasks)

1. `cw_outbox_wait_since` — cursor-aware outbox wait
2. `cw_outbox_wait_all` — block until N troopers all done
3. Identity-template multi-task language
4. `consult:` block + `cw_consult_timeout`
5. `lib/consult.sh` paths + parser + **`cw_consult_findings_status`** (degraded-mode signal)
6. **`cw_consult_citation_overlaps` + overlap-aware `cw_consult_diff`** (rewritten)
7. Verify-prompt builder + verdict parser
8. Research-prompt builder
9. **Synthesis assembler with NOT_VERIFIED + banners** (extended)
10. `@file` send.sh regression test
11. **`bin/consult.sh` skeleton — slug cap to 20 chars** (revised)
12. **Phase 2 research dispatch — track per-side dispatch status** (revised)
13. **Phase 3+4 — track per-side verify status; carry NOT_VERIFIED forward** (revised)
14. **Phase 5 — write `adjudicated.md` only; NO synthesis, NO teardown** (rewritten)
15. **`bin/consult-finalize.sh` — synthesize + teardown + `_consult/` archive** (NEW)
16. **`commands/consult.md` — drive resolve → finalize** (rewritten)
17. README + v0.1.0 release

---

### Task 1: `cw_outbox_wait_since` — cursor-aware outbox wait

**Why:** Phase 4 verify dispatch needs to wait for the *next* `done` past a known offset, not re-trigger on the previous task's `done`.

**Files:** Test `tests/test_outbox_cursor.sh` (new); modify `lib/ipc.sh`.

- [ ] **Step 1: Write the failing test**

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

cw_state_init alpha codex demo
OUTBOX=$(cw_outbox_path alpha codex demo)

echo '{"event":"done","ts":"t1","summary":"first"}' >> "$OUTBOX"
got=$(cw_outbox_wait_since alpha codex demo 0 done 5)
[[ "$got" == *'"summary":"first"'* ]] || { echo "FAIL: first done at offset 0" >&2; exit 1; }
pass "match at offset 0"

OFFSET=$(stat -c '%s' "$OUTBOX")
echo '{"event":"done","ts":"t2","summary":"second"}' >> "$OUTBOX"
got=$(cw_outbox_wait_since alpha codex demo "$OFFSET" done 5)
[[ "$got" == *'"summary":"second"'* ]] || { echo "FAIL: second done after offset" >&2; exit 1; }
pass "skip events before offset"

OFFSET=$(stat -c '%s' "$OUTBOX")
out=$(cw_outbox_wait_since alpha codex demo "$OFFSET" done 1) && rc=0 || rc=$?
assert_eq "$out" "" "no event past EOF"
[[ "$rc" -eq 1 ]] || { echo "FAIL: expected rc=1 on timeout" >&2; exit 1; }
pass "rc=1 on timeout"

# Multi-event varargs.
OFFSET=$(stat -c '%s' "$OUTBOX")
echo '{"event":"error","ts":"t3","message":"boom"}' >> "$OUTBOX"
got=$(cw_outbox_wait_since alpha codex demo "$OFFSET" done error 5)
[[ "$got" == *'"event":"error"'* ]] || { echo "FAIL: error in multi-event call" >&2; exit 1; }
pass "multi-event varargs"
```

- [ ] **Step 2: Run, expect failure**

```bash
bash tests/run.sh test_outbox_cursor.sh
```

- [ ] **Step 3: Implement in `lib/ipc.sh`**

Insert after `cw_outbox_wait`:

```bash
# cw_outbox_wait_since <commander> <model> <topic> <byte-offset> <event...> <timeout>
# Like cw_outbox_wait, but only considers content AFTER <byte-offset>. Capture
# stat -c '%s' BEFORE the inbox nudge; this wait then matches only events the
# dispatched task produced.
cw_outbox_wait_since() {
  local commander="$1" model="$2" topic="$3" offset="$4"
  shift 4
  (( $# >= 2 )) || { echo "cw_outbox_wait_since: need event(s) and timeout" >&2; return 2; }
  local timeout="${!#}"
  set -- "${@:1:$#-1}"
  local events=("$@")
  [[ "$offset"  =~ ^[0-9]+$ ]] || { echo "cw_outbox_wait_since: bad offset '$offset'" >&2; return 2; }
  [[ "$timeout" =~ ^[0-9]+$ ]] || { echo "cw_outbox_wait_since: bad timeout '$timeout'" >&2; return 2; }
  local outbox; outbox=$(cw_outbox_path "$commander" "$model" "$topic")
  local i event pat tail_size tail_content
  for ((i = 0; i < timeout; i++)); do
    if [[ -f "$outbox" ]]; then
      tail_size=$(stat -c '%s' "$outbox")
      if (( tail_size > offset )); then
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

- [ ] **Step 4: Run, expect pass**

```bash
bash tests/run.sh test_outbox_cursor.sh && bash tests/run.sh
```

- [ ] **Step 5: Commit**

```bash
git add lib/ipc.sh tests/test_outbox_cursor.sh
git commit -m "feat(ipc): cw_outbox_wait_since cursor-aware outbox wait"
```

---

### Task 2: `cw_outbox_wait_all` — block until N troopers all done

**Files:** extend `tests/test_outbox_cursor.sh`; modify `lib/ipc.sh`.

- [ ] **Step 1: Append failing test**

```bash
# 5. wait_all matches one trooper, then the second.
cw_state_init bravo codex demo2
B_OUTBOX=$(cw_outbox_path bravo codex demo2)

cat > "$TMP/troopers.txt" <<EOF
alpha:codex:demo:0
bravo:codex:demo2:0
EOF

echo '{"event":"done","ts":"t10","summary":"a-done"}' >> "$OUTBOX"
( sleep 1; echo '{"event":"done","ts":"t11","summary":"b-done"}' >> "$B_OUTBOX" ) &

cw_outbox_wait_all "$TMP/troopers.txt" done 30
[[ "$?" -eq 0 ]] || { echo "FAIL: wait_all expected 0" >&2; exit 1; }
pass "wait_all matches both"

# 6. Partial timeout returns rc=1.
cw_state_init charlie codex demo3
cat > "$TMP/troopers2.txt" <<EOF
alpha:codex:demo:$(stat -c '%s' "$OUTBOX")
charlie:codex:demo3:0
EOF
out=$(cw_outbox_wait_all "$TMP/troopers2.txt" done 1) && rc=0 || rc=$?
[[ "$rc" -eq 1 ]] || { echo "FAIL: rc=$rc, expected 1" >&2; exit 1; }
pass "rc=1 if any trooper times out"

# 7. Empty file returns rc=2 (caller must handle).
: > "$TMP/empty.txt"
out=$(cw_outbox_wait_all "$TMP/empty.txt" done 1) && rc=0 || rc=$?
[[ "$rc" -eq 2 ]] || { echo "FAIL: empty file expected rc=2" >&2; exit 1; }
pass "rc=2 on empty troopers file"
```

The 30s timeout in case 5 (vs 10s previously) gives the background `sleep 1` writer plenty of headroom on a slow CI runner so the test isn't flaky.

- [ ] **Step 2: Run, expect failure**

```bash
bash tests/run.sh test_outbox_cursor.sh
```

- [ ] **Step 3: Implement**

Append to `lib/ipc.sh`:

```bash
# cw_outbox_wait_all <troopers-file> <event...> <timeout>
# Block until every trooper listed all match. <troopers-file> format:
# one line per trooper, colon-delimited "<commander>:<model>:<topic>:<offset>".
# Returns 0 if all matched within <timeout>; 1 if any trooper timed out;
# 2 on bad args / empty file.
cw_outbox_wait_all() {
  local file="$1"; shift
  (( $# >= 2 )) || { echo "cw_outbox_wait_all: need event(s) and timeout" >&2; return 2; }
  local timeout="${!#}"
  set -- "${@:1:$#-1}"
  local events=("$@")
  [[ -f "$file" ]]             || { echo "cw_outbox_wait_all: file not found: $file" >&2; return 2; }
  [[ "$timeout" =~ ^[0-9]+$ ]] || { echo "cw_outbox_wait_all: bad timeout '$timeout'" >&2; return 2; }

  mapfile -t lines < <(grep -v '^[[:space:]]*$' "$file")
  (( ${#lines[@]} > 0 )) || { echo "cw_outbox_wait_all: empty troopers file" >&2; return 2; }

  local deadline=$(( $(date +%s) + timeout ))
  local line commander model topic offset remaining
  for line in "${lines[@]}"; do
    IFS=':' read -r commander model topic offset <<< "$line"
    [[ -n "$commander" && -n "$model" && -n "$topic" && -n "$offset" ]] \
      || { echo "cw_outbox_wait_all: malformed line: $line" >&2; return 2; }
    remaining=$(( deadline - $(date +%s) ))
    (( remaining > 0 )) || return 1
    cw_outbox_wait_since "$commander" "$model" "$topic" "$offset" "${events[@]}" "$remaining" >/dev/null || return 1
  done
  return 0
}
```

- [ ] **Step 4: Run, expect pass**

```bash
bash tests/run.sh test_outbox_cursor.sh && bash tests/run.sh
```

- [ ] **Step 5: Commit**

```bash
git add lib/ipc.sh tests/test_outbox_cursor.sh
git commit -m "feat(ipc): cw_outbox_wait_all blocks until N troopers all done"
```

---

### Task 3: Identity template — write findings to inbox-specified path

**Why:** Spec prereq P1. Inbox-prompted output-path discipline so troopers don't fold long output into the truncated `done.summary`.

**Files:** modify `config/identity-template.md`; modify `tests/test_identity_template.sh`.

- [ ] **Step 1: Append failing assertion**

In `tests/test_identity_template.sh`, after the existing assertions:

```bash
grep -q 'inbox specifies' "$IDENTITY" \
  || { echo "FAIL: identity missing inbox-specified output-path discipline" >&2; exit 1; }
pass "identity: inbox-specified output path discipline"
```

(`$IDENTITY` is the rendered identity.md set up earlier in the test.)

- [ ] **Step 2: Run, expect failure**

```bash
bash tests/run.sh test_identity_template.sh
```

- [ ] **Step 3: Insert after line 20 of `config/identity-template.md`**

```markdown
When the inbox specifies an output path (e.g., "write your findings to
`<state-dir>/findings.md`"), write to that path BEFORE emitting `done`.
The `done` event's `summary` field is for a one-line headline; the full
output goes in the file you wrote.

This sentence is INERT for tasks that don't specify an output path —
short tasks remain summary-only.
```

The "inert for tasks that don't specify" line is deliberate so the existing tracer-bullet smoke (no findings.md instruction) still works.

- [ ] **Step 4: Run, expect pass**

```bash
bash tests/run.sh
```

- [ ] **Step 5: Commit**

```bash
git add config/identity-template.md tests/test_identity_template.sh
git commit -m "feat(identity): inbox-specified output-path discipline (inert for legacy tasks)"
```

---

### Task 4: `consult:` block + `cw_consult_timeout`

**Files:** modify `config/contracts.yaml`, `lib/contracts.sh`, `tests/test_contracts.sh`.

- [ ] **Step 1: Add failing test**

Append to `tests/test_contracts.sh`:

```bash
# === consult: block ===
cat > "$TMP_C/contracts.yaml" <<YAML
codex:
  binary: codex
  modes: { full: [--bypass] }
  default_mode: full
  ready_timeout_s: 30

consult:
  research_timeout_s: 600
  verify_timeout_s: 300
YAML
got=$(CLONE_WARS_HOME="$TMP_C" cw_consult_timeout research)
assert_eq "$got" "600" "research reads back"
got=$(CLONE_WARS_HOME="$TMP_C" cw_consult_timeout verify)
assert_eq "$got" "300" "verify reads back"
pass "consult timeouts read back"

# Defaults when block missing.
cat > "$TMP_C/contracts.yaml" <<YAML
codex:
  binary: codex
  modes: { full: [--bypass] }
  default_mode: full
  ready_timeout_s: 30
YAML
got=$(CLONE_WARS_HOME="$TMP_C" cw_consult_timeout research); assert_eq "$got" "600" "research default 600"
got=$(CLONE_WARS_HOME="$TMP_C" cw_consult_timeout verify);   assert_eq "$got" "300" "verify default 300"
pass "defaults applied when block missing"

# Malformed value falls back to default.
cat > "$TMP_C/contracts.yaml" <<YAML
codex:
  binary: codex
  modes: { full: [--bypass] }
  default_mode: full
  ready_timeout_s: 30

consult:
  research_timeout_s: -5
  verify_timeout_s:   notaninteger
YAML
got=$(CLONE_WARS_HOME="$TMP_C" cw_consult_timeout research); assert_eq "$got" "600" "negative falls back"
got=$(CLONE_WARS_HOME="$TMP_C" cw_consult_timeout verify);   assert_eq "$got" "300" "non-integer falls back"
pass "malformed values fall back to defaults"
```

- [ ] **Step 2: Run, expect failure**

```bash
bash tests/run.sh test_contracts.sh
```

- [ ] **Step 3: Implement**

Append to `lib/contracts.sh`:

```bash
# cw_consult_timeout <kind>
# Print the configured timeout for <kind> ∈ {research, verify}. Reads the
# consult: block in contracts.yaml; falls back to research=600, verify=300
# on missing block, missing field, or non-positive-integer value.
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
  if [[ -z "$v" ]] || ! [[ "$v" =~ ^[1-9][0-9]*$ ]]; then
    v="$default"
  fi
  printf '%s\n' "$v"
}
```

Append to `config/contracts.yaml`:

```yaml

consult:
  research_timeout_s: 600   # 10 min
  verify_timeout_s:   300   # 5 min
```

- [ ] **Step 4: Run, expect pass**

```bash
bash tests/run.sh
```

- [ ] **Step 5: Commit**

```bash
git add lib/contracts.sh config/contracts.yaml tests/test_contracts.sh
git commit -m "feat(contracts): consult: block + cw_consult_timeout with default-fallback on bad values"
```

---

### Task 5: `lib/consult.sh` paths + claims parser + `cw_consult_findings_status`

**Why:** Spec degraded path requires distinguishing four states for findings.md: `ok` (parseable claims), `empty` (no claims block content), `malformed` (file present, content present, but parser extracted zero items — Codex finding #5), `missing` (file absent).

**Files:** create `lib/consult.sh`; create `tests/test_consult_findings_parse.sh`.

- [ ] **Step 1: Write the failing test**

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
assert_eq "$(cw_consult_findings_path alpha codex demo)" "$DIR/findings.md" "findings path"
assert_eq "$(cw_consult_verify_path   alpha codex demo)" "$DIR/verify.md"   "verify path"
pass "path helpers"

# Well-formed claims.
cat > "$DIR/findings.md" <<'MD'
# Findings: x
## Summary
.
## Claims
1. [src/auth/store.py:42] Tokens stored in plaintext.
2. [src/auth/refresh.py:15-30] No retry logic on refresh.
3. [https://example.com/x] External source.
## Notes
MD
mapfile -t CLAIMS < <(cw_consult_parse_claims "$DIR/findings.md")
[[ "${#CLAIMS[@]}" -eq 3 ]] || { echo "FAIL: 3 claims, got ${#CLAIMS[@]}" >&2; exit 1; }
assert_eq "${CLAIMS[0]%%$'\t'*}" "src/auth/store.py:42" "claim 1 cite"
assert_eq "${CLAIMS[2]%%$'\t'*}" "https://example.com/x" "URL cite"
pass "well-formed parsed into 3 claims"

# Status = ok
status=$(cw_consult_findings_status "$DIR/findings.md")
assert_eq "$status" "ok" "well-formed → ok"

# Empty Claims block (no items, but block present).
cat > "$DIR/findings.md" <<'MD'
# Findings: x
## Summary
nothing
## Claims
## Notes
MD
mapfile -t CLAIMS < <(cw_consult_parse_claims "$DIR/findings.md")
[[ "${#CLAIMS[@]}" -eq 0 ]] || { echo "FAIL: empty block expected 0" >&2; exit 1; }
status=$(cw_consult_findings_status "$DIR/findings.md")
assert_eq "$status" "empty" "block empty → empty"
pass "empty Claims block"

# Malformed: file has content but parser extracts 0 (no [citation] anywhere).
cat > "$DIR/findings.md" <<'MD'
# Findings: x
## Summary
A long discussion of token storage and refresh behavior, written in prose.
The trooper did real work but didn't follow the format. Need to surface this.
## Claims
1. The store has plaintext tokens.
2. Refresh has no retry logic.
## Notes
MD
mapfile -t CLAIMS < <(cw_consult_parse_claims "$DIR/findings.md")
[[ "${#CLAIMS[@]}" -eq 0 ]] || { echo "FAIL: malformed expected 0" >&2; exit 1; }
status=$(cw_consult_findings_status "$DIR/findings.md")
assert_eq "$status" "malformed" "no [cite] under non-empty Claims → malformed"
pass "malformed (zero parseable claims) detected"

# Missing
status=$(cw_consult_findings_status "$DIR/missing.md")
assert_eq "$status" "missing" "absent file → missing"
pass "missing detected"
```

- [ ] **Step 2: Run, expect failure**

```bash
bash tests/run.sh test_consult_findings_parse.sh
```

- [ ] **Step 3: Create `lib/consult.sh`**

```bash
# lib/consult.sh — /clone-wars:consult helpers.
# Sourced. Depends on lib/state.sh, lib/ipc.sh, lib/contracts.sh.

cw_consult_findings_path() { printf '%s/findings.md\n' "$(cw_trooper_dir "$1" "$2" "$3")"; }
cw_consult_verify_path()   { printf '%s/verify.md\n'   "$(cw_trooper_dir "$1" "$2" "$3")"; }

# cw_consult_parse_claims <findings.md>
# Print one TAB-delimited line per claim: "<citation>\t<text>".
# Source format: `N. [<citation>] <text>` lines under `## Claims`.
# Lines without [citation] are silently skipped.
cw_consult_parse_claims() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  awk '
    /^## Claims/      { in_claims = 1; next }
    /^## /            { in_claims = 0 }
    in_claims && /^[0-9]+\. \[[^]]+\] / {
      match($0, /\[[^]]+\]/)
      cite = substr($0, RSTART + 1, RLENGTH - 2)
      text = substr($0, RSTART + RLENGTH + 1)
      sub(/^[ \t]+/, "", text)
      printf "%s\t%s\n", cite, text
    }
  ' "$file"
}

# cw_consult_findings_status <findings.md>
# Print one of: ok | empty | malformed | missing.
#   missing   — file absent
#   ok        — Claims block contains ≥1 parseable item
#   empty     — Claims block exists but has no body content (whitespace only)
#   malformed — Claims block has body content but 0 parseable items
cw_consult_findings_status() {
  local file="$1"
  [[ -f "$file" ]] || { echo missing; return 0; }
  local n_parsed n_lines
  n_parsed=$(cw_consult_parse_claims "$file" | wc -l)
  if (( n_parsed > 0 )); then echo ok; return 0; fi
  # Count non-blank lines under ## Claims (excluding the ## Claims heading).
  n_lines=$(awk '
    /^## Claims/   { in_claims = 1; next }
    /^## /         { in_claims = 0 }
    in_claims && NF { count++ }
    END            { print count + 0 }
  ' "$file")
  if (( n_lines > 0 )); then echo malformed; else echo empty; fi
}
```

- [ ] **Step 4: Run, expect pass**

```bash
bash tests/run.sh
```

- [ ] **Step 5: Commit**

```bash
git add lib/consult.sh tests/test_consult_findings_parse.sh
git commit -m "feat(consult): paths + claims parser + findings_status (degraded-mode signal)

cw_consult_findings_status returns one of {ok, empty, malformed, missing}
so synthesis can emit the spec-required degraded banner when a trooper
writes prose but doesn't follow the [citation] format."
```

---

### Task 6: Citation overlap matcher + overlap-aware diff

**Why:** Codex finding #2 — spec said "agree iff overlapping line range OR same URL" but original plan used byte-identical strings via `join`. Two citations like `src/x.py:15-30` and `src/x.py:20` should bucket as AGREE (the second cites a line within the first's range). Same path with `./` prefix should normalize.

**Files:** modify `lib/consult.sh`; create `tests/test_consult_diff.sh`.

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# tests/test_consult_diff.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/state.sh
source ../lib/ipc.sh
source ../lib/consult.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# === citation overlap: pairwise unit tests ===
cw_consult_citation_overlaps "src/x.py:5"     "src/x.py:5"      || { echo "FAIL: same line"        >&2; exit 1; }
cw_consult_citation_overlaps "src/x.py:5-10"  "src/x.py:7"      || { echo "FAIL: line in range"   >&2; exit 1; }
cw_consult_citation_overlaps "src/x.py:5-10"  "src/x.py:8-15"   || { echo "FAIL: ranges overlap"  >&2; exit 1; }
cw_consult_citation_overlaps "./src/x.py:5"   "src/x.py:5"      || { echo "FAIL: ./ normalize"    >&2; exit 1; }
cw_consult_citation_overlaps "src/x.py"       "src/x.py:5"      || { echo "FAIL: path-only ⊇ line">&2; exit 1; }
cw_consult_citation_overlaps "src/x.py:5"     "src/y.py:5"      && { echo "FAIL: paths differ"    >&2; exit 1; }
cw_consult_citation_overlaps "src/x.py:5-10"  "src/x.py:11-20"  && { echo "FAIL: disjoint ranges" >&2; exit 1; }
cw_consult_citation_overlaps "https://a/b"    "https://a/b"     || { echo "FAIL: same URL"        >&2; exit 1; }
cw_consult_citation_overlaps "https://a/b"    "https://a/c"     && { echo "FAIL: diff URLs"       >&2; exit 1; }
cw_consult_citation_overlaps "src/x.py:5"     "https://a/x"     && { echo "FAIL: file vs URL"     >&2; exit 1; }
cw_consult_citation_overlaps "runtime: pytest" "runtime: pytest" || { echo "FAIL: same runtime"   >&2; exit 1; }
cw_consult_citation_overlaps "runtime: pytest" "runtime: tox"    && { echo "FAIL: diff runtime"   >&2; exit 1; }
pass "cw_consult_citation_overlaps unit cases"

# === diff bucketing ===
REX="$TMP/rex.md"; CODY="$TMP/cody.md"
cat > "$REX" <<'MD'
# Findings
## Summary
.
## Claims
1. [src/auth/store.py:42] Plaintext storage.
2. [src/auth/refresh.py:15-30] No retry logic.
3. [src/util/log.py:7] Logger leaks tokens.
## Notes
MD
cat > "$CODY" <<'MD'
# Findings
## Summary
.
## Claims
1. [./src/auth/store.py:42] Tokens not encrypted.
2. [src/auth/refresh.py:20] No retry block.
3. [src/oauth/callback.py:88] State unvalidated.
## Notes
MD

OUT="$TMP/diff.md"
cw_consult_diff "$REX" "$CODY" "$OUT"

grep -q '^## Agreed'    "$OUT" || { echo "FAIL: missing Agreed"    >&2; exit 1; }
grep -q '^## Rex-only'  "$OUT" || { echo "FAIL: missing Rex-only"  >&2; exit 1; }
grep -q '^## Cody-only' "$OUT" || { echo "FAIL: missing Cody-only" >&2; exit 1; }

# Both store.py:42 (./ normalized) AND refresh.py:15-30 vs :20 (range-overlap)
# bucket as Agreed. That's 2 agreed pairs.
agreed_n=$(awk '/^## Agreed/{f=1;next} /^## /{f=0} f && /^- /{n++} END{print n+0}' "$OUT")
[[ "$agreed_n" -eq 2 ]] || { echo "FAIL: expected 2 agreed, got $agreed_n" >&2; cat "$OUT" >&2; exit 1; }
pass "Agreed bucket includes ./ normalization + range overlap"

# Rex-only: log.py only.
rex_n=$(awk '/^## Rex-only/{f=1;next} /^## /{f=0} f && /^- /{n++} END{print n+0}' "$OUT")
[[ "$rex_n" -eq 1 ]] || { echo "FAIL: expected 1 rex-only, got $rex_n" >&2; cat "$OUT" >&2; exit 1; }
grep -q 'src/util/log.py:7' "$OUT" || { echo "FAIL: log.py not in Rex-only" >&2; exit 1; }
pass "Rex-only correctly identifies disjoint claim"

# Cody-only: callback.py.
cody_n=$(awk '/^## Cody-only/{f=1;next} /^## /{f=0} f && /^- /{n++} END{print n+0}' "$OUT")
[[ "$cody_n" -eq 1 ]] || { echo "FAIL: expected 1 cody-only, got $cody_n" >&2; cat "$OUT" >&2; exit 1; }
pass "Cody-only correctly identifies disjoint claim"

# Empty inputs still emit all three sections.
echo '# x' > "$TMP/e1.md"; echo '# x' > "$TMP/e2.md"
cw_consult_diff "$TMP/e1.md" "$TMP/e2.md" "$TMP/d2.md"
grep -q '^## Agreed' "$TMP/d2.md"
grep -q '^## Rex-only' "$TMP/d2.md"
grep -q '^## Cody-only' "$TMP/d2.md"
pass "empty inputs still emit all three section headers"
```

- [ ] **Step 2: Run, expect failure**

```bash
bash tests/run.sh test_consult_diff.sh
```

- [ ] **Step 3: Implement**

Append to `lib/consult.sh`:

```bash
# cw_consult_citation_overlaps <a> <b>
# Return 0 if two citations agree (cite the same logical source). Match rules
# (per spec):
#   File:  same path (after `./` strip) AND line ranges overlap (treat
#          single-line as Lo=Hi=N; treat path-only as covering all lines).
#   URL:   identical strings (after trim).
#   runtime: identical strings (after trim, includes `runtime:` prefix).
#   File vs URL/runtime: never overlap.
cw_consult_citation_overlaps() {
  local a="$1" b="$2"
  # Strip leading ./
  a="${a#./}"; b="${b#./}"
  # URL?
  if [[ "$a" == http* || "$b" == http* ]]; then
    [[ "$a" == "$b" ]]
    return $?
  fi
  # runtime?
  if [[ "$a" == runtime:* || "$b" == runtime:* ]]; then
    [[ "$a" == "$b" ]]
    return $?
  fi
  # Both are file citations.
  local a_path b_path a_lines b_lines
  a_path="${a%%:*}"; b_path="${b%%:*}"
  [[ "$a_path" == "$b_path" ]] || return 1
  if [[ "$a" == *:* ]]; then a_lines="${a#*:}"; else a_lines=""; fi
  if [[ "$b" == *:* ]]; then b_lines="${b#*:}"; else b_lines=""; fi
  # Path-only on either side covers all lines → overlap by default.
  [[ -z "$a_lines" || -z "$b_lines" ]] && return 0
  local a1 a2 b1 b2
  if [[ "$a_lines" == *-* ]]; then a1="${a_lines%-*}"; a2="${a_lines#*-}"; else a1="$a_lines"; a2="$a_lines"; fi
  if [[ "$b_lines" == *-* ]]; then b1="${b_lines%-*}"; b2="${b_lines#*-}"; else b1="$b_lines"; b2="$b_lines"; fi
  # Bail out on non-numeric (defensive).
  [[ "$a1$a2$b1$b2" =~ ^[0-9]+$ ]] || return 1
  (( a1 <= b2 && b1 <= a2 ))
}

# cw_consult_diff <rex-findings> <cody-findings> <out-path>
# Bucket claims via cw_consult_citation_overlaps. Output format (always 3 sections):
#   ## Agreed
#   - [<rex-cite>] <rex-text> | <cody-text>
#   ## Rex-only
#   - [<rex-cite>] <rex-text>
#   ## Cody-only
#   - [<cody-cite>] <cody-text>
cw_consult_diff() {
  local rex="$1" cody="$2" out="$3"
  local -a rex_cites=() rex_texts=() cody_cites=() cody_texts=() rex_matched=() cody_matched=()
  local cite text
  while IFS=$'\t' read -r cite text; do
    rex_cites+=("$cite");   rex_texts+=("$text");   rex_matched+=(0)
  done < <(cw_consult_parse_claims "$rex")
  while IFS=$'\t' read -r cite text; do
    cody_cites+=("$cite");  cody_texts+=("$text");  cody_matched+=(0)
  done < <(cw_consult_parse_claims "$cody")

  local n_rex="${#rex_cites[@]}" n_cody="${#cody_cites[@]}"
  local i j
  for ((i = 0; i < n_rex; i++)); do
    for ((j = 0; j < n_cody; j++)); do
      [[ "${cody_matched[$j]}" -eq 1 ]] && continue
      if cw_consult_citation_overlaps "${rex_cites[$i]}" "${cody_cites[$j]}"; then
        rex_matched[$i]=1
        cody_matched[$j]=1
        break
      fi
    done
  done

  {
    printf '## Agreed\n'
    for ((i = 0; i < n_rex; i++)); do
      [[ "${rex_matched[$i]}" -eq 1 ]] || continue
      for ((j = 0; j < n_cody; j++)); do
        if cw_consult_citation_overlaps "${rex_cites[$i]}" "${cody_cites[$j]}"; then
          printf -- '- [%s] %s | %s\n' "${rex_cites[$i]}" "${rex_texts[$i]}" "${cody_texts[$j]}"
          break
        fi
      done
    done
    printf '\n## Rex-only\n'
    for ((i = 0; i < n_rex; i++)); do
      [[ "${rex_matched[$i]}" -eq 0 ]] || continue
      printf -- '- [%s] %s\n' "${rex_cites[$i]}" "${rex_texts[$i]}"
    done
    printf '\n## Cody-only\n'
    for ((j = 0; j < n_cody; j++)); do
      [[ "${cody_matched[$j]}" -eq 0 ]] || continue
      printf -- '- [%s] %s\n' "${cody_cites[$j]}" "${cody_texts[$j]}"
    done
  } > "$out"
}
```

- [ ] **Step 4: Run, expect pass**

```bash
bash tests/run.sh
```

- [ ] **Step 5: Commit**

```bash
git add lib/consult.sh tests/test_consult_diff.sh
git commit -m "feat(consult): citation-overlap matcher + overlap-aware diff

Replaces byte-identical string match with the spec-required overlap
semantics: ./-prefix normalization, line ranges (single-line = [N,N]),
path-only = full file, URL/runtime = exact string. Closes Codex
finding #2."
```

---

### Task 7: Verify-prompt builder + verdict parser

**Files:** modify `lib/consult.sh`; create `tests/test_consult_prompts.sh`.

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# tests/test_consult_prompts.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/state.sh
source ../lib/ipc.sh
source ../lib/consult.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

ITEMS="$TMP/items.txt"
cat > "$ITEMS" <<'EOF'
[src/auth/refresh.py:15-30] No retry logic.
[src/oauth/callback.py:88] State unvalidated.
EOF

PROMPT=$(cw_consult_build_verify_prompt "$ITEMS" "/state/verify.md")
echo "$PROMPT" | grep -q 'END_OF_INSTRUCTION$'      || { echo "FAIL: sentinel"; exit 1; }
echo "$PROMPT" | grep -q 'AGREE / DISPUTE / UNCERTAIN' || { echo "FAIL: tags"; exit 1; }
echo "$PROMPT" | grep -q '/state/verify.md'         || { echo "FAIL: path"; exit 1; }
pass "verify prompt has sentinel, tags, output path"

VERIFY="$TMP/v.md"
cat > "$VERIFY" <<'MD'
# Verify
## Verdicts
1. AGREE [src/auth/refresh.py:15-30] No retry logic.
   src/auth/refresh.py:25 — no except RetryError block
2. DISPUTE [src/oauth/callback.py:88] State unvalidated.
   actually reads from session at line 88
3. UNCERTAIN [src/util/x.py:10] Some claim.
   no test reproduces this
MD

mapfile -t V < <(cw_consult_parse_verdicts "$VERIFY")
[[ "${#V[@]}" -eq 3 ]] || { echo "FAIL: 3 verdicts" >&2; exit 1; }
IFS=$'\t' read -r tag cite text <<< "${V[0]}"; assert_eq "$tag" "AGREE" "v1 tag"
IFS=$'\t' read -r tag cite text <<< "${V[1]}"; assert_eq "$tag" "DISPUTE" "v2 tag"
IFS=$'\t' read -r tag cite text <<< "${V[2]}"; assert_eq "$tag" "UNCERTAIN" "v3 tag"
pass "all three tags recognized"

cat > "$VERIFY" <<'MD'
# Verify
## Verdicts
1. UNKNOWN [src/x.py:1] Garbled.
2. AGREE [src/y.py:5] Real.
MD
mapfile -t V < <(cw_consult_parse_verdicts "$VERIFY")
[[ "${#V[@]}" -eq 1 ]] || { echo "FAIL: unknown tag should be filtered"; exit 1; }
pass "unknown tags filtered"
```

- [ ] **Step 2: Run, expect failure**

```bash
bash tests/run.sh test_consult_prompts.sh
```

- [ ] **Step 3: Implement**

Append to `lib/consult.sh`:

```bash
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

cw_consult_parse_verdicts() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  awk '
    /^## Verdicts/                                            { in_v = 1; next }
    /^## /                                                    { in_v = 0 }
    in_v && /^[0-9]+\. (AGREE|DISPUTE|UNCERTAIN) \[[^]]+\] / {
      sub(/^[0-9]+\. /, "")
      tag = $1
      sub(/^[A-Z]+ /, "")
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
bash tests/run.sh
```

- [ ] **Step 5: Commit**

```bash
git add lib/consult.sh tests/test_consult_prompts.sh
git commit -m "feat(consult): verify-prompt builder + verdict parser"
```

---

### Task 8: Research-prompt builder

**Files:** modify `lib/consult.sh`; extend `tests/test_consult_prompts.sh`.

- [ ] **Step 1: Append failing test**

```bash
PROMPT=$(cw_consult_build_research_prompt "review src/auth for token edge cases" "/state/findings.md")
echo "$PROMPT" | grep -q 'review src/auth for token edge cases' || { echo "FAIL: topic"; exit 1; }
echo "$PROMPT" | grep -q '/state/findings.md'  || { echo "FAIL: path"; exit 1; }
echo "$PROMPT" | grep -q '## Claims'            || { echo "FAIL: format anchor"; exit 1; }
echo "$PROMPT" | grep -q 'END_OF_INSTRUCTION$' || { echo "FAIL: sentinel"; exit 1; }
pass "research prompt complete"
```

- [ ] **Step 2: Run, expect failure**

```bash
bash tests/run.sh test_consult_prompts.sh
```

- [ ] **Step 3: Implement**

Append to `lib/consult.sh`:

```bash
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
will be silently dropped by the conductor — and if NO claim has a
citation, your findings will be flagged as malformed in the report.

Then emit {"event":"done", "summary":"researched $topic", "ts":"<iso>"} to your outbox.

END_OF_INSTRUCTION
EOF
}
```

- [ ] **Step 4: Run, expect pass**

```bash
bash tests/run.sh
```

- [ ] **Step 5: Commit**

```bash
git add lib/consult.sh tests/test_consult_prompts.sh
git commit -m "feat(consult): research-prompt builder"
```

---

### Task 9: Synthesis assembler with NOT_VERIFIED + degraded banners

**Why:** Spec failure modes require NOT_VERIFIED tagging when a side's verify call failed (Codex finding #4) and a degraded banner when a side's findings.md was malformed/missing (Codex finding #5).

**Files:** modify `lib/consult.sh`; create `tests/test_consult_synthesis.sh`.

- [ ] **Step 1: Failing test**

```bash
#!/usr/bin/env bash
# tests/test_consult_synthesis.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/state.sh
source ../lib/ipc.sh
source ../lib/consult.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

DIFF="$TMP/diff.md"
cat > "$DIFF" <<'MD'
## Agreed
- [src/auth/store.py:42] Plaintext. | Not encrypted.

## Rex-only
- [src/auth/refresh.py:15-30] No retry.

## Cody-only
- [src/oauth/callback.py:88] State unvalidated.
MD

ADJ="$TMP/adj.md"
cat > "$ADJ" <<'MD'
## Cross-verified
- [src/auth/refresh.py:15-30] No retry. — CODY confirmed (refresh.py:25)

## Adjudicated
- CONFIRMED: [src/oauth/callback.py:88] State unvalidated. — REX disputed; conductor verdict: callback.py:88 reads from request

## Contested

## Not-verified
- [src/util/log.py:7] Logger leaks tokens. — CODY did not respond
MD

OUT="$TMP/syn.md"
cw_consult_synthesize "review auth" "$DIFF" "$ADJ" \
  "/state/rex" "/state/cody" \
  "ok" "ok" \
  "ok" "timeout" \
  "$OUT"

# Title + 6 sections (added Not-verified).
grep -q '^# Consultation: review auth'    "$OUT" || { echo "FAIL: title";        exit 1; }
grep -q '^## Agreed findings'             "$OUT" || { echo "FAIL: agreed";       exit 1; }
grep -q '^## Cross-verified'              "$OUT" || { echo "FAIL: cross";        exit 1; }
grep -q '^## Adjudicated'                 "$OUT" || { echo "FAIL: adjudicated";  exit 1; }
grep -q '^## Contested'                   "$OUT" || { echo "FAIL: contested";    exit 1; }
grep -q '^## Not-verified'                "$OUT" || { echo "FAIL: not-verified"; exit 1; }
grep -q '^## Trooper artifacts'           "$OUT" || { echo "FAIL: artifacts";    exit 1; }
pass "synthesis has all 6 sections"

# Banner appears: cody verify timed out.
grep -q '^> .*verify.*partial' "$OUT" || { echo "FAIL: missing partial-verify banner" >&2; cat "$OUT" >&2; exit 1; }
pass "partial-verify banner present"

# All-good case: no banners.
cw_consult_synthesize "review auth" "$DIFF" "$ADJ" \
  "/state/rex" "/state/cody" "ok" "ok" "ok" "ok" "$TMP/syn2.md"
grep -q '^> ' "$TMP/syn2.md" && { echo "FAIL: unexpected banner in clean run" >&2; exit 1; }
pass "clean run has no banner"

# Findings malformed for one side → degraded banner.
cw_consult_synthesize "review auth" "$DIFF" "$ADJ" \
  "/state/rex" "/state/cody" "malformed" "ok" "ok" "ok" "$TMP/syn3.md"
grep -q '^> .*REX.*malformed' "$TMP/syn3.md" || { echo "FAIL: missing degraded findings banner" >&2; exit 1; }
pass "degraded findings banner emitted"
```

- [ ] **Step 2: Run, expect failure**

```bash
bash tests/run.sh test_consult_synthesis.sh
```

- [ ] **Step 3: Implement**

Append to `lib/consult.sh`:

```bash
# cw_consult_synthesize <topic> <diff.md> <adjudicated.md> \
#                       <rex-state-dir> <cody-state-dir> \
#                       <rex-findings-status> <cody-findings-status> \
#                       <rex-verify-status>   <cody-verify-status>   <out>
#
# *_findings_status ∈ {ok, empty, malformed, missing}
# *_verify_status   ∈ {ok, empty, missing, timeout, error, send-failed, skipped}
#   skipped = no work was needed (other side had no _ONLY items)
#
# Emits the 6-section synthesis with banners when any status is not ok/skipped.
cw_consult_synthesize() {
  local topic="$1" diff="$2" adj="$3" rex_dir="$4" cody_dir="$5"
  local rex_fs="$6" cody_fs="$7" rex_vs="$8" cody_vs="$9" out="${10}"

  {
    printf '# Consultation: %s\n\n' "$topic"

    # Banners
    case "$rex_fs"  in malformed|missing|empty) printf '> NOTE: REX findings.md %s — diff/synthesis ran on best-effort parse.\n\n' "$rex_fs" ;; esac
    case "$cody_fs" in malformed|missing|empty) printf '> NOTE: CODY findings.md %s — diff/synthesis ran on best-effort parse.\n\n' "$cody_fs" ;; esac
    case "$rex_vs"  in timeout|error|send-failed|missing) printf '> NOTE: REX verify dispatch %s — partial cross-verification; some Cody-only items not graded.\n\n' "$rex_vs" ;; esac
    case "$cody_vs" in timeout|error|send-failed|missing) printf '> NOTE: CODY verify dispatch %s — partial cross-verification; some Rex-only items not graded.\n\n' "$cody_vs" ;; esac

    printf '## Agreed findings (both raised independently)\n'
    awk '/^## Agreed/{f=1;next} /^## /{f=0} f' "$diff"
    printf '\n'

    awk '
      /^## Cross-verified/{f=1; print; next}
      /^## Adjudicated/   {f=1; print; next}
      /^## Contested/     {f=1; print; next}
      /^## Not-verified/  {f=1; print; next}
      /^## /              {f=0}
      f
    ' "$adj"
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
bash tests/run.sh
```

- [ ] **Step 5: Commit**

```bash
git add lib/consult.sh tests/test_consult_synthesis.sh
git commit -m "feat(consult): synthesis with NOT_VERIFIED + degraded banners

Closes Codex findings #4 and #5: NOT_VERIFIED items surface as their
own section, and findings.md status (ok/empty/malformed/missing) +
verify dispatch status (ok/timeout/error/send-failed) drive banner
emission per side."
```

---

### Task 10: `bin/send.sh` `@file` regression test

**Files:** create `tests/test_send_at_file.sh`.

- [ ] **Step 1: Write the test**

```bash
#!/usr/bin/env bash
# tests/test_send_at_file.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

grep -q 'MSG_OR_FILE.*@\*'             ../bin/send.sh \
  || { echo "FAIL: @-prefix detection lost" >&2; exit 1; }
grep -q 'TASK="\$(cat "\$task_file")"' ../bin/send.sh \
  || { echo "FAIL: @file body load lost" >&2; exit 1; }
pass "send.sh keeps @file branch wired"

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
[[ "${#TOK[@]}" -eq 3 ]] || { echo "FAIL: 3 tokens" >&2; exit 1; }
assert_eq "${TOK[2]}" "@/tmp/some prompt with spaces.md" "@-path token preserved"
pass "args-file preserves @path-with-spaces as a single token"
```

- [ ] **Step 2: Run, expect pass (functionality already exists)**

```bash
bash tests/run.sh test_send_at_file.sh && bash tests/run.sh
```

- [ ] **Step 3: Commit**

```bash
git add tests/test_send_at_file.sh
git commit -m "test(send): regression guard for @file argument flow"
```

---

### Task 11: `bin/consult.sh` skeleton — slug cap to 20 chars

**Why:** Codex finding #1 — `bin/spawn.sh` rejects topics >32 chars; `consult-` (8) + base slug + `-NN` conflict suffix must fit. Cap base slug to 20; cap conflict suffix to `-999` (4 chars). 8 + 20 + 4 = 32 exactly.

**Files:** create `bin/consult.sh`; create `tests/test_consult_slug.sh`.

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# tests/test_consult_slug.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

# bin/consult.sh prints the resolved consult topic before spawning, so we can
# capture and validate it without running tmux. Use a sentinel env var to make
# consult.sh print-then-exit before the spawn step.
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"
export CW_CONSULT_DRY_RUN=1   # consult.sh: print topic and exit 0

# Long topic — base slug must be cropped to 20 chars.
out=$(../bin/consult.sh "review the authentication middleware for token-refresh edge cases and rate-limiting issues")
slug=$(echo "$out" | awk -F': ' '/consultation topic:/{print $NF}')
[[ ${#slug} -le 32 ]] || { echo "FAIL: slug $slug = ${#slug} chars > 32" >&2; exit 1; }
[[ "$slug" == consult-* ]] || { echo "FAIL: slug missing prefix: $slug" >&2; exit 1; }
pass "long topic produces ≤32-char consult-<slug>"

# All-uppercase, mixed punctuation.
out=$(../bin/consult.sh "REVIEW @ AUTH: TOKEN!?")
slug=$(echo "$out" | awk -F': ' '/consultation topic:/{print $NF}')
[[ "$slug" =~ ^consult-[a-z0-9-]+$ ]] || { echo "FAIL: bad chars in slug: $slug" >&2; exit 1; }
pass "uppercase + punctuation normalized"

# Conflict resolver bumps n. Pre-create a few directories.
RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
DIR_BASE="$CLONE_WARS_HOME/state/$RH"
mkdir -p "$DIR_BASE/consult-foo"
mkdir -p "$DIR_BASE/consult-foo-2"
out=$(../bin/consult.sh "foo")
slug=$(echo "$out" | awk -F': ' '/consultation topic:/{print $NF}')
assert_eq "$slug" "consult-foo-3" "third consult on same slug bumps to -3"
pass "conflict resolver"

# Conflict resolver gives up at 999.
for n in {3..999}; do mkdir -p "$DIR_BASE/consult-foo-$n"; done
out=$(../bin/consult.sh "foo" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: 999 conflicts should fail" >&2; exit 1; }
pass "conflict resolver bounded at 999"

# Empty slug rejected.
out=$(../bin/consult.sh "@@@@@" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'empty slug' \
  || { echo "FAIL: empty slug should be rejected" >&2; exit 1; }
pass "empty slug rejected"
```

- [ ] **Step 2: Run, expect failure**

```bash
bash tests/run.sh test_consult_slug.sh
```

- [ ] **Step 3: Create `bin/consult.sh`**

```bash
#!/usr/bin/env bash
# bin/consult.sh — orchestrate /clone-wars:consult Phases 1-5.
# Writes adjudicated.md with PENDING items; the slash directive drives the
# conductor through PENDING resolution; bin/consult-finalize.sh handles 6-7.

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

# ---------------------------------------------------------- Slug derivation
# Cap base slug to 20 chars so consult-<base>-NNN ≤ 32 (spawn.sh's limit).
SLUG_BASE=$(printf '%s' "$TOPIC_TEXT" \
  | tr '[:upper:]' '[:lower:]' \
  | tr -c 'a-z0-9-' '-' \
  | sed 's/--*/-/g; s/^-//; s/-$//' \
  | cut -c1-20)
[[ -n "$SLUG_BASE" ]] || { log_error "topic produced empty slug; provide alphanumerics"; exit 2; }

CONSULT_TOPIC="consult-$SLUG_BASE"
TOPIC_DIR="$(cw_state_root)/state/$(cw_repo_hash)/$CONSULT_TOPIC"
n=2
while [[ -d "$TOPIC_DIR" ]]; do
  if (( n > 999 )); then
    log_error "more than 999 prior consults on slug '$SLUG_BASE'; pick a different topic"
    exit 1
  fi
  CONSULT_TOPIC="consult-$SLUG_BASE-$n"
  TOPIC_DIR="$(cw_state_root)/state/$(cw_repo_hash)/$CONSULT_TOPIC"
  n=$((n + 1))
done

mkdir -p "$TOPIC_DIR/_consult"
ART_DIR="$TOPIC_DIR/_consult"
# Save topic text for finalize to recover later.
printf '%s' "$TOPIC_TEXT" > "$ART_DIR/topic.txt"

log_info "consultation topic: $CONSULT_TOPIC"
log_info "  artifacts dir: $ART_DIR"

# Dry-run path (test harness): print and exit before spawning.
if [[ "${CW_CONSULT_DRY_RUN:-0}" == "1" ]]; then
  exit 0
fi

# (Phase 1 spawn + Phases 2-5 in subsequent commits.)
exit 0
```

- [ ] **Step 4: chmod + run**

```bash
chmod +x bin/consult.sh
bash tests/run.sh test_consult_slug.sh
```

- [ ] **Step 5: Full suite**

```bash
bash tests/run.sh
```

- [ ] **Step 6: Commit**

```bash
git add bin/consult.sh tests/test_consult_slug.sh
git commit -m "feat(consult): orchestrator skeleton — slug cap to 20 chars

Closes Codex finding #1: spawn.sh rejects topics >32 chars; cap the
user slug to 20 so consult-<base>-NNN fits exactly. Conflict resolver
bounded at 999 to prevent unbounded looping under pathological input."
```

---

### Task 12: Phase 1 spawn + Phase 2 research dispatch — track per-side dispatch status

**Why:** Codex finding #4 — must distinguish per-side outcomes (success vs send-failed vs done-emitted vs error vs timeout) so synthesis can emit NOT_VERIFIED tags. Phase 2 sets `REX_RESEARCH_STATUS` and `CODY_RESEARCH_STATUS` flags consumed downstream.

**Files:** modify `bin/consult.sh`.

- [ ] **Step 1: Replace the dry-run-and-exit tail in `bin/consult.sh`**

Replace the trailing `exit 0` with:

```bash
# ---------------------------------------------------------- Phase 1 spawn

REX=rex; CODY=cody
log_info "[Phase 1] spawning $REX-codex"
"$PLUGIN_ROOT/bin/spawn.sh" "$REX" codex "$CONSULT_TOPIC" >/dev/null \
  || { log_error "rex spawn failed"; exit 1; }

log_info "[Phase 1] spawning $CODY-claude"
if ! "$PLUGIN_ROOT/bin/spawn.sh" "$CODY" claude "$CONSULT_TOPIC" >/dev/null; then
  log_error "cody spawn failed; tearing down rex"
  "$PLUGIN_ROOT/bin/teardown.sh" "$REX" "$CONSULT_TOPIC" >/dev/null 2>&1 || true
  exit 1
fi
log_ok "both troopers ready"

REX_DIR=$(cw_trooper_dir  "$REX"  codex  "$CONSULT_TOPIC")
CODY_DIR=$(cw_trooper_dir "$CODY" claude "$CONSULT_TOPIC")

# ---------------------------------------------------------- Phase 2 research

log_info "[Phase 2] dispatching research to both troopers"

REX_PROMPT="$ART_DIR/rex_research_prompt.md"
CODY_PROMPT="$ART_DIR/cody_research_prompt.md"
cw_consult_build_research_prompt "$TOPIC_TEXT" "$REX_DIR/findings.md"  > "$REX_PROMPT"
cw_consult_build_research_prompt "$TOPIC_TEXT" "$CODY_DIR/findings.md" > "$CODY_PROMPT"

REX_OUTBOX=$(cw_outbox_path  "$REX"  codex  "$CONSULT_TOPIC")
CODY_OUTBOX=$(cw_outbox_path "$CODY" claude "$CONSULT_TOPIC")
REX_OFFSET=$(stat -c '%s' "$REX_OUTBOX")
CODY_OFFSET=$(stat -c '%s' "$CODY_OUTBOX")

REX_SEND_OK=1; CODY_SEND_OK=1
if ! "$PLUGIN_ROOT/bin/send.sh" "$REX"  "$CONSULT_TOPIC" "@$REX_PROMPT"  >/dev/null; then
  log_error "[Phase 2] rex send failed"
  REX_SEND_OK=0
fi
if ! "$PLUGIN_ROOT/bin/send.sh" "$CODY" "$CONSULT_TOPIC" "@$CODY_PROMPT" >/dev/null; then
  log_error "[Phase 2] cody send failed"
  CODY_SEND_OK=0
fi

if (( REX_SEND_OK == 0 && CODY_SEND_OK == 0 )); then
  log_error "[Phase 2] both research sends failed; tearing down"
  "$PLUGIN_ROOT/bin/teardown.sh" "$CONSULT_TOPIC" >/dev/null 2>&1 || true
  exit 1
fi

# Wait for both done events past their pre-send offsets.
RESEARCH_TIMEOUT=$(cw_consult_timeout research)
log_info "[Phase 2] waiting up to ${RESEARCH_TIMEOUT}s for both done events"

cat > "$ART_DIR/wait_research.txt" <<EOF
$REX:codex:$CONSULT_TOPIC:$REX_OFFSET
$CODY:claude:$CONSULT_TOPIC:$CODY_OFFSET
EOF

if ! cw_outbox_wait_all "$ART_DIR/wait_research.txt" done error "$RESEARCH_TIMEOUT"; then
  log_error "[Phase 2] timeout or error before both troopers reported done"
  "$PLUGIN_ROOT/bin/teardown.sh" "$CONSULT_TOPIC" >/dev/null 2>&1 || true
  exit 1
fi

REX_FS=$(cw_consult_findings_status  "$REX_DIR/findings.md")
CODY_FS=$(cw_consult_findings_status "$CODY_DIR/findings.md")

if [[ "$REX_FS" == "missing" && "$CODY_FS" == "missing" ]]; then
  log_error "[Phase 2] neither trooper produced findings.md; tearing down"
  "$PLUGIN_ROOT/bin/teardown.sh" "$CONSULT_TOPIC" >/dev/null 2>&1 || true
  exit 1
fi

# Persist statuses for finalize.
cat > "$ART_DIR/research_status.txt" <<EOF
REX_FS=$REX_FS
CODY_FS=$CODY_FS
EOF

log_ok "[Phase 2] research complete (rex=$REX_FS, cody=$CODY_FS)"

# (Phase 3 + 4 + 5 in subsequent commits.)
exit 0
```

- [ ] **Step 2: Static smoke**

```bash
bash -n bin/consult.sh && echo "ok"
bash tests/run.sh
```

- [ ] **Step 3: Commit**

```bash
git add bin/consult.sh
git commit -m "feat(consult): Phase 1 spawn + Phase 2 research with per-side status tracking

Records findings status per trooper (ok/empty/malformed/missing) so
synthesis can emit the spec-required degraded banner. Aborts only
if BOTH troopers fail to produce any findings (single-trooper run
still produces a usable report)."
```

---

### Task 13: Phase 3 diff + Phase 4 verify with per-side dispatch status

**Why:** Codex finding #4 (NOT_VERIFIED) and #5 (verify-skipped propagation). Track `REX_VS` and `CODY_VS` ∈ {ok, skipped, send-failed, timeout, error, missing}; persist to disk for finalize.

**Files:** modify `bin/consult.sh`.

- [ ] **Step 1: Replace the trailing `exit 0` with the Phase 3 + Phase 4 block**

```bash
# ---------------------------------------------------------- Phase 3 diff

log_info "[Phase 3] bucketing claims"
DIFF="$ART_DIR/diff.md"
cw_consult_diff "$REX_DIR/findings.md" "$CODY_DIR/findings.md" "$DIFF"

REX_ONLY="$ART_DIR/rex_only_items.txt"
CODY_ONLY="$ART_DIR/cody_only_items.txt"
awk '/^## Rex-only/{f=1;next}  /^## /{f=0} f && /^- /{ sub(/^- /,""); print }'  "$DIFF" > "$REX_ONLY"
awk '/^## Cody-only/{f=1;next} /^## /{f=0} f && /^- /{ sub(/^- /,""); print }'  "$DIFF" > "$CODY_ONLY"

# ---------------------------------------------------------- Phase 4 verify

REX_VS=skipped; CODY_VS=skipped

if [[ -s "$CODY_ONLY" ]]; then
  REX_VERIFY_PROMPT="$ART_DIR/rex_verify_prompt.md"
  cw_consult_build_verify_prompt "$CODY_ONLY" "$REX_DIR/verify.md" > "$REX_VERIFY_PROMPT"
  REX_OFFSET2=$(stat -c '%s' "$REX_OUTBOX")
  if "$PLUGIN_ROOT/bin/send.sh" "$REX" "$CONSULT_TOPIC" "@$REX_VERIFY_PROMPT" >/dev/null; then
    REX_VS=pending  # provisional; refined after wait
  else
    REX_VS=send-failed
  fi
fi

if [[ -s "$REX_ONLY" ]]; then
  CODY_VERIFY_PROMPT="$ART_DIR/cody_verify_prompt.md"
  cw_consult_build_verify_prompt "$REX_ONLY" "$CODY_DIR/verify.md" > "$CODY_VERIFY_PROMPT"
  CODY_OFFSET2=$(stat -c '%s' "$CODY_OUTBOX")
  if "$PLUGIN_ROOT/bin/send.sh" "$CODY" "$CONSULT_TOPIC" "@$CODY_VERIFY_PROMPT" >/dev/null; then
    CODY_VS=pending
  else
    CODY_VS=send-failed
  fi
fi

# Build wait file ONLY for sides that have a pending dispatch.
> "$ART_DIR/wait_verify.txt"
[[ "$REX_VS"  == pending ]] && echo "$REX:codex:$CONSULT_TOPIC:$REX_OFFSET2"   >> "$ART_DIR/wait_verify.txt"
[[ "$CODY_VS" == pending ]] && echo "$CODY:claude:$CONSULT_TOPIC:$CODY_OFFSET2" >> "$ART_DIR/wait_verify.txt"

if [[ -s "$ART_DIR/wait_verify.txt" ]]; then
  VERIFY_TIMEOUT=$(cw_consult_timeout verify)
  log_info "[Phase 4] waiting up to ${VERIFY_TIMEOUT}s for verify done events"
  if ! cw_outbox_wait_all "$ART_DIR/wait_verify.txt" done error "$VERIFY_TIMEOUT"; then
    log_warn "[Phase 4] one or both verify dispatches timed out — partial cross-verification"
    [[ "$REX_VS"  == pending ]] && [[ ! -s "$REX_DIR/verify.md"  ]] && REX_VS=timeout
    [[ "$CODY_VS" == pending ]] && [[ ! -s "$CODY_DIR/verify.md" ]] && CODY_VS=timeout
  fi
  # Promote pending → ok for sides that produced verify.md.
  [[ "$REX_VS"  == pending ]] && [[ -s "$REX_DIR/verify.md"  ]] && REX_VS=ok
  [[ "$CODY_VS" == pending ]] && [[ -s "$CODY_DIR/verify.md" ]] && CODY_VS=ok
  # Pending without verify.md and not flagged timeout means error or silent miss.
  [[ "$REX_VS"  == pending ]] && REX_VS=missing
  [[ "$CODY_VS" == pending ]] && CODY_VS=missing
else
  log_info "[Phase 4] no cross-verify needed (no Rex-only or Cody-only items)"
fi

cat > "$ART_DIR/verify_status.txt" <<EOF
REX_VS=$REX_VS
CODY_VS=$CODY_VS
EOF

log_ok "[Phase 4] verify status: rex=$REX_VS, cody=$CODY_VS"

# (Phase 5 in next commit.)
exit 0
```

- [ ] **Step 2: Static smoke + suite**

```bash
bash -n bin/consult.sh && bash tests/run.sh
```

- [ ] **Step 3: Commit**

```bash
git add bin/consult.sh
git commit -m "feat(consult): Phase 3 diff + Phase 4 with per-side verify status

Per-side status tracking (ok|skipped|send-failed|timeout|missing)
persists to verify_status.txt for finalize. Verify dispatch is skipped
for any side whose peer has no _ONLY items. Empty wait file short-
circuits the wait_all call entirely."
```

---

### Task 14: Phase 5 — write `adjudicated.md` only; NO synthesis, NO teardown

**Why:** Codex finding #3 — original plan wrote `synthesis.md` BEFORE PENDING resolution and never regenerated it; final report could ship stale. New design: bash writes `adjudicated.md` with PENDING items + NOT_VERIFIED items; conductor resolves PENDINGs in-place; `bin/consult-finalize.sh` (Task 15) does synthesis after resolution. Bash never writes synthesis.md and never tears down here.

**Files:** modify `bin/consult.sh`.

- [ ] **Step 1: Replace the trailing `exit 0` with Phase 5**

```bash
# ---------------------------------------------------------- Phase 5 adjudicate

log_info "[Phase 5] writing adjudicated.md (PENDING resolution is the conductor's job)"

ADJ="$ART_DIR/adjudicated.md"
{
  printf '## Cross-verified\n'
  if [[ -f "$CODY_DIR/verify.md" ]]; then
    cw_consult_parse_verdicts "$CODY_DIR/verify.md" \
      | awk -F'\t' '$1 == "AGREE" { printf "- [%s] %s — CODY confirmed: %s\n", $2, $3, $3 }'
  fi
  if [[ -f "$REX_DIR/verify.md" ]]; then
    cw_consult_parse_verdicts "$REX_DIR/verify.md" \
      | awk -F'\t' '$1 == "AGREE" { printf "- [%s] %s — REX confirmed: %s\n", $2, $3, $3 }'
  fi

  printf '\n## Adjudicated\n'
  printf '<!-- conductor: read each cited source for every "PENDING" line below; rewrite the prefix to CONFIRMED, REFUTED, or move to ## Contested. The synthesis tool refuses to finalize while any PENDING remains. -->\n'
  if [[ -f "$CODY_DIR/verify.md" ]]; then
    cw_consult_parse_verdicts "$CODY_DIR/verify.md" \
      | awk -F'\t' '$1 != "AGREE" { printf "- PENDING: [%s] %s — CODY %s: %s\n", $2, $3, $1, $3 }'
  fi
  if [[ -f "$REX_DIR/verify.md" ]]; then
    cw_consult_parse_verdicts "$REX_DIR/verify.md" \
      | awk -F'\t' '$1 != "AGREE" { printf "- PENDING: [%s] %s — REX %s: %s\n", $2, $3, $1, $3 }'
  fi

  printf '\n## Contested\n'
  printf '<!-- conductor: move CONTESTED items here from Adjudicated. Items in this section ship in synthesis as unresolved. -->\n'

  printf '\n## Not-verified\n'
  # If REX_VS != ok and CODY_ONLY had items, list them here (rex was supposed to verify them).
  if [[ "$REX_VS" != "ok" && "$REX_VS" != "skipped" && -s "$CODY_ONLY" ]]; then
    awk '{ printf "- %s — REX verify dispatch %s\n", $0, ENVIRON["REX_VS"] }' "$CODY_ONLY"
  fi
  if [[ "$CODY_VS" != "ok" && "$CODY_VS" != "skipped" && -s "$REX_ONLY" ]]; then
    awk '{ printf "- %s — CODY verify dispatch %s\n", $0, ENVIRON["CODY_VS"] }' "$REX_ONLY"
  fi
} > "$ADJ"

cat <<EOF

============================================================
  CONSULTATION DRAFT (Phases 1-5 complete)
============================================================
  topic:         $CONSULT_TOPIC ($TOPIC_TEXT)
  rex findings:  $REX_DIR/findings.md           ($REX_FS)
  cody findings: $CODY_DIR/findings.md          ($CODY_FS)
  diff:          $DIFF
  adjudicated:   $ADJ                            (has PENDING items)
  rex verify:    $REX_DIR/verify.md             ($REX_VS)
  cody verify:   $CODY_DIR/verify.md            ($CODY_VS)

  NEXT — conductor responsibility:
    1. Open $ADJ.
    2. For each "- PENDING:" line, read the cited source and rewrite the
       PENDING prefix to CONFIRMED or REFUTED with one-line evidence,
       OR move the line into ## Contested if you can't decide.
    3. Run: $PLUGIN_ROOT/bin/consult-finalize.sh "$CONSULT_TOPIC"
       (this synthesizes the final report, tears down the panes, and
       archives _consult/ alongside the trooper state).
============================================================

EOF
```

- [ ] **Step 2: Static smoke + suite**

```bash
bash -n bin/consult.sh && bash tests/run.sh
```

- [ ] **Step 3: Commit**

```bash
git add bin/consult.sh
git commit -m "feat(consult): Phase 5 writes adjudicated.md only — no synthesis, no teardown

Closes Codex finding #3: bash never writes the final synthesis.md and
never tears down. Conductor resolves PENDING items in adjudicated.md;
bin/consult-finalize.sh (next commit) does the final synthesis after
resolution. NOT_VERIFIED items appear in their own section so they
can't get silently dropped."
```

---

### Task 15: `bin/consult-finalize.sh` + `_consult/` archive

**Why:** Closes Codex finding #3 (synthesis after resolution) and #6 (`_consult/` archive). The finalize script enforces no-PENDING precondition before writing synthesis.md, calls `bin/teardown.sh` (which archives the trooper dirs), then archives the leftover `_consult/` to `archive/<repo-hash>/<topic>/_consult-<ts>/`.

**Files:** create `bin/consult-finalize.sh`; create `tests/test_consult_finalize.sh`.

- [ ] **Step 1: Failing test**

```bash
#!/usr/bin/env bash
# tests/test_consult_finalize.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

# Build a fake _consult/ subtree that looks like Phase 5's output.
RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
TOPIC=consult-fakeslug
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
ART="$TD/_consult"
mkdir -p "$ART"
mkdir -p "$TD/rex-codex"   "$TD/cody-claude"
echo 'topic text' > "$ART/topic.txt"

cat > "$ART/diff.md" <<'MD'
## Agreed
- [src/x.py:5] Real | Real.
## Rex-only
## Cody-only
MD

# Adjudicated WITH a PENDING item — finalize must refuse.
cat > "$ART/adjudicated.md" <<'MD'
## Cross-verified
## Adjudicated
- PENDING: [src/y.py:10] needs resolution
## Contested
## Not-verified
MD
cat > "$ART/research_status.txt" <<EOF
REX_FS=ok
CODY_FS=ok
EOF
cat > "$ART/verify_status.txt" <<EOF
REX_VS=ok
CODY_VS=ok
EOF

out=$(../bin/consult-finalize.sh "$TOPIC" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'PENDING' \
  || { echo "FAIL: PENDING should block finalize" >&2; exit 1; }
pass "finalize refuses to run with PENDING items"

# Resolve the PENDING and retry. NOTE: skip the actual teardown by setting a
# sentinel that consult-finalize.sh recognizes.
sed -i 's/^- PENDING:.*$/- CONFIRMED: [src\/y.py:10] real claim — verified/' "$ART/adjudicated.md"
export CW_CONSULT_FINALIZE_NO_TEARDOWN=1

out=$(../bin/consult-finalize.sh "$TOPIC" 2>&1) || { echo "FAIL: finalize should succeed: $out" >&2; exit 1; }

# synthesis.md was created.
[[ -f "$CLONE_WARS_HOME/archive/$RH/$TOPIC/_consult-"*"/synthesis.md" ]] \
  || [[ -f "$ART/synthesis.md" ]] \
  || { echo "FAIL: synthesis.md missing" >&2; ls -la "$ART" >&2; exit 1; }
pass "finalize wrote synthesis.md"

# synthesis.md never contains 'PENDING' as an active item.
syn=$(find "$CLONE_WARS_HOME/archive/$RH/$TOPIC" -name synthesis.md 2>/dev/null) || syn="$ART/synthesis.md"
grep -q '^- PENDING:' "$syn" && { echo "FAIL: synthesis still has PENDING" >&2; exit 1; }
pass "synthesis.md is PENDING-free"

# _consult/ has moved to archive/.
arch=$(find "$CLONE_WARS_HOME/archive/$RH/$TOPIC" -maxdepth 1 -type d -name '_consult-*' 2>/dev/null | head -n1)
[[ -n "$arch" ]] || { echo "FAIL: _consult/ not archived" >&2; ls -la "$CLONE_WARS_HOME/archive/$RH/$TOPIC" >&2 || true; exit 1; }
pass "_consult/ archived alongside trooper state"
```

- [ ] **Step 2: Run, expect failure (script doesn't exist yet)**

```bash
bash tests/run.sh test_consult_finalize.sh
```

- [ ] **Step 3: Create `bin/consult-finalize.sh`**

```bash
#!/usr/bin/env bash
# bin/consult-finalize.sh — Phases 6-7 of /clone-wars:consult.
# Reads adjudicated.md (must be PENDING-free), writes synthesis.md, tears
# down the trooper panes via bin/teardown.sh, then archives the _consult/
# sibling dir alongside the (now-archived) trooper state.

set -uo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/consult.sh"

usage() { echo "Usage: $0 <consult-topic>" >&2; }

[[ $# -ge 1 ]] || { usage; exit 2; }
CONSULT_TOPIC="$1"

TOPIC_DIR="$(cw_state_root)/state/$(cw_repo_hash)/$CONSULT_TOPIC"
ART_DIR="$TOPIC_DIR/_consult"

[[ -d "$ART_DIR" ]] || { log_error "$ART_DIR not found — was bin/consult.sh run?"; exit 1; }
ADJ="$ART_DIR/adjudicated.md"
DIFF="$ART_DIR/diff.md"
TOPIC_TEXT_FILE="$ART_DIR/topic.txt"

[[ -f "$ADJ" ]]              || { log_error "adjudicated.md not found"; exit 1; }
[[ -f "$DIFF" ]]             || { log_error "diff.md not found"; exit 1; }
[[ -f "$TOPIC_TEXT_FILE" ]]  || { log_error "topic.txt not found"; exit 1; }

# Refuse to finalize while PENDING items remain.
if grep -q '^- PENDING:' "$ADJ"; then
  log_error "adjudicated.md still has PENDING items — conductor must resolve them first"
  log_error "  open: $ADJ"
  exit 1
fi

# Load statuses (set by Phase 2 / Phase 4).
REX_FS=missing; CODY_FS=missing; REX_VS=skipped; CODY_VS=skipped
# shellcheck disable=SC1090
[[ -f "$ART_DIR/research_status.txt" ]] && source "$ART_DIR/research_status.txt"
# shellcheck disable=SC1090
[[ -f "$ART_DIR/verify_status.txt"   ]] && source "$ART_DIR/verify_status.txt"

TOPIC_TEXT=$(cat "$TOPIC_TEXT_FILE")
REX_DIR=$(cw_trooper_dir  rex  codex  "$CONSULT_TOPIC")
CODY_DIR=$(cw_trooper_dir cody claude "$CONSULT_TOPIC")

SYN="$ART_DIR/synthesis.md"
log_info "[Phase 6] synthesizing report"
cw_consult_synthesize "$TOPIC_TEXT" "$DIFF" "$ADJ" "$REX_DIR" "$CODY_DIR" \
  "$REX_FS" "$CODY_FS" "$REX_VS" "$CODY_VS" "$SYN"

# Print the final synthesis.
cat <<EOF

============================================================
  CONSULTATION REPORT
============================================================
EOF
cat "$SYN"
cat <<EOF
============================================================

EOF

if [[ "${CW_CONSULT_FINALIZE_NO_TEARDOWN:-0}" == "1" ]]; then
  log_info "[Phase 7] CW_CONSULT_FINALIZE_NO_TEARDOWN=1 — archiving _consult/ in place"
  ARCHIVE_BASE="$(cw_state_root)/archive/$(cw_repo_hash)/$CONSULT_TOPIC"
  mkdir -p "$ARCHIVE_BASE"
  TS=$(date -u +'%Y%m%dT%H%M%SZ')
  mv "$ART_DIR" "$ARCHIVE_BASE/_consult-$TS"
  rmdir "$TOPIC_DIR" 2>/dev/null || true
  exit 0
fi

log_info "[Phase 7] tearing down trooper panes"
"$PLUGIN_ROOT/bin/teardown.sh" "$CONSULT_TOPIC" >/dev/null 2>&1 || true

# After teardown, the trooper subdirs are archived by bin/teardown.sh, but
# _consult/ is a sibling that teardown doesn't know about. Move it ourselves
# into the same archive root so the entire consult is one forensic record.
ARCHIVE_BASE="$(cw_state_root)/archive/$(cw_repo_hash)/$CONSULT_TOPIC"
if [[ -d "$ART_DIR" ]]; then
  mkdir -p "$ARCHIVE_BASE"
  TS=$(date -u +'%Y%m%dT%H%M%SZ')
  mv "$ART_DIR" "$ARCHIVE_BASE/_consult-$TS"
  rmdir "$TOPIC_DIR" 2>/dev/null || true
fi
log_ok "consultation $CONSULT_TOPIC complete; archive: $ARCHIVE_BASE"
```

- [ ] **Step 4: chmod + run**

```bash
chmod +x bin/consult-finalize.sh
bash tests/run.sh test_consult_finalize.sh
```

- [ ] **Step 5: Full suite**

```bash
bash tests/run.sh
```

- [ ] **Step 6: Commit**

```bash
git add bin/consult-finalize.sh tests/test_consult_finalize.sh
git commit -m "feat(consult): bin/consult-finalize.sh + _consult/ archive

Closes Codex findings #3 (synthesis written AFTER PENDING resolution
with explicit guard) and #6 (_consult/ archives alongside trooper
state for a single forensic record).

The script refuses to run while adjudicated.md still has PENDING
items — synthesis.md can never ship stale draft content."
```

---

### Task 16: Slash directive — drives conductor through resolve → finalize

**Why:** Closes Codex finding #3 (textual instruction reliability). The slash directive is the load-bearing contract: it tells the conductor explicitly to (1) run consult.sh, (2) read adjudicated.md and resolve every PENDING in-place via Edit, (3) run consult-finalize.sh which enforces the no-PENDING precondition.

**Files:** create `commands/consult.md`.

- [ ] **Step 1: Create the directive**

```markdown
---
description: Spawn rex+codex and cody+claude on a topic; cross-verify their findings; synthesize a final report
argument-hint: <topic — what to research>
---

# /clone-wars:consult

Run a cross-verified dual-model investigation on `$ARGUMENTS`. The conductor
spawns one codex pane (`rex`) and one claude pane (`cody`), dispatches an
independent research task to each, diffs their findings via citation overlap,
dispatches each side's unique claims to the OTHER trooper for AGREE / DISPUTE /
UNCERTAIN verification (using the SAME pane — TUI memory carries between
calls), then makes the conductor adjudicate disputed items by reading the
cited sources directly.

Both panes stay attached for the entire run — `tmux select-pane` to watch.

Spec: `docs/superpowers/specs/2026-04-28-clone-wars-consult-design.md`

## Steps

The user's `$ARGUMENTS` may contain shell metacharacters. Write it via the
Write tool, then invoke the bin script with `--args-file`.

1. Use the Bash tool to resolve the args-file path:

   ```
   ARGS_DIR="${CLONE_WARS_HOME:-$HOME/.clone-wars}/_args"
   mkdir -p "$ARGS_DIR"
   echo "$ARGS_DIR/consult.txt"
   ```

2. Use the Write tool to put `$ARGUMENTS` into that path:

   - `file_path`: the absolute path printed by step 1
   - `content`: the literal value of `$ARGUMENTS`

3. Use the Bash tool to run consult Phases 1–5:

   ```
   "$CLAUDE_PLUGIN_ROOT/bin/consult.sh" --args-file "$ARGS_DIR/consult.txt"
   ```

   The script ends by printing the path to `adjudicated.md` and the path to
   `bin/consult-finalize.sh`. **Do not finalize yet.**

4. **CONDUCTOR RESPONSIBILITY — resolve PENDING items before finalizing.**

   Open the printed `adjudicated.md` with the Read tool. For every line that
   begins with `- PENDING:`:

   a. Note the citation in `[brackets]` and the original claim.
   b. Open the cited source (file at the path, or fetch the URL via WebFetch).
   c. Decide:
      - **CONFIRMED** — the original claim is correct.
      - **REFUTED**   — the original claim is wrong.
      - **CONTESTED** — the source is genuinely ambiguous.
   d. Use the Edit tool to rewrite the line:
      - For CONFIRMED / REFUTED: replace `- PENDING:` with `- CONFIRMED:` or
        `- REFUTED:`, append a one-line evidence note (the file:line or quote
        you read).
      - For CONTESTED: move the entire line under `## Contested` and drop the
        `PENDING:` prefix.

   When done, no `^- PENDING:` line should remain.

5. Use the Bash tool to finalize:

   ```
   "$CLAUDE_PLUGIN_ROOT/bin/consult-finalize.sh" <consult-topic>
   ```

   Replace `<consult-topic>` with the topic the previous output printed (e.g.
   `consult-review-auth`). The script will refuse to run if any `^- PENDING:`
   line remains — that's the enforcement gate that prevents shipping a stale
   report.

6. Show the user the final synthesis (already printed by the finalize script).
   Do NOT show the draft from step 3 as the final answer; the user only sees
   the synthesis from step 5.

## What the user should expect

Two tmux panes spawn, do their research, swap verify items, then teardown.
The conductor (you) does the source-reading adjudication step in step 4.
End-to-end this takes 10–20 minutes for a non-trivial topic; longer for
complex ones (default research timeout is 600s per side).
```

- [ ] **Step 2: Full suite**

```bash
bash tests/run.sh
```

- [ ] **Step 3: Commit**

```bash
git add commands/consult.md
git commit -m "feat(commands): /clone-wars:consult slash directive — resolve→finalize loop

Closes Codex finding #3 (textual instruction reliability): the
directive walks the conductor through consult.sh → resolve every
PENDING via Edit → consult-finalize.sh. Finalize enforces the
no-PENDING precondition so a skipped resolve step fails loud, not
silent."
```

---

### Task 17: README + version bump to v0.1.0

**Files:** modify `README.md`, `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`.

- [ ] **Step 1: Add the consult section to README.md**

Insert after the existing `## Commands` table:

```markdown
---

## Orchestration: `/clone-wars:consult`

`/clone-wars:consult <topic>` is the first orchestration command on top of the
spawn/send/collect/teardown primitives. Use it for cross-verified research:

1. The conductor spawns `rex (codex)` and `cody (claude)` on a fresh topic.
2. Both research independently, writing structured `findings.md`.
3. The conductor diffs the findings via citation overlap (path normalization,
   line-range intersection, URL exact match).
4. Each side's unique claims dispatch back to the OTHER trooper for AGREE /
   DISPUTE / UNCERTAIN verification — using the SAME pane (codex and claude
   TUIs preserve in-session memory across the two calls).
5. The conductor adjudicates disputed items by reading the cited sources
   directly, then synthesizes a six-section report (Agreed / Cross-verified /
   Adjudicated / Contested / Not-verified / Trooper artifacts).

```
/clone-wars:consult "review src/auth/oauth.py for token-refresh edge cases"
```

The full spec is at `docs/superpowers/specs/2026-04-28-clone-wars-consult-design.md`.

---
```

- [ ] **Step 2: Bump versions**

In `.claude-plugin/plugin.json`:
```json
"version": "0.1.0",
```

In `.claude-plugin/marketplace.json` (TWO occurrences — top-level + plugins array):
```json
"version": "0.1.0",
```

- [ ] **Step 3: Full suite + medic + dogfood**

```bash
bash tests/run.sh
bash bin/medic.sh
# Live dogfood (manual):
# /clone-wars:consult "review tests/test_consult_diff.sh for edge cases"
```

- [ ] **Step 4: Commit**

```bash
git add README.md .claude-plugin/plugin.json .claude-plugin/marketplace.json
git commit -m "release: v0.1.0 — /clone-wars:consult cross-verified dual-model research"
```

---

## Self-review (post-revision)

**1. Spec coverage.** All 7 spec sections + 5 prereqs map to tasks; degraded paths (P3 #4, #5) and failure modes (P3 #6) close in Tasks 9, 13, 14, 15.

**2. Codex finding closure.**
- #1 slug-length spawn fail → Task 11 caps base slug to 20 + 999 conflict bound
- #2 byte-equality diff → Task 6 citation-overlap matcher
- #3 PENDING handoff stale draft → Task 14 (no synthesis, no teardown) + Task 15 (no-PENDING precondition) + Task 16 (slash directive walks conductor through Edit step)
- #4 NOT_VERIFIED dropped → Tasks 13 (per-side verify status) + 9 (Not-verified section + banner) + 14 (writes Not-verified section)
- #5 malformed findings silent → Tasks 5 (`cw_consult_findings_status`) + 9 (degraded banner)
- #6 `_consult/` not archived → Task 15 (post-teardown archive step)

**3. Type consistency end-to-end.**
- claims TSV `<cite>\t<text>` — Task 5 emits, Task 6 consumes
- verdicts TSV `<tag>\t<cite>\t<text>` — Task 7 emits, Tasks 14 + 9 consume
- finding status enum `{ok|empty|malformed|missing}` — Task 5 emits, Tasks 9 + 12 + 15 consume via env file
- verify status enum `{ok|skipped|send-failed|timeout|error|missing}` — Tasks 12 + 13 emit, Tasks 9 + 14 + 15 consume
- `cw_consult_synthesize` 10-arg signature consistent across Tasks 9, 14, 15

**4. Placeholder scan.** No `TBD`, `TODO`, `Similar to Task N`, "implement later", or "add appropriate" patterns. Every step has executable content.

**5. Bisect-safe.** Each task ends with passing tests on a single commit. No task introduces a function used by an earlier task. The orchestrator slices (11→12→13→14) all `exit 0` cleanly between commits, so any commit can be checked out and tests stay green.

---

## Execution

Plan complete. Recommended execution: subagent-driven-development. Tasks 1–10 are mechanical; 11–16 are integration; 17 is release. Codex adversarial-review on the plan was already run and all six findings are closed in this revision.
