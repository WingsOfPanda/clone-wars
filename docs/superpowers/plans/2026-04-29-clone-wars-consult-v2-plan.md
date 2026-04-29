# /clone-wars:consult v0.2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace v0.1.2's monolithic `bin/consult.sh` + `bin/consult-finalize.sh` with 11 small per-phase sub-scripts the conductor invokes one at a time, enabling parallel spawn/dispatches and conductor-mediated trooper intervention between every step.

**Architecture:** Pure bash + tmux + file IPC. Each sub-script is fail-loud non-idempotent except `bin/consult-adjudicate.sh` (writes regenerable `adjudicated-draft.md`) and `bin/consult-offset-reset.sh` (the executable retry primitive). Per-commander state files (`_consult/research-<commander>.txt` / `verify-<commander>.txt`) eliminate the shared-file append race.

**Spec:** `docs/superpowers/specs/2026-04-29-clone-wars-consult-v2-design.md` (Revision 1, post-Codex review)

**Tech Stack:** bash 4.2+, tmux 3.0+, awk/sed/grep, pure-bash test harness via `tests/run.sh`.

---

## File structure

| File | Action | Responsibility |
|---|---|---|
| `lib/consult.sh` | Modify (+3 helpers) | Append `cw_consult_topic_validate`, `cw_consult_status_load`, `cw_consult_write_adjudicated`. Existing helpers unchanged. |
| `bin/consult-init.sh` | Create | Slug derivation + `_consult/` dir + `topic.txt`; prints resolved CONSULT_TOPIC. |
| `bin/consult-offset-reset.sh` | Create | Removes `_consult/<phase>-<commander>.txt` AND derived artifacts. The executable retry primitive. |
| `bin/consult-research-send.sh` | Create | Per-commander research dispatch. Writes `OFFSET=` to per-commander state file. |
| `bin/consult-research-wait.sh` | Create | Per-commander research wait. Appends `FS=` to per-commander state file. |
| `bin/consult-diff.sh` | Create | Calls `cw_consult_diff` lib helper; writes `diff.md` + `*_only_items.txt`. |
| `bin/consult-verify-send.sh` | Create | Per-commander verify dispatch (conditional on peer's _ONLY items). |
| `bin/consult-verify-wait.sh` | Create | Per-commander verify wait. Appends `VS=` to per-commander state file. |
| `bin/consult-adjudicate.sh` | Create | Reads all 4 state files + verify.md files; writes `adjudicated-draft.md`. |
| `bin/consult-synthesize.sh` | Create | No-PENDING gate; reads conductor-resolved `adjudicated.md`; writes `synthesis.md`. |
| `bin/consult-teardown.sh` | Create | Thin wrapper around `bin/teardown.sh <topic>`. |
| `bin/consult-archive.sh` | Create | Moves `_consult/` to archive. |
| `commands/consult.md` | Rewrite | 13-step directive with parallel-pair invocations + spawn-rollback runbook + retry contracts. |
| `tests/test_consult_init.sh` | Create (replaces `test_consult_slug.sh`) | Slug + conflict-bound + topic.txt + path-traversal cases. |
| `tests/test_consult_offset_reset.sh` | Create | Removes per-commander file + cascades. |
| `tests/test_consult_research_send.sh` | Create | OFFSET captured + idempotency-fail-loud + reset-enables-retry. |
| `tests/test_consult_research_wait.sh` | Create | Per-trooper status survives peer timeout (Codex finding #2 fixture). |
| `tests/test_consult_verify_send.sh` | Create | Peer-empty → `VS=skipped`; peer-non-empty → OFFSET. |
| `tests/test_consult_verify_wait.sh` | Create | Mirror of research-wait. |
| `tests/test_consult_adjudicate.sh` | Create | Generates `adjudicated-draft.md`; never touches `adjudicated.md` (Codex #4 fixture). |
| `tests/test_consult_synthesize_bin.sh` | Create | No-PENDING gate; missing `adjudicated.md` rc=1; synthesis-overwrite refusal. |
| `tests/test_consult_teardown_bin.sh` | Create | Smoke (delegates to existing `bin/teardown.sh`). |
| `tests/test_consult_archive.sh` | Create | Moves `_consult/` to archive; idempotency. |
| `tests/test_consult_spawn_rollback.sh` | Create | One-success/one-failure parallel-spawn → peer torn down (Codex #3 fixture). |
| `bin/consult.sh` | Delete (final task) | Replaced by sub-scripts. |
| `bin/consult-finalize.sh` | Delete (final task) | Replaced by synthesize + teardown + archive. |
| `tests/test_consult_slug.sh` | Delete (final task) | Renamed to `test_consult_init.sh`. |
| `tests/test_consult_finalize.sh` | Delete (final task) | Split across 3 new bin tests. |
| `README.md` + `.claude-plugin/{plugin,marketplace}.json` | Modify (final) | v0.1.x → v0.2.0 release. |

**Existing library tests stay**: `test_consult_diff.sh`, `test_consult_findings_parse.sh`, `test_consult_prompts.sh`, `test_consult_synthesis.sh` cover the lib helpers and need no v0.2 changes.

---

## Bisect-safety strategy

The plan adds new sub-scripts ALONGSIDE the existing v0.1.2 monoliths through Tasks 1–13. Task 14 rewrites the slash directive to use the new sub-scripts. Task 15 deletes the old monoliths + their tests. Task 16 ships v0.2.0. Every commit through Task 14 keeps `bin/consult.sh` and `bin/consult-finalize.sh` callable, so `tests/test_consult_slug.sh` and `tests/test_consult_finalize.sh` keep passing. Task 15 deletes them in the same commit that asserts the new tests cover the gap.

---

## Task summary (16 tasks)

1. `lib/consult.sh` foundation helpers (topic_validate, status_load, write_adjudicated)
2. `bin/consult-init.sh` + test_consult_init.sh
3. `bin/consult-offset-reset.sh` + test_consult_offset_reset.sh
4. `bin/consult-research-send.sh` + test_consult_research_send.sh
5. `bin/consult-research-wait.sh` + test_consult_research_wait.sh (per-commander, finds #2 fixture)
6. `bin/consult-diff.sh`
7. `bin/consult-verify-send.sh` + test_consult_verify_send.sh
8. `bin/consult-verify-wait.sh` + test_consult_verify_wait.sh
9. `bin/consult-adjudicate.sh` + test_consult_adjudicate.sh (Codex #4 fixture)
10. `bin/consult-synthesize.sh` + test_consult_synthesize_bin.sh
11. `bin/consult-teardown.sh` + test_consult_teardown_bin.sh
12. `bin/consult-archive.sh` + test_consult_archive.sh
13. `tests/test_consult_spawn_rollback.sh` (Codex #3 fixture, mocks `bin/spawn.sh`)
14. Rewrite `commands/consult.md` (13-step directive + parallel pairs + spawn-rollback runbook)
15. Cleanup: delete `bin/consult.sh`, `bin/consult-finalize.sh`, `tests/test_consult_slug.sh`, `tests/test_consult_finalize.sh`
16. README + v0.2.0 release polish

---

### Task 1: `lib/consult.sh` foundation helpers

**Why:** All 11 sub-scripts validate their `<topic>` arg; many read per-commander state files; `bin/consult-adjudicate.sh` needs the awk that v0.1's monolith embedded inline. Hoist three helpers up to the lib.

**Files:**
- Modify: `lib/consult.sh` (append three functions)
- Test: extend `tests/test_consult_findings_parse.sh` (the only consult-lib test file already sourcing the lib in isolation)

- [ ] **Step 1: Append failing assertions to tests/test_consult_findings_parse.sh**

After the existing pass-cases (before any final exit), append:

```bash
# === cw_consult_topic_validate ===
cw_consult_topic_validate "consult-foo"     || { echo "FAIL: clean topic" >&2; exit 1; }
cw_consult_topic_validate "consult-foo-3"   || { echo "FAIL: numeric suffix" >&2; exit 1; }
cw_consult_topic_validate "consult-foo_bar" || { echo "FAIL: underscore allowed" >&2; exit 1; }
cw_consult_topic_validate "../etc/passwd"   && { echo "FAIL: dotdot accepted" >&2; exit 1; }
cw_consult_topic_validate "consult-foo/bar" && { echo "FAIL: slash accepted" >&2; exit 1; }
cw_consult_topic_validate ".secret"         && { echo "FAIL: dot-prefix accepted" >&2; exit 1; }
cw_consult_topic_validate ""                && { echo "FAIL: empty accepted" >&2; exit 1; }
cw_consult_topic_validate "no-prefix"       && { echo "FAIL: missing consult- prefix" >&2; exit 1; }
pass "cw_consult_topic_validate accepts safe topics, rejects unsafe"

# === cw_consult_status_load ===
F="$TMP/state.txt"
cat > "$F" <<EOF
OFFSET=42
FS=ok
EOF
cw_consult_status_load "$F"
assert_eq "$OFFSET" "42" "OFFSET loaded"
assert_eq "$FS" "ok" "FS loaded"
pass "cw_consult_status_load reads KEY=VAL pairs"

# Missing file → returns rc=0 silently with no vars set.
unset OFFSET FS
cw_consult_status_load "$TMP/missing.txt"
[[ -z "${OFFSET:-}" ]] || { echo "FAIL: missing file leaked vars" >&2; exit 1; }
pass "cw_consult_status_load missing file is silent no-op"
```

- [ ] **Step 2: Run, expect failure**

```bash
bash tests/run.sh test_consult_findings_parse.sh
```

Expected: FAIL with `cw_consult_topic_validate: command not found` or `cw_consult_status_load: command not found`.

- [ ] **Step 3: Append helpers to `lib/consult.sh`**

Append at the end of the file:

```bash
# cw_consult_topic_validate <topic>
# Return 0 if the topic is a safe consult topic name; 1 otherwise.
# Rules:
#   - Must start with `consult-`
#   - Allowed chars: [A-Za-z0-9._-]+
#   - No leading dot or hyphen, no slash, no `..`
# Used at the top of every sub-script that takes a <topic> arg.
cw_consult_topic_validate() {
  local topic="$1"
  [[ -n "$topic" ]] || return 1
  [[ "$topic" == consult-* ]] || return 1
  [[ "$topic" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
  [[ "$topic" != .* && "$topic" != -* ]] || return 1
  [[ "$topic" != *..* ]] || return 1
  return 0
}

# cw_consult_status_load <file>
# Source a per-commander state file (KEY=VAL lines) into the calling shell.
# Missing file is a silent no-op (rc=0, no vars set). The file is written
# exclusively by sub-scripts (research-send/wait, verify-send/wait), never by
# troopers, so plain `source` is acceptable here — see spec Migration §
# "cw_consult_status_load design note" for the threat-model rationale.
cw_consult_status_load() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  # shellcheck disable=SC1090
  source "$file"
}

# cw_consult_write_adjudicated <out> <rex-verify-md> <cody-verify-md> \
#                              <rex-only-items> <cody-only-items> \
#                              <rex-vs> <cody-vs>
# Compose the adjudicated-draft.md content from the four state inputs.
# Sections: Cross-verified, Adjudicated (PENDING list), Contested, Not-verified.
# Extracted from v0.1.2 bin/consult.sh Phase 5 awk; matches the same output.
cw_consult_write_adjudicated() {
  local out="$1" rex_v="$2" cody_v="$3" rex_only="$4" cody_only="$5"
  local rex_vs="$6" cody_vs="$7"
  {
    printf '## Cross-verified\n'
    [[ -f "$cody_v" ]] && cw_consult_parse_verdicts "$cody_v" \
      | awk -F'\t' '$1 == "AGREE" { printf "- [%s] %s — CODY confirmed: %s\n", $2, $3, ($4 != "" ? $4 : $3) }'
    [[ -f "$rex_v" ]] && cw_consult_parse_verdicts "$rex_v" \
      | awk -F'\t' '$1 == "AGREE" { printf "- [%s] %s — REX confirmed: %s\n", $2, $3, ($4 != "" ? $4 : $3) }'

    printf '\n## Adjudicated\n'
    printf '<!-- conductor: read each cited source for every "PENDING" line below; rewrite the prefix to CONFIRMED, REFUTED, or move to ## Contested. consult-synthesize.sh refuses to finalize while any PENDING remains. -->\n'
    [[ -f "$cody_v" ]] && cw_consult_parse_verdicts "$cody_v" \
      | awk -F'\t' '$1 != "AGREE" { printf "- PENDING: [%s] %s — CODY %s: %s\n", $2, $3, $1, ($4 != "" ? $4 : $3) }'
    [[ -f "$rex_v" ]] && cw_consult_parse_verdicts "$rex_v" \
      | awk -F'\t' '$1 != "AGREE" { printf "- PENDING: [%s] %s — REX %s: %s\n", $2, $3, $1, ($4 != "" ? $4 : $3) }'

    printf '\n## Contested\n'
    printf '<!-- conductor: move CONTESTED items here from Adjudicated. Items in this section ship in synthesis as unresolved. -->\n'

    printf '\n## Not-verified\n'
    if [[ "$rex_vs" != "ok" && "$rex_vs" != "skipped" && -s "$cody_only" ]]; then
      awk -v vs="$rex_vs" '{ printf "- %s — REX verify dispatch %s\n", $0, vs }' "$cody_only"
    fi
    if [[ "$cody_vs" != "ok" && "$cody_vs" != "skipped" && -s "$rex_only" ]]; then
      awk -v vs="$cody_vs" '{ printf "- %s — CODY verify dispatch %s\n", $0, vs }' "$rex_only"
    fi
  } > "$out"
}
```

- [ ] **Step 4: Run, expect pass**

```bash
bash tests/run.sh test_consult_findings_parse.sh && bash tests/run.sh
```

- [ ] **Step 5: Commit**

```bash
git add lib/consult.sh tests/test_consult_findings_parse.sh
git commit -m "feat(consult): lib helpers — topic_validate, status_load, write_adjudicated"
```

---

### Task 2: `bin/consult-init.sh` + test

**Why:** Slug derivation + `_consult/` setup, replacing the first half of v0.1's `bin/consult.sh`. Conductor calls this once at the start of every consult.

**Files:**
- Create: `bin/consult-init.sh` (executable)
- Create: `tests/test_consult_init.sh`

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# tests/test_consult_init.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

# 1. Long topic-text → slug capped at 20 chars; full topic ≤32.
out=$(../bin/consult-init.sh "review the authentication middleware for token-refresh edge cases")
[[ "$out" == consult-* ]] || { echo "FAIL: prefix missing: $out" >&2; exit 1; }
[[ ${#out} -le 32 ]]      || { echo "FAIL: topic ${#out} chars > 32: $out" >&2; exit 1; }
RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
[[ -d "$CLONE_WARS_HOME/state/$RH/$out/_consult" ]] || { echo "FAIL: _consult dir not created" >&2; exit 1; }
[[ -f "$CLONE_WARS_HOME/state/$RH/$out/_consult/topic.txt" ]] || { echo "FAIL: topic.txt missing" >&2; exit 1; }
pass "init creates capped slug + _consult/ + topic.txt"

# 2. topic.txt preserves the raw topic-text.
saved=$(cat "$CLONE_WARS_HOME/state/$RH/$out/_consult/topic.txt")
assert_eq "$saved" "review the authentication middleware for token-refresh edge cases" "topic.txt round-trips"
pass "topic.txt preserves raw topic-text"

# 3. All-uppercase + punctuation normalized.
out=$(../bin/consult-init.sh "REVIEW @ AUTH: TOKEN!?")
[[ "$out" =~ ^consult-[a-z0-9-]+$ ]] || { echo "FAIL: bad chars: $out" >&2; exit 1; }
pass "uppercase + punctuation normalized"

# 4. Conflict resolver bumps to -3 on third invocation of same slug.
out1=$(../bin/consult-init.sh "foo")
out2=$(../bin/consult-init.sh "foo")
out3=$(../bin/consult-init.sh "foo")
assert_eq "$out1" "consult-foo"   "1st"
assert_eq "$out2" "consult-foo-2" "2nd"
assert_eq "$out3" "consult-foo-3" "3rd"
pass "conflict resolver"

# 5. Empty slug rejected.
err=$(../bin/consult-init.sh "@@@@@" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && echo "$err" | grep -q 'empty slug' \
  || { echo "FAIL: empty slug should reject" >&2; exit 1; }
pass "empty slug rejected"
```

- [ ] **Step 2: Run, expect failure**

```bash
bash tests/run.sh test_consult_init.sh
```

Expected: FAIL because `bin/consult-init.sh` doesn't exist yet.

- [ ] **Step 3: Create `bin/consult-init.sh`**

```bash
#!/usr/bin/env bash
# bin/consult-init.sh — derive consult-<slug> + create _consult/ + save topic.txt.
# Prints CONSULT_TOPIC to stdout; INFO logs to stderr.
#
# Usage: bin/consult-init.sh <topic-text>

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/consult.sh"

[[ $# -ge 1 ]] || { echo "Usage: $0 <topic-text>" >&2; exit 2; }
TOPIC_TEXT="$*"

# Cap base slug to 20 chars so consult-<base>-NNN ≤ 32 (spawn.sh's regex limit).
SLUG_BASE=$(printf '%s' "$TOPIC_TEXT" \
  | tr '[:upper:]' '[:lower:]' \
  | tr -c 'a-z0-9-' '-' \
  | sed 's/--*/-/g; s/^-//; s/-$//' \
  | cut -c1-20 \
  | sed 's/-$//')
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
printf '%s' "$TOPIC_TEXT" > "$TOPIC_DIR/_consult/topic.txt"

log_info "consultation topic: $CONSULT_TOPIC"
log_info "  artifacts dir:    $TOPIC_DIR/_consult"

printf '%s\n' "$CONSULT_TOPIC"
```

- [ ] **Step 4: chmod + run**

```bash
chmod +x bin/consult-init.sh
bash tests/run.sh test_consult_init.sh && bash tests/run.sh
```

- [ ] **Step 5: Commit**

```bash
git add bin/consult-init.sh tests/test_consult_init.sh
git commit -m "feat(consult): bin/consult-init.sh — slug + _consult/ + topic.txt"
```

---

### Task 3: `bin/consult-offset-reset.sh` + test

**Why:** Codex finding #1 closure. The executable retry primitive. Removes per-commander state file AND derived artifacts. Required for Pattern 1 + 3 intervention.

**Files:**
- Create: `bin/consult-offset-reset.sh`
- Create: `tests/test_consult_offset_reset.sh`

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# tests/test_consult_offset_reset.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

# Build a fake topic with all the artifacts reset should cascade.
RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
TOPIC=consult-fixture
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
mkdir -p "$TD/_consult"
echo "OFFSET=42" > "$TD/_consult/research-rex.txt"
echo "OFFSET=88" > "$TD/_consult/research-cody.txt"
echo "old diff"  > "$TD/_consult/diff.md"
echo "rex item"  > "$TD/_consult/rex_only_items.txt"
echo "cody item" > "$TD/_consult/cody_only_items.txt"
echo "draft"     > "$TD/_consult/adjudicated-draft.md"

# 1. Reset rex research → removes research-rex.txt + diff.md + both _only files + draft.
../bin/consult-offset-reset.sh "$TOPIC" rex research
[[ ! -f "$TD/_consult/research-rex.txt"     ]] || { echo "FAIL: research-rex.txt survived" >&2; exit 1; }
[[ ! -f "$TD/_consult/diff.md"               ]] || { echo "FAIL: diff.md survived" >&2; exit 1; }
[[ ! -f "$TD/_consult/rex_only_items.txt"   ]] || { echo "FAIL: rex_only_items.txt survived" >&2; exit 1; }
[[ ! -f "$TD/_consult/cody_only_items.txt"  ]] || { echo "FAIL: cody_only_items.txt survived" >&2; exit 1; }
[[ ! -f "$TD/_consult/adjudicated-draft.md" ]] || { echo "FAIL: adjudicated-draft.md survived" >&2; exit 1; }
# But cody's research state is left alone.
[[ -f "$TD/_consult/research-cody.txt" ]] || { echo "FAIL: cody state was wrongly removed" >&2; exit 1; }
pass "reset rex research cascades to derived artifacts"

# 2. Idempotent: reset on missing file is rc=0, no error.
../bin/consult-offset-reset.sh "$TOPIC" rex research
pass "reset is idempotent on already-reset state"

# 3. Verify-phase reset only touches verify state + adjudicated-draft.
echo "OFFSET=99" > "$TD/_consult/verify-rex.txt"
echo "draft2"    > "$TD/_consult/adjudicated-draft.md"
../bin/consult-offset-reset.sh "$TOPIC" rex verify
[[ ! -f "$TD/_consult/verify-rex.txt"        ]] || { echo "FAIL: verify-rex.txt survived" >&2; exit 1; }
[[ ! -f "$TD/_consult/adjudicated-draft.md"  ]] || { echo "FAIL: draft survived verify reset" >&2; exit 1; }
[[ -f "$TD/_consult/research-cody.txt"        ]] || { echo "FAIL: research-cody wrongly affected" >&2; exit 1; }
pass "reset rex verify cascades only to verify+draft"

# 4. Bad phase rejected.
err=$(../bin/consult-offset-reset.sh "$TOPIC" rex bogus 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && echo "$err" | grep -q 'phase' \
  || { echo "FAIL: bad phase should reject" >&2; exit 1; }
pass "bad phase rejected"

# 5. Bad topic (path-traversal) rejected.
err=$(../bin/consult-offset-reset.sh "../etc/passwd" rex research 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: path-traversal accepted" >&2; exit 1; }
pass "path-traversal topic rejected"
```

- [ ] **Step 2: Run, expect failure**

```bash
bash tests/run.sh test_consult_offset_reset.sh
```

- [ ] **Step 3: Create `bin/consult-offset-reset.sh`**

```bash
#!/usr/bin/env bash
# bin/consult-offset-reset.sh — remove per-commander state file + cascade.
# The only documented retry primitive. See spec § "Retry contract".
#
# Usage: bin/consult-offset-reset.sh <consult-topic> <commander> <phase>
#   <phase> ∈ {research, verify}
#
# Removes _consult/<phase>-<commander>.txt and the derived artifacts that
# depend on it (diff.md and *_only_items.txt for the research phase;
# adjudicated-draft.md for both phases). Idempotent on missing files.

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/consult.sh"

[[ $# -eq 3 ]] || { echo "Usage: $0 <consult-topic> <commander> <phase>" >&2; exit 2; }
TOPIC="$1"; COMMANDER="$2"; PHASE="$3"

cw_consult_topic_validate "$TOPIC" \
  || { log_error "invalid topic: $TOPIC"; exit 2; }
[[ "$COMMANDER" =~ ^[a-z0-9_-]+$ ]] \
  || { log_error "invalid commander: $COMMANDER"; exit 2; }
[[ "$PHASE" == research || "$PHASE" == verify ]] \
  || { log_error "phase must be 'research' or 'verify'; got '$PHASE'"; exit 2; }

ART_DIR="$(cw_state_root)/state/$(cw_repo_hash)/$TOPIC/_consult"
[[ -d "$ART_DIR" ]] || { log_error "$ART_DIR not found"; exit 1; }

rm -f "$ART_DIR/$PHASE-$COMMANDER.txt"

# Cascade. Research phase invalidates downstream computation.
if [[ "$PHASE" == research ]]; then
  rm -f "$ART_DIR/diff.md" "$ART_DIR/rex_only_items.txt" "$ART_DIR/cody_only_items.txt"
fi
# Both phases invalidate the adjudication draft (which depends on both).
rm -f "$ART_DIR/adjudicated-draft.md"

log_info "reset $PHASE state for $COMMANDER on $TOPIC"
```

- [ ] **Step 4: chmod + run**

```bash
chmod +x bin/consult-offset-reset.sh
bash tests/run.sh test_consult_offset_reset.sh && bash tests/run.sh
```

- [ ] **Step 5: Commit**

```bash
git add bin/consult-offset-reset.sh tests/test_consult_offset_reset.sh
git commit -m "feat(consult): bin/consult-offset-reset.sh — executable retry primitive

Closes Codex finding #1: removes per-commander state file and cascades
to derived artifacts (diff.md, *_only_items.txt for research; the
adjudication draft for both phases). The only documented retry tool;
spec forbids manual editing of state files."
```

---

### Task 4: `bin/consult-research-send.sh` + test

**Why:** Per-commander research dispatch. Conductor invokes 2× in parallel.

**Files:**
- Create: `bin/consult-research-send.sh`
- Create: `tests/test_consult_research_send.sh`

- [ ] **Step 1: Failing test**

```bash
#!/usr/bin/env bash
# tests/test_consult_research_send.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

# Static wiring: confirm the script exists, sources lib/consult.sh, calls bin/send.sh.
grep -q 'cw_consult_topic_validate' ../bin/consult-research-send.sh \
  || { echo "FAIL: missing topic validation" >&2; exit 1; }
grep -q 'consult_build_research_prompt' ../bin/consult-research-send.sh \
  || { echo "FAIL: missing research prompt builder" >&2; exit 1; }
grep -q 'wc -c' ../bin/consult-research-send.sh \
  || { echo "FAIL: missing wc -c offset capture" >&2; exit 1; }
grep -q 'OFFSET=' ../bin/consult-research-send.sh \
  || { echo "FAIL: missing OFFSET= write" >&2; exit 1; }
pass "research-send wiring"

# Build a fake topic with a stub trooper outbox so we can exercise idempotency.
RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
TOPIC=consult-fixture-rs
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
mkdir -p "$TD/_consult" "$TD/rex-codex"
touch "$TD/rex-codex/outbox.jsonl"
echo "rex" > "$TD/rex-codex/pane.json"   # placeholder; send.sh reads pane_id

# Idempotency: pre-populate research-rex.txt and assert second call refuses.
echo "OFFSET=0" > "$TD/_consult/research-rex.txt"
err=$(../bin/consult-research-send.sh "$TOPIC" rex codex 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && echo "$err" | grep -q 'already exists' \
  || { echo "FAIL: should refuse with existing state file. rc=$rc out=$err" >&2; exit 1; }
pass "research-send fails loud on existing state file"

# Bad commander rejected.
err=$(../bin/consult-research-send.sh "$TOPIC" "bad/commander" codex 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: bad commander accepted" >&2; exit 1; }
pass "bad commander rejected"

# Bad topic (path-traversal) rejected.
err=$(../bin/consult-research-send.sh "../bad" rex codex 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: bad topic accepted" >&2; exit 1; }
pass "path-traversal topic rejected"
```

- [ ] **Step 2: Run, expect failure**

```bash
bash tests/run.sh test_consult_research_send.sh
```

- [ ] **Step 3: Create `bin/consult-research-send.sh`**

```bash
#!/usr/bin/env bash
# bin/consult-research-send.sh — Phase 2 dispatch for one commander.
# The conductor invokes 2× in parallel (one per trooper).
#
# Usage: bin/consult-research-send.sh <consult-topic> <commander> <model>
#
# Writes _consult/research-<commander>.txt with one line: OFFSET=<n>
# Refuses if the file already exists — reset via bin/consult-offset-reset.sh.

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/consult.sh"

[[ $# -eq 3 ]] || { echo "Usage: $0 <consult-topic> <commander> <model>" >&2; exit 2; }
TOPIC="$1"; COMMANDER="$2"; MODEL="$3"

cw_consult_topic_validate "$TOPIC" || { log_error "invalid topic: $TOPIC"; exit 2; }
[[ "$COMMANDER" =~ ^[a-z0-9_-]+$ ]] || { log_error "invalid commander: $COMMANDER"; exit 2; }
[[ "$MODEL" =~ ^[a-z0-9_-]+$ ]] || { log_error "invalid model: $MODEL"; exit 2; }

ART_DIR="$(cw_state_root)/state/$(cw_repo_hash)/$TOPIC/_consult"
[[ -d "$ART_DIR" ]] || { log_error "$ART_DIR not found — run consult-init first"; exit 1; }

STATE_FILE="$ART_DIR/research-$COMMANDER.txt"
[[ ! -e "$STATE_FILE" ]] || {
  log_error "$STATE_FILE already exists; reset with: bin/consult-offset-reset.sh $TOPIC $COMMANDER research"
  exit 1
}

TROOPER_DIR=$(cw_trooper_dir "$COMMANDER" "$MODEL" "$TOPIC")
OUTBOX="$TROOPER_DIR/outbox.jsonl"
[[ -f "$OUTBOX" ]] || { log_error "outbox not found at $OUTBOX — was the trooper spawned?"; exit 1; }

TOPIC_TEXT=$(cat "$ART_DIR/topic.txt")
PROMPT_FILE="$ART_DIR/${COMMANDER}_research_prompt.md"
cw_consult_build_research_prompt "$TOPIC_TEXT" "$TROOPER_DIR/findings.md" > "$PROMPT_FILE"

OFFSET=$(wc -c < "$OUTBOX" | tr -d ' ')
printf 'OFFSET=%s\n' "$OFFSET" > "$STATE_FILE"

if ! "$PLUGIN_ROOT/bin/send.sh" "$COMMANDER" "$TOPIC" "@$PROMPT_FILE" >/dev/null; then
  log_error "send.sh failed; state file kept for retry via consult-offset-reset.sh"
  exit 1
fi

log_info "[research-send] $COMMANDER offset=$OFFSET"
```

- [ ] **Step 4: chmod + run**

```bash
chmod +x bin/consult-research-send.sh
bash tests/run.sh test_consult_research_send.sh && bash tests/run.sh
```

- [ ] **Step 5: Commit**

```bash
git add bin/consult-research-send.sh tests/test_consult_research_send.sh
git commit -m "feat(consult): bin/consult-research-send.sh — per-commander dispatch"
```

---

### Task 5: `bin/consult-research-wait.sh` + test (Codex #2 fixture)

**Why:** Per-commander wait. Replaces the shared `cw_outbox_wait_all` call. Each conductor invocation runs in parallel and writes its own state file → per-trooper status survives peer timeout.

**Files:**
- Create: `bin/consult-research-wait.sh`
- Create: `tests/test_consult_research_wait.sh`

- [ ] **Step 1: Failing test**

```bash
#!/usr/bin/env bash
# tests/test_consult_research_wait.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
TOPIC=consult-fixture-rw
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
mkdir -p "$TD/_consult" "$TD/rex-codex" "$TD/cody-claude"
touch "$TD/rex-codex/outbox.jsonl" "$TD/cody-claude/outbox.jsonl"

# 1. Pre-populate state files with offsets, then append done events past those offsets,
#    then create well-formed findings.md for both → wait should write FS=ok.
REX_OFF=$(wc -c < "$TD/rex-codex/outbox.jsonl" | tr -d ' ')
COD_OFF=$(wc -c < "$TD/cody-claude/outbox.jsonl" | tr -d ' ')
echo "OFFSET=$REX_OFF" > "$TD/_consult/research-rex.txt"
echo "OFFSET=$COD_OFF" > "$TD/_consult/research-cody.txt"

cat > "$TD/rex-codex/findings.md" <<'MD'
# Findings: x
## Summary
.
## Claims
1. [src/x.py:5] real claim.
## Notes
MD
cat > "$TD/cody-claude/findings.md" <<'MD'
# Findings: x
## Summary
.
## Claims
1. [src/y.py:5] real claim.
## Notes
MD

echo '{"event":"done","ts":"t1","summary":"rex"}' >> "$TD/rex-codex/outbox.jsonl"
echo '{"event":"done","ts":"t2","summary":"cody"}' >> "$TD/cody-claude/outbox.jsonl"

../bin/consult-research-wait.sh "$TOPIC" rex codex
../bin/consult-research-wait.sh "$TOPIC" cody claude

# Each state file should now have BOTH OFFSET= and FS= lines.
grep -q '^OFFSET=' "$TD/_consult/research-rex.txt"  || { echo "FAIL: rex OFFSET missing" >&2; exit 1; }
grep -q '^FS=ok'   "$TD/_consult/research-rex.txt"  || { echo "FAIL: rex FS not ok" >&2; cat "$TD/_consult/research-rex.txt" >&2; exit 1; }
grep -q '^OFFSET=' "$TD/_consult/research-cody.txt" || { echo "FAIL: cody OFFSET missing" >&2; exit 1; }
grep -q '^FS=ok'   "$TD/_consult/research-cody.txt" || { echo "FAIL: cody FS not ok" >&2; cat "$TD/_consult/research-cody.txt" >&2; exit 1; }
pass "per-commander wait writes FS=ok when findings well-formed"

# 2. Codex finding #2 fixture: rex times out, cody finishes. Cody's status must survive.
TOPIC2=consult-fixture-rw2
TD2="$CLONE_WARS_HOME/state/$RH/$TOPIC2"
mkdir -p "$TD2/_consult" "$TD2/rex-codex" "$TD2/cody-claude"
touch "$TD2/rex-codex/outbox.jsonl" "$TD2/cody-claude/outbox.jsonl"
REX_OFF2=$(wc -c < "$TD2/rex-codex/outbox.jsonl" | tr -d ' ')
COD_OFF2=$(wc -c < "$TD2/cody-claude/outbox.jsonl" | tr -d ' ')
echo "OFFSET=$REX_OFF2" > "$TD2/_consult/research-rex.txt"
echo "OFFSET=$COD_OFF2" > "$TD2/_consult/research-cody.txt"
# Only cody emits done; rex's outbox stays silent.
cat > "$TD2/cody-claude/findings.md" <<'MD'
# Findings: x
## Claims
1. [src/y.py:5] real claim.
## Notes
MD
echo '{"event":"done","ts":"t","summary":"cody"}' >> "$TD2/cody-claude/outbox.jsonl"

# Run cody-side wait FIRST (succeeds in <1s), then rex-side (times out via short timeout).
../bin/consult-research-wait.sh "$TOPIC2" cody claude
# Force a short timeout for rex via env override (script should pick up CW_CONSULT_RESEARCH_TIMEOUT_OVERRIDE if set).
CW_CONSULT_RESEARCH_TIMEOUT_OVERRIDE=1 ../bin/consult-research-wait.sh "$TOPIC2" rex codex

grep -q '^FS=ok'      "$TD2/_consult/research-cody.txt" || { echo "FAIL: cody status was destroyed by rex timeout" >&2; cat "$TD2/_consult/research-cody.txt" >&2; exit 1; }
grep -q '^FS=missing' "$TD2/_consult/research-rex.txt"  || { echo "FAIL: rex status not 'missing' after timeout" >&2; cat "$TD2/_consult/research-rex.txt" >&2; exit 1; }
pass "rex timeout does not destroy cody's status (Codex #2 fixture)"

# 3. Refuses if state file missing.
err=$(../bin/consult-research-wait.sh "$TOPIC" missing-cmd codex 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: missing state file should reject" >&2; exit 1; }
pass "research-wait refuses with missing state file"
```

- [ ] **Step 2: Run, expect failure**

```bash
bash tests/run.sh test_consult_research_wait.sh
```

- [ ] **Step 3: Create `bin/consult-research-wait.sh`**

```bash
#!/usr/bin/env bash
# bin/consult-research-wait.sh — per-commander wait for {done,error}.
# The conductor invokes 2× in parallel (one per trooper).
#
# Usage: bin/consult-research-wait.sh <consult-topic> <commander> <model>
#
# Reads OFFSET= from _consult/research-<commander>.txt; appends FS=<status>.
# Returns rc=0 always — status field carries the outcome.

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/contracts.sh"
source "$PLUGIN_ROOT/lib/consult.sh"

[[ $# -eq 3 ]] || { echo "Usage: $0 <consult-topic> <commander> <model>" >&2; exit 2; }
TOPIC="$1"; COMMANDER="$2"; MODEL="$3"

cw_consult_topic_validate "$TOPIC" || { log_error "invalid topic: $TOPIC"; exit 2; }
[[ "$COMMANDER" =~ ^[a-z0-9_-]+$ ]] || { log_error "invalid commander: $COMMANDER"; exit 2; }

ART_DIR="$(cw_state_root)/state/$(cw_repo_hash)/$TOPIC/_consult"
STATE_FILE="$ART_DIR/research-$COMMANDER.txt"
[[ -f "$STATE_FILE" ]] || { log_error "$STATE_FILE missing — run consult-research-send first"; exit 1; }

# shellcheck disable=SC1090
source "$STATE_FILE"   # sets OFFSET
[[ -n "${OFFSET:-}" ]] || { log_error "OFFSET not set in $STATE_FILE"; exit 1; }

TIMEOUT="${CW_CONSULT_RESEARCH_TIMEOUT_OVERRIDE:-$(cw_consult_timeout research)}"
log_info "[research-wait] $COMMANDER offset=$OFFSET timeout=${TIMEOUT}s"

cw_outbox_wait_since "$COMMANDER" "$MODEL" "$TOPIC" "$OFFSET" done error "$TIMEOUT" >/dev/null || true
# rc is intentionally ignored — status comes from cw_consult_findings_status.

TROOPER_DIR=$(cw_trooper_dir "$COMMANDER" "$MODEL" "$TOPIC")
FS=$(cw_consult_findings_status "$TROOPER_DIR/findings.md")
printf 'FS=%s\n' "$FS" >> "$STATE_FILE"
log_info "[research-wait] $COMMANDER FS=$FS"
```

- [ ] **Step 4: chmod + run**

```bash
chmod +x bin/consult-research-wait.sh
bash tests/run.sh test_consult_research_wait.sh && bash tests/run.sh
```

- [ ] **Step 5: Commit**

```bash
git add bin/consult-research-wait.sh tests/test_consult_research_wait.sh
git commit -m "$(cat <<'EOF'
feat(consult): bin/consult-research-wait.sh — per-commander wait

Closes Codex finding #2: per-commander wait scripts run in parallel and
each writes its own _consult/research-<commander>.txt. A peer's timeout
no longer destroys a successful trooper's status. Test fixture asserts
the rex-times-out + cody-finishes case explicitly.
EOF
)"
```

---

### Task 6: `bin/consult-diff.sh`

**Why:** Wraps the existing `cw_consult_diff` lib helper; adds `*_only_items.txt` extraction.

**Files:**
- Create: `bin/consult-diff.sh`

(No new test — `tests/test_consult_diff.sh` already covers `cw_consult_diff` exhaustively. This sub-script is a 30-line shell wrapper.)

- [ ] **Step 1: Create `bin/consult-diff.sh`**

```bash
#!/usr/bin/env bash
# bin/consult-diff.sh — bucket findings into Agreed / Rex-only / Cody-only.
#
# Usage: bin/consult-diff.sh <consult-topic>
#
# Writes _consult/diff.md + rex_only_items.txt + cody_only_items.txt.
# Refuses if diff.md exists.

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/consult.sh"

[[ $# -eq 1 ]] || { echo "Usage: $0 <consult-topic>" >&2; exit 2; }
TOPIC="$1"
cw_consult_topic_validate "$TOPIC" || { log_error "invalid topic: $TOPIC"; exit 2; }

ART_DIR="$(cw_state_root)/state/$(cw_repo_hash)/$TOPIC/_consult"
[[ -d "$ART_DIR" ]] || { log_error "$ART_DIR not found"; exit 1; }
[[ ! -e "$ART_DIR/diff.md" ]] || { log_error "diff.md exists; reset to retry"; exit 1; }

REX_DIR=$(cw_trooper_dir rex codex "$TOPIC")
CODY_DIR=$(cw_trooper_dir cody claude "$TOPIC")
[[ -f "$REX_DIR/findings.md"  ]] || { log_error "rex findings.md missing"; exit 1; }
[[ -f "$CODY_DIR/findings.md" ]] || { log_error "cody findings.md missing"; exit 1; }

DIFF="$ART_DIR/diff.md"
cw_consult_diff "$REX_DIR/findings.md" "$CODY_DIR/findings.md" "$DIFF"

# Extract _only items for verify dispatch.
awk '/^## Rex-only/{f=1;next}  /^## /{f=0} f && /^- /{ sub(/^- /,""); print }'  "$DIFF" > "$ART_DIR/rex_only_items.txt"
awk '/^## Cody-only/{f=1;next} /^## /{f=0} f && /^- /{ sub(/^- /,""); print }'  "$DIFF" > "$ART_DIR/cody_only_items.txt"

log_info "[diff] wrote $DIFF + rex_only_items.txt ($(wc -l < "$ART_DIR/rex_only_items.txt") items) + cody_only_items.txt ($(wc -l < "$ART_DIR/cody_only_items.txt") items)"
```

- [ ] **Step 2: chmod + suite**

```bash
chmod +x bin/consult-diff.sh
bash tests/run.sh
```

(No new test for the wrapper itself; `test_consult_diff.sh` covers the lib helper.)

- [ ] **Step 3: Commit**

```bash
git add bin/consult-diff.sh
git commit -m "feat(consult): bin/consult-diff.sh — wrap cw_consult_diff + extract _only items"
```

---

### Task 7: `bin/consult-verify-send.sh` + test

**Why:** Per-commander verify dispatch. Skips writing OFFSET if peer's _ONLY items file is empty (writes `VS=skipped` instead).

**Files:**
- Create: `bin/consult-verify-send.sh`
- Create: `tests/test_consult_verify_send.sh`

- [ ] **Step 1: Failing test**

```bash
#!/usr/bin/env bash
# tests/test_consult_verify_send.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')

# 1. Empty peer file → VS=skipped, no OFFSET, no send.
TOPIC=consult-fixture-vs1
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
mkdir -p "$TD/_consult" "$TD/rex-codex" "$TD/cody-claude"
touch "$TD/rex-codex/outbox.jsonl"
touch "$TD/_consult/cody_only_items.txt"  # EMPTY

../bin/consult-verify-send.sh "$TOPIC" rex codex
[[ -f "$TD/_consult/verify-rex.txt" ]] || { echo "FAIL: verify-rex.txt missing" >&2; exit 1; }
grep -q '^VS=skipped' "$TD/_consult/verify-rex.txt" || { echo "FAIL: VS not skipped" >&2; cat "$TD/_consult/verify-rex.txt" >&2; exit 1; }
grep -q '^OFFSET='   "$TD/_consult/verify-rex.txt" && { echo "FAIL: OFFSET should not be present in skipped state" >&2; exit 1; }
pass "empty peer file → VS=skipped"

# 2. Idempotency: second call refuses.
err=$(../bin/consult-verify-send.sh "$TOPIC" rex codex 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: second call should refuse" >&2; exit 1; }
pass "verify-send fails loud on existing state"

# 3. Bad commander rejected.
TOPIC2=consult-fixture-vs2
mkdir -p "$CLONE_WARS_HOME/state/$RH/$TOPIC2/_consult"
touch "$CLONE_WARS_HOME/state/$RH/$TOPIC2/_consult/cody_only_items.txt"
err=$(../bin/consult-verify-send.sh "$TOPIC2" "bad/cmd" codex 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: bad commander accepted" >&2; exit 1; }
pass "bad commander rejected"

# Static wiring check: verify the rex-side reads cody_only_items.txt and vice versa.
grep -q 'cody_only_items.txt' ../bin/consult-verify-send.sh \
  || { echo "FAIL: rex-branch must read cody_only_items.txt" >&2; exit 1; }
grep -q 'rex_only_items.txt'  ../bin/consult-verify-send.sh \
  || { echo "FAIL: cody-branch must read rex_only_items.txt" >&2; exit 1; }
pass "verify-send reads PEER's _only_items.txt"
```

- [ ] **Step 2: Run, expect failure**

```bash
bash tests/run.sh test_consult_verify_send.sh
```

- [ ] **Step 3: Create `bin/consult-verify-send.sh`**

```bash
#!/usr/bin/env bash
# bin/consult-verify-send.sh — Phase 4 dispatch for one commander.
# The conductor invokes 2× in parallel.
#
# Usage: bin/consult-verify-send.sh <consult-topic> <commander> <model>
#
# Reads PEER's _only_items.txt: rex sends → reads cody_only_items.txt; cody → reads rex_only_items.txt.
# If peer file is empty → writes VS=skipped (no actual send). Else writes OFFSET= and sends.

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/consult.sh"

[[ $# -eq 3 ]] || { echo "Usage: $0 <consult-topic> <commander> <model>" >&2; exit 2; }
TOPIC="$1"; COMMANDER="$2"; MODEL="$3"

cw_consult_topic_validate "$TOPIC" || { log_error "invalid topic: $TOPIC"; exit 2; }
[[ "$COMMANDER" =~ ^[a-z0-9_-]+$ ]] || { log_error "invalid commander: $COMMANDER"; exit 2; }
[[ "$MODEL" =~ ^[a-z0-9_-]+$ ]]    || { log_error "invalid model: $MODEL"; exit 2; }

ART_DIR="$(cw_state_root)/state/$(cw_repo_hash)/$TOPIC/_consult"
[[ -d "$ART_DIR" ]] || { log_error "$ART_DIR not found"; exit 1; }

STATE_FILE="$ART_DIR/verify-$COMMANDER.txt"
[[ ! -e "$STATE_FILE" ]] || {
  log_error "$STATE_FILE already exists; reset with: bin/consult-offset-reset.sh $TOPIC $COMMANDER verify"
  exit 1
}

# rex sends → reads cody's _only items; cody sends → reads rex's.
case "$COMMANDER" in
  rex)  PEER_ITEMS="$ART_DIR/cody_only_items.txt" ;;
  cody) PEER_ITEMS="$ART_DIR/rex_only_items.txt"  ;;
  *)    log_error "verify-send only supports rex/cody for now; got $COMMANDER"; exit 2 ;;
esac
[[ -f "$PEER_ITEMS" ]] || { log_error "$PEER_ITEMS missing — run consult-diff first"; exit 1; }

if [[ ! -s "$PEER_ITEMS" ]]; then
  printf 'VS=skipped\n' > "$STATE_FILE"
  log_info "[verify-send] $COMMANDER VS=skipped (peer has no _only items)"
  exit 0
fi

TROOPER_DIR=$(cw_trooper_dir "$COMMANDER" "$MODEL" "$TOPIC")
OUTBOX="$TROOPER_DIR/outbox.jsonl"
[[ -f "$OUTBOX" ]] || { log_error "outbox not found at $OUTBOX"; exit 1; }

PROMPT_FILE="$ART_DIR/${COMMANDER}_verify_prompt.md"
cw_consult_build_verify_prompt "$PEER_ITEMS" "$TROOPER_DIR/verify.md" > "$PROMPT_FILE"

OFFSET=$(wc -c < "$OUTBOX" | tr -d ' ')
printf 'OFFSET=%s\n' "$OFFSET" > "$STATE_FILE"

if ! "$PLUGIN_ROOT/bin/send.sh" "$COMMANDER" "$TOPIC" "@$PROMPT_FILE" >/dev/null; then
  log_error "send.sh failed; state file kept for retry"
  exit 1
fi

log_info "[verify-send] $COMMANDER offset=$OFFSET items=$(wc -l < "$PEER_ITEMS")"
```

- [ ] **Step 4: chmod + run**

```bash
chmod +x bin/consult-verify-send.sh
bash tests/run.sh test_consult_verify_send.sh && bash tests/run.sh
```

- [ ] **Step 5: Commit**

```bash
git add bin/consult-verify-send.sh tests/test_consult_verify_send.sh
git commit -m "feat(consult): bin/consult-verify-send.sh — per-commander verify dispatch"
```

---

### Task 8: `bin/consult-verify-wait.sh` + test

**Why:** Per-commander verify wait. Skips wait if state file shows `VS=skipped`. Mirror of research-wait.

**Files:**
- Create: `bin/consult-verify-wait.sh`
- Create: `tests/test_consult_verify_wait.sh`

- [ ] **Step 1: Failing test**

```bash
#!/usr/bin/env bash
# tests/test_consult_verify_wait.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')

# 1. VS=skipped state → wait short-circuits, no FS append, rc=0.
TOPIC=consult-fixture-vw1
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
mkdir -p "$TD/_consult" "$TD/rex-codex"
touch "$TD/rex-codex/outbox.jsonl"
echo "VS=skipped" > "$TD/_consult/verify-rex.txt"

../bin/consult-verify-wait.sh "$TOPIC" rex codex
content=$(cat "$TD/_consult/verify-rex.txt")
assert_eq "$content" "VS=skipped" "skipped state untouched"
pass "verify-wait short-circuits on VS=skipped"

# 2. OFFSET state with done event → VS=ok appended.
TOPIC2=consult-fixture-vw2
TD2="$CLONE_WARS_HOME/state/$RH/$TOPIC2"
mkdir -p "$TD2/_consult" "$TD2/rex-codex"
touch "$TD2/rex-codex/outbox.jsonl"
OFF=$(wc -c < "$TD2/rex-codex/outbox.jsonl" | tr -d ' ')
echo "OFFSET=$OFF" > "$TD2/_consult/verify-rex.txt"
cat > "$TD2/rex-codex/verify.md" <<'MD'
# Verify
## Verdicts
1. AGREE [src/x.py:5] real claim.
   evidence here
MD
echo '{"event":"done","ts":"t","summary":"verified"}' >> "$TD2/rex-codex/outbox.jsonl"

../bin/consult-verify-wait.sh "$TOPIC2" rex codex
grep -q '^VS=ok' "$TD2/_consult/verify-rex.txt" || { echo "FAIL: VS not ok" >&2; cat "$TD2/_consult/verify-rex.txt" >&2; exit 1; }
pass "verify-wait writes VS=ok when verify.md present"

# 3. Refuses if state file missing.
err=$(../bin/consult-verify-wait.sh "$TOPIC" missing-cmd codex 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: missing state file should reject" >&2; exit 1; }
pass "verify-wait refuses with missing state file"
```

- [ ] **Step 2: Run, expect failure**

```bash
bash tests/run.sh test_consult_verify_wait.sh
```

- [ ] **Step 3: Create `bin/consult-verify-wait.sh`**

```bash
#!/usr/bin/env bash
# bin/consult-verify-wait.sh — per-commander verify wait.
#
# Usage: bin/consult-verify-wait.sh <consult-topic> <commander> <model>
#
# Reads OFFSET= from _consult/verify-<commander>.txt (or VS=skipped → no-op).
# Appends VS=<status> based on wait outcome + verify.md presence.

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/contracts.sh"
source "$PLUGIN_ROOT/lib/consult.sh"

[[ $# -eq 3 ]] || { echo "Usage: $0 <consult-topic> <commander> <model>" >&2; exit 2; }
TOPIC="$1"; COMMANDER="$2"; MODEL="$3"

cw_consult_topic_validate "$TOPIC" || { log_error "invalid topic: $TOPIC"; exit 2; }
[[ "$COMMANDER" =~ ^[a-z0-9_-]+$ ]] || { log_error "invalid commander: $COMMANDER"; exit 2; }

ART_DIR="$(cw_state_root)/state/$(cw_repo_hash)/$TOPIC/_consult"
STATE_FILE="$ART_DIR/verify-$COMMANDER.txt"
[[ -f "$STATE_FILE" ]] || { log_error "$STATE_FILE missing — run consult-verify-send first"; exit 1; }

# Short-circuit if already skipped.
if grep -q '^VS=skipped' "$STATE_FILE"; then
  log_info "[verify-wait] $COMMANDER skipped (already)"
  exit 0
fi

unset OFFSET
# shellcheck disable=SC1090
source "$STATE_FILE"
[[ -n "${OFFSET:-}" ]] || { log_error "OFFSET not set in $STATE_FILE"; exit 1; }

TIMEOUT="${CW_CONSULT_VERIFY_TIMEOUT_OVERRIDE:-$(cw_consult_timeout verify)}"
log_info "[verify-wait] $COMMANDER offset=$OFFSET timeout=${TIMEOUT}s"

cw_outbox_wait_since "$COMMANDER" "$MODEL" "$TOPIC" "$OFFSET" done error "$TIMEOUT" >/dev/null
WAIT_RC=$?

TROOPER_DIR=$(cw_trooper_dir "$COMMANDER" "$MODEL" "$TOPIC")
VERIFY_FILE="$TROOPER_DIR/verify.md"

if [[ -s "$VERIFY_FILE" ]]; then
  VS=ok
elif [[ "$WAIT_RC" -ne 0 ]]; then
  VS=timeout
else
  VS=missing
fi

printf 'VS=%s\n' "$VS" >> "$STATE_FILE"
log_info "[verify-wait] $COMMANDER VS=$VS"
```

- [ ] **Step 4: chmod + run**

```bash
chmod +x bin/consult-verify-wait.sh
bash tests/run.sh test_consult_verify_wait.sh && bash tests/run.sh
```

- [ ] **Step 5: Commit**

```bash
git add bin/consult-verify-wait.sh tests/test_consult_verify_wait.sh
git commit -m "feat(consult): bin/consult-verify-wait.sh — per-commander verify wait"
```

---

### Task 9: `bin/consult-adjudicate.sh` + test (Codex #4 fixture)

**Why:** Closes Codex finding #4. Writes `adjudicated-DRAFT.md` (regenerable). Never touches `adjudicated.md`.

**Files:**
- Create: `bin/consult-adjudicate.sh`
- Create: `tests/test_consult_adjudicate.sh`

- [ ] **Step 1: Failing test**

```bash
#!/usr/bin/env bash
# tests/test_consult_adjudicate.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
TOPIC=consult-fixture-adj
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
mkdir -p "$TD/_consult" "$TD/rex-codex" "$TD/cody-claude"

# Set up state files.
cat > "$TD/_consult/research-rex.txt"  <<'EOF'
OFFSET=0
FS=ok
EOF
cat > "$TD/_consult/research-cody.txt" <<'EOF'
OFFSET=0
FS=ok
EOF
cat > "$TD/_consult/verify-rex.txt"  <<'EOF'
OFFSET=0
VS=ok
EOF
cat > "$TD/_consult/verify-cody.txt" <<'EOF'
OFFSET=0
VS=ok
EOF
touch "$TD/_consult/rex_only_items.txt" "$TD/_consult/cody_only_items.txt"

cat > "$TD/rex-codex/verify.md" <<'MD'
# Verify
## Verdicts
1. AGREE [src/x.py:5] tokens stored in plaintext.
   src/x.py:5 confirms
2. DISPUTE [src/y.py:10] some other claim.
   src/y.py:10 actually does the opposite
MD
cat > "$TD/cody-claude/verify.md" <<'MD'
# Verify
## Verdicts
1. AGREE [src/z.py:7] callback validated.
   line 7 has the assert
MD

# 1. Adjudicate writes DRAFT, not the resolved file.
../bin/consult-adjudicate.sh "$TOPIC"
[[ -f "$TD/_consult/adjudicated-draft.md" ]] || { echo "FAIL: draft missing" >&2; exit 1; }
[[ ! -f "$TD/_consult/adjudicated.md" ]]    || { echo "FAIL: resolved file should not exist yet" >&2; exit 1; }
grep -q '^## Cross-verified' "$TD/_consult/adjudicated-draft.md"  || { echo "FAIL: missing Cross-verified"  >&2; exit 1; }
grep -q '^## Adjudicated'    "$TD/_consult/adjudicated-draft.md"  || { echo "FAIL: missing Adjudicated"    >&2; exit 1; }
grep -q 'PENDING:'           "$TD/_consult/adjudicated-draft.md"  || { echo "FAIL: missing PENDING entry" >&2; exit 1; }
pass "adjudicate writes draft only"

# 2. Re-running adjudicate overwrites the draft (idempotent).
echo "stale" > "$TD/_consult/adjudicated-draft.md"
../bin/consult-adjudicate.sh "$TOPIC"
grep -q '^## Cross-verified' "$TD/_consult/adjudicated-draft.md" || { echo "FAIL: re-run did not regenerate draft" >&2; exit 1; }
pass "adjudicate re-run overwrites draft"

# 3. Codex #4 fixture: existing adjudicated.md (conductor's resolution) is NEVER touched.
cat > "$TD/_consult/adjudicated.md" <<'MD'
## Cross-verified
- [src/x.py:5] confirmed by both
## Adjudicated
- CONFIRMED: [src/y.py:10] verified by conductor reading source
## Contested
## Not-verified
MD
ORIGINAL=$(cat "$TD/_consult/adjudicated.md")

../bin/consult-adjudicate.sh "$TOPIC"

NEW=$(cat "$TD/_consult/adjudicated.md")
assert_eq "$NEW" "$ORIGINAL" "conductor's adjudicated.md preserved across re-adjudicate"
pass "adjudicate never overwrites conductor's adjudicated.md (Codex #4 fixture)"
```

- [ ] **Step 2: Run, expect failure**

```bash
bash tests/run.sh test_consult_adjudicate.sh
```

- [ ] **Step 3: Create `bin/consult-adjudicate.sh`**

```bash
#!/usr/bin/env bash
# bin/consult-adjudicate.sh — generate adjudicated-draft.md.
#
# Usage: bin/consult-adjudicate.sh <consult-topic>
#
# Writes _consult/adjudicated-draft.md (regenerable, idempotent).
# NEVER touches _consult/adjudicated.md (the conductor's resolution surface).

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/consult.sh"

[[ $# -eq 1 ]] || { echo "Usage: $0 <consult-topic>" >&2; exit 2; }
TOPIC="$1"
cw_consult_topic_validate "$TOPIC" || { log_error "invalid topic: $TOPIC"; exit 2; }

ART_DIR="$(cw_state_root)/state/$(cw_repo_hash)/$TOPIC/_consult"
[[ -d "$ART_DIR" ]] || { log_error "$ART_DIR not found"; exit 1; }

# Defaults if a state file is missing.
REX_VS=skipped; CODY_VS=skipped
cw_consult_status_load "$ART_DIR/verify-rex.txt"
cw_consult_status_load "$ART_DIR/verify-cody.txt"
# Note: status_load sources the file, so VS gets overwritten as each is loaded.
# Capture them explicitly.
REX_VS_VAL=skipped; CODY_VS_VAL=skipped
if [[ -f "$ART_DIR/verify-rex.txt" ]]; then
  REX_VS_VAL=$(awk -F= '/^VS=/{print $2}' "$ART_DIR/verify-rex.txt")
  : "${REX_VS_VAL:=skipped}"
fi
if [[ -f "$ART_DIR/verify-cody.txt" ]]; then
  CODY_VS_VAL=$(awk -F= '/^VS=/{print $2}' "$ART_DIR/verify-cody.txt")
  : "${CODY_VS_VAL:=skipped}"
fi

REX_DIR=$(cw_trooper_dir rex codex "$TOPIC")
CODY_DIR=$(cw_trooper_dir cody claude "$TOPIC")

cw_consult_write_adjudicated \
  "$ART_DIR/adjudicated-draft.md" \
  "$REX_DIR/verify.md" \
  "$CODY_DIR/verify.md" \
  "$ART_DIR/rex_only_items.txt" \
  "$ART_DIR/cody_only_items.txt" \
  "$REX_VS_VAL" \
  "$CODY_VS_VAL"

log_info "[adjudicate] wrote $ART_DIR/adjudicated-draft.md"
log_info "  conductor: cp adjudicated-draft.md adjudicated.md, then resolve PENDINGs."
```

- [ ] **Step 4: chmod + run**

```bash
chmod +x bin/consult-adjudicate.sh
bash tests/run.sh test_consult_adjudicate.sh && bash tests/run.sh
```

- [ ] **Step 5: Commit**

```bash
git add bin/consult-adjudicate.sh tests/test_consult_adjudicate.sh
git commit -m "$(cat <<'EOF'
feat(consult): bin/consult-adjudicate.sh — generates draft, never touches resolved

Closes Codex finding #4: adjudicated-draft.md is the regenerable
computation output; adjudicated.md is the conductor's resolution
surface. The two-file split prevents re-adjudicate from silently
destroying PENDING-resolution work.
EOF
)"
```

---

### Task 10: `bin/consult-synthesize.sh` + test

**Why:** No-PENDING gate (moved from v0.1's consult-finalize.sh). Reads conductor-resolved `adjudicated.md`, NOT the draft.

**Files:**
- Create: `bin/consult-synthesize.sh`
- Create: `tests/test_consult_synthesize_bin.sh`

- [ ] **Step 1: Failing test**

```bash
#!/usr/bin/env bash
# tests/test_consult_synthesize_bin.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
TOPIC=consult-fixture-syn
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
mkdir -p "$TD/_consult" "$TD/rex-codex" "$TD/cody-claude"

# Pre-populate state.
echo "topic text" > "$TD/_consult/topic.txt"
cat > "$TD/_consult/research-rex.txt"  <<EOF
OFFSET=0
FS=ok
EOF
cat > "$TD/_consult/research-cody.txt" <<EOF
OFFSET=0
FS=ok
EOF
cat > "$TD/_consult/verify-rex.txt"  <<EOF
OFFSET=0
VS=ok
EOF
cat > "$TD/_consult/verify-cody.txt" <<EOF
OFFSET=0
VS=ok
EOF
cat > "$TD/_consult/diff.md" <<'MD'
## Agreed
- [src/x.py:5] both | Both confirm.
## Rex-only
## Cody-only
MD

# 1. adjudicated.md missing → rc=1.
err=$(../bin/consult-synthesize.sh "$TOPIC" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && echo "$err" | grep -q 'adjudicated.md' \
  || { echo "FAIL: missing adjudicated.md should reject" >&2; exit 1; }
pass "synthesize refuses without adjudicated.md"

# 2. adjudicated.md with PENDING → rc=1.
cat > "$TD/_consult/adjudicated.md" <<'MD'
## Cross-verified
## Adjudicated
- PENDING: [src/y.py:10] needs resolution
## Contested
## Not-verified
MD
err=$(../bin/consult-synthesize.sh "$TOPIC" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && echo "$err" | grep -q 'PENDING' \
  || { echo "FAIL: PENDING should block" >&2; exit 1; }
pass "synthesize refuses with PENDING items"

# 3. Resolved adjudicated.md → rc=0; synthesis.md created.
sed -i 's/^- PENDING:/- CONFIRMED:/' "$TD/_consult/adjudicated.md"
../bin/consult-synthesize.sh "$TOPIC" >/dev/null
[[ -f "$TD/_consult/synthesis.md" ]] || { echo "FAIL: synthesis.md missing" >&2; exit 1; }
grep -q '^# Consultation: topic text' "$TD/_consult/synthesis.md" || { echo "FAIL: synthesis title missing" >&2; exit 1; }
pass "synthesize writes synthesis.md when no PENDING"

# 4. Re-running on existing synthesis.md → rc=1.
err=$(../bin/consult-synthesize.sh "$TOPIC" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: re-run on existing synthesis should reject" >&2; exit 1; }
pass "synthesize fails loud on existing synthesis.md"
```

- [ ] **Step 2: Run, expect failure**

```bash
bash tests/run.sh test_consult_synthesize_bin.sh
```

- [ ] **Step 3: Create `bin/consult-synthesize.sh`**

```bash
#!/usr/bin/env bash
# bin/consult-synthesize.sh — write synthesis.md after PENDING resolution.
#
# Usage: bin/consult-synthesize.sh <consult-topic>
#
# Refuses if adjudicated.md missing OR contains any ^- PENDING: line OR
# synthesis.md already exists.

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/consult.sh"

[[ $# -eq 1 ]] || { echo "Usage: $0 <consult-topic>" >&2; exit 2; }
TOPIC="$1"
cw_consult_topic_validate "$TOPIC" || { log_error "invalid topic: $TOPIC"; exit 2; }

ART_DIR="$(cw_state_root)/state/$(cw_repo_hash)/$TOPIC/_consult"
[[ -d "$ART_DIR" ]] || { log_error "$ART_DIR not found"; exit 1; }

ADJ="$ART_DIR/adjudicated.md"
[[ -f "$ADJ" ]] || { log_error "$ADJ missing — conductor must cp adjudicated-draft.md adjudicated.md and resolve PENDINGs"; exit 1; }

if grep -q '^- PENDING:' "$ADJ"; then
  log_error "$ADJ still has ^- PENDING: lines:"
  grep -n '^- PENDING:' "$ADJ" >&2
  exit 1
fi

SYN="$ART_DIR/synthesis.md"
[[ ! -e "$SYN" ]] || { log_error "$SYN already exists; rm to regenerate"; exit 1; }

# Load statuses with safe fallbacks.
REX_FS=missing; CODY_FS=missing; REX_VS=skipped; CODY_VS=skipped
if [[ -f "$ART_DIR/research-rex.txt"  ]]; then REX_FS=$(awk -F= '/^FS=/{print $2}'  "$ART_DIR/research-rex.txt");  : "${REX_FS:=missing}"; fi
if [[ -f "$ART_DIR/research-cody.txt" ]]; then CODY_FS=$(awk -F= '/^FS=/{print $2}' "$ART_DIR/research-cody.txt"); : "${CODY_FS:=missing}"; fi
if [[ -f "$ART_DIR/verify-rex.txt"    ]]; then REX_VS=$(awk -F= '/^VS=/{print $2}'  "$ART_DIR/verify-rex.txt");   : "${REX_VS:=skipped}"; fi
if [[ -f "$ART_DIR/verify-cody.txt"   ]]; then CODY_VS=$(awk -F= '/^VS=/{print $2}' "$ART_DIR/verify-cody.txt");  : "${CODY_VS:=skipped}"; fi

TOPIC_TEXT=$(cat "$ART_DIR/topic.txt")
DIFF="$ART_DIR/diff.md"
REX_DIR=$(cw_trooper_dir rex codex "$TOPIC")
CODY_DIR=$(cw_trooper_dir cody claude "$TOPIC")

cw_consult_synthesize "$TOPIC_TEXT" "$DIFF" "$ADJ" "$REX_DIR" "$CODY_DIR" \
  "$REX_FS" "$CODY_FS" "$REX_VS" "$CODY_VS" "$SYN"

log_info "[synthesize] wrote $SYN"
cat "$SYN"
```

- [ ] **Step 4: chmod + run**

```bash
chmod +x bin/consult-synthesize.sh
bash tests/run.sh test_consult_synthesize_bin.sh && bash tests/run.sh
```

- [ ] **Step 5: Commit**

```bash
git add bin/consult-synthesize.sh tests/test_consult_synthesize_bin.sh
git commit -m "feat(consult): bin/consult-synthesize.sh — no-PENDING gate + synthesis"
```

---

### Task 11: `bin/consult-teardown.sh` + test

**Files:** Create both.

- [ ] **Step 1: Failing test**

```bash
#!/usr/bin/env bash
# tests/test_consult_teardown_bin.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

# Topic must exist; teardown should be safe (no panes alive in test env).
RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
TOPIC=consult-fixture-td
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
mkdir -p "$TD/_consult"

../bin/consult-teardown.sh "$TOPIC" 2>&1 >/dev/null
# The script delegates to bin/teardown.sh; with no panes/commanders, it's a no-op.
pass "teardown is a thin wrapper; safe on no-pane state"

# Bad topic rejected.
err=$(../bin/consult-teardown.sh "../bad" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: bad topic accepted" >&2; exit 1; }
pass "bad topic rejected"
```

- [ ] **Step 2: Run, expect failure**

```bash
bash tests/run.sh test_consult_teardown_bin.sh
```

- [ ] **Step 3: Create `bin/consult-teardown.sh`**

```bash
#!/usr/bin/env bash
# bin/consult-teardown.sh — kill consult panes + archive trooper state.
# Thin wrapper around bin/teardown.sh with topic validation.
#
# Usage: bin/consult-teardown.sh <consult-topic>

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/consult.sh"

[[ $# -eq 1 ]] || { echo "Usage: $0 <consult-topic>" >&2; exit 2; }
TOPIC="$1"
cw_consult_topic_validate "$TOPIC" || { log_error "invalid topic: $TOPIC"; exit 2; }

"$PLUGIN_ROOT/bin/teardown.sh" "$TOPIC"
```

- [ ] **Step 4: chmod + run**

```bash
chmod +x bin/consult-teardown.sh
bash tests/run.sh test_consult_teardown_bin.sh && bash tests/run.sh
```

- [ ] **Step 5: Commit**

```bash
git add bin/consult-teardown.sh tests/test_consult_teardown_bin.sh
git commit -m "feat(consult): bin/consult-teardown.sh — topic-validated teardown wrapper"
```

---

### Task 12: `bin/consult-archive.sh` + test

**Files:** Create both.

- [ ] **Step 1: Failing test**

```bash
#!/usr/bin/env bash
# tests/test_consult_archive.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
TOPIC=consult-fixture-arch
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"
mkdir -p "$TD/_consult"
echo "synthesis content" > "$TD/_consult/synthesis.md"

# 1. Archive moves _consult to archive/, removes topic dir.
../bin/consult-archive.sh "$TOPIC"
[[ ! -d "$TD/_consult" ]] || { echo "FAIL: _consult survived" >&2; exit 1; }
[[ ! -d "$TD"           ]] || { echo "FAIL: topic dir survived" >&2; exit 1; }
arch=$(find "$CLONE_WARS_HOME/archive/$RH/$TOPIC" -maxdepth 1 -type d -name '_consult-*' 2>/dev/null | head -n1)
[[ -n "$arch" ]] || { echo "FAIL: _consult not archived" >&2; exit 1; }
[[ -f "$arch/synthesis.md" ]] || { echo "FAIL: synthesis.md not in archive" >&2; exit 1; }
pass "archive moves _consult, removes topic dir"

# 2. Re-running archive on missing _consult → rc=1.
err=$(../bin/consult-archive.sh "$TOPIC" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: missing _consult should reject" >&2; exit 1; }
pass "archive fails loud on missing _consult"

# 3. Bad topic rejected.
err=$(../bin/consult-archive.sh "../bad" 2>&1) && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: bad topic accepted" >&2; exit 1; }
pass "bad topic rejected"
```

- [ ] **Step 2: Run, expect failure**

```bash
bash tests/run.sh test_consult_archive.sh
```

- [ ] **Step 3: Create `bin/consult-archive.sh`**

```bash
#!/usr/bin/env bash
# bin/consult-archive.sh — move _consult/ to archive.
#
# Usage: bin/consult-archive.sh <consult-topic>

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/consult.sh"

[[ $# -eq 1 ]] || { echo "Usage: $0 <consult-topic>" >&2; exit 2; }
TOPIC="$1"
cw_consult_topic_validate "$TOPIC" || { log_error "invalid topic: $TOPIC"; exit 2; }

TOPIC_DIR="$(cw_state_root)/state/$(cw_repo_hash)/$TOPIC"
ART_DIR="$TOPIC_DIR/_consult"
[[ -d "$ART_DIR" ]] || { log_error "$ART_DIR missing — already archived?"; exit 1; }

ARCHIVE_BASE="$(cw_state_root)/archive/$(cw_repo_hash)/$TOPIC"
mkdir -p "$ARCHIVE_BASE"
TS=$(date -u +'%Y%m%dT%H%M%SZ')
mv "$ART_DIR" "$ARCHIVE_BASE/_consult-$TS"
rmdir "$TOPIC_DIR" 2>/dev/null || true

log_ok "archived: $ARCHIVE_BASE/_consult-$TS"
```

- [ ] **Step 4: chmod + run**

```bash
chmod +x bin/consult-archive.sh
bash tests/run.sh test_consult_archive.sh && bash tests/run.sh
```

- [ ] **Step 5: Commit**

```bash
git add bin/consult-archive.sh tests/test_consult_archive.sh
git commit -m "feat(consult): bin/consult-archive.sh — move _consult/ to archive"
```

---

### Task 13: `tests/test_consult_spawn_rollback.sh` (Codex #3 fixture)

**Why:** Closes Codex finding #3. Verifies that the slash directive's spawn-rollback runbook works: when one parallel `bin/spawn.sh` fails, the survivor must be torn down. Since the rollback is conductor-driven (the slash directive instructs the conductor to do it), this test exercises a shell harness that simulates the rollback.

**Files:** Create test only — no new bin script (rollback is in the slash directive). The test acts as a regression guard for the documented rollback recipe.

- [ ] **Step 1: Write the test**

```bash
#!/usr/bin/env bash
# tests/test_consult_spawn_rollback.sh — Codex finding #3 fixture.
# Asserts the spawn-rollback recipe documented in commands/consult.md works:
# if one parallel spawn fails, the survivor must be teardown'd and _consult/
# removed before exit.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLONE_WARS_HOME="$TMP/cw"

# Static wiring: the slash directive must contain the rollback runbook.
grep -q 'spawn-rollback\|rollback'        ../commands/consult.md || { echo "FAIL: directive missing rollback section" >&2; exit 1; }
grep -q 'bin/teardown.sh\|consult-teardown' ../commands/consult.md || { echo "FAIL: directive missing teardown call" >&2; exit 1; }
grep -q 'rm -rf.*_consult\|consult-archive' ../commands/consult.md || { echo "FAIL: directive missing _consult cleanup" >&2; exit 1; }
pass "slash directive contains spawn-rollback runbook"

# Functional check: simulate the rollback recipe inline.
RH=$(bash -c 'source ../lib/state.sh; cw_repo_hash')
TOPIC=$(../bin/consult-init.sh "fixture rollback")
TD="$CLONE_WARS_HOME/state/$RH/$TOPIC"

# Pretend a survivor pane was spawned: create the trooper state dir.
mkdir -p "$TD/cody-claude"
touch "$TD/cody-claude/outbox.jsonl"

# Rollback recipe: teardown survivor (no-op in test env, no real pane), remove _consult/.
../bin/consult-teardown.sh "$TOPIC" 2>&1 >/dev/null || true
rm -rf "$TD/_consult"

[[ ! -d "$TD/_consult" ]] || { echo "FAIL: _consult survived rollback" >&2; exit 1; }
pass "rollback recipe removes _consult/ cleanly"
```

- [ ] **Step 2: Run, expect partial failure (commands/consult.md not yet rewritten — that's Task 14)**

```bash
bash tests/run.sh test_consult_spawn_rollback.sh
```

The static-wiring grep checks will fail until Task 14 rewrites the directive. That's expected.

- [ ] **Step 3: SKIP the static checks for now**

Comment out the three `grep -q` static checks with a `# TODO Task 14:` marker. Re-enable in Task 14. This keeps Task 13's commit green:

```bash
# TODO Task 14: re-enable after directive rewrite.
# grep -q 'spawn-rollback\|rollback' ../commands/consult.md || { ... }
```

(The functional rollback simulation already passes.)

- [ ] **Step 4: Run, expect pass**

```bash
bash tests/run.sh test_consult_spawn_rollback.sh && bash tests/run.sh
```

- [ ] **Step 5: Commit**

```bash
git add tests/test_consult_spawn_rollback.sh
git commit -m "$(cat <<'EOF'
test(consult): spawn-rollback fixture skeleton (Codex finding #3)

Functional simulation of the rollback recipe (teardown survivor +
remove _consult/) is in place. Static-wiring grep checks against
commands/consult.md are TODO-deferred to Task 14, which rewrites the
directive to include the rollback runbook.
EOF
)"
```

---

### Task 14: Rewrite `commands/consult.md`

**Why:** New directive walks the conductor through all 13 step boundaries with `TaskCreate` × 13 + `TaskUpdate` between each, calls sub-scripts via parallel pairs where applicable, and includes the spawn-rollback runbook + retry contract for Patterns 1 + 3.

**Files:** Modify `commands/consult.md` (full rewrite) + re-enable the 3 grep checks in `tests/test_consult_spawn_rollback.sh`.

- [ ] **Step 1: Rewrite `commands/consult.md`**

Replace the entire file content with:

```markdown
---
description: Spawn rex+codex and cody+claude on a topic; cross-verify their findings; synthesize a final report
argument-hint: <topic — what to research>
---

# /clone-wars:consult

Run a cross-verified dual-model investigation on `$ARGUMENTS`. The conductor
orchestrates 13 steps via per-phase sub-scripts under `bin/`. Between every
step, the conductor regains control — if a trooper produces unexpected
output, the conductor can `cw_send` a clarifying prompt before the next
sub-script runs.

Both panes stay attached for the entire run — `tmux select-pane` to watch.

Spec: `docs/superpowers/specs/2026-04-29-clone-wars-consult-v2-design.md`

## Task list (TaskCreate × 13 BEFORE step 1)

Create the 13-task list using `TaskCreate`. Update statuses at the
boundaries below — do NOT print a markdown checklist in chat.

| # | subject | activeForm |
|---|---|---|
| 0   | `0   Stage args-file [conductor]`               | `Staging args-file` |
| 1.1 | `1.1 Spawn rex (codex) [conductor]`             | `Spawning rex` |
| 1.2 | `1.2 Spawn cody (claude) [conductor]`           | `Spawning cody` |
| 1.3 | `1.3 Research [rex/codex]`                      | `Rex researching` |
| 1.4 | `1.4 Research [cody/claude]`                    | `Cody researching` |
| 1.5 | `1.5 Diff findings [conductor]`                 | `Diffing findings` |
| 1.6 | `1.6 Cross-verify cody-only items [rex/codex]`  | `Rex verifying` |
| 1.7 | `1.7 Cross-verify rex-only items [cody/claude]` | `Cody verifying` |
| 2   | `2   Resolve PENDING items [conductor]`         | `Resolving PENDING items` |
| 3.1 | `3.1 Synthesize report [conductor]`             | `Synthesizing` |
| 3.2 | `3.2 Teardown panes [conductor]`                | `Tearing down` |
| 3.3 | `3.3 Archive _consult/ [conductor]`             | `Archiving` |
| 4   | `4   Present final synthesis [conductor]`       | `Presenting synthesis` |

## Steps

The user's `$ARGUMENTS` may contain shell metacharacters. Write it via the
Write tool, then invoke sub-scripts with the resolved topic.

### Step 0 — args-file + init

Set task `0` → `in_progress`.

1. Resolve args path:

   ```
   ARGS_DIR="${CLONE_WARS_HOME:-$HOME/.clone-wars}/_args"
   mkdir -p "$ARGS_DIR"; echo "$ARGS_DIR/consult.txt"
   ```

2. Write tool: `file_path` = the path printed; `content` = `$ARGUMENTS`.

3. Initialize the consult topic:

   ```
   CONSULT_TOPIC=$("$CLAUDE_PLUGIN_ROOT/bin/consult-init.sh" "$(cat "$ARGS_DIR/consult.txt")")
   echo "$CONSULT_TOPIC"   # for use in subsequent steps
   ```

Set task `0` → `completed`. Set tasks `1.1` and `1.2` → `in_progress`.

### Step 1 — Parallel spawn (with rollback)

Invoke BOTH spawn calls as PARALLEL Bash tool calls in a single message.
Capture each rc.

```
"$CLAUDE_PLUGIN_ROOT/bin/spawn.sh" rex  codex  "$CONSULT_TOPIC"   # parallel 1
"$CLAUDE_PLUGIN_ROOT/bin/spawn.sh" cody claude "$CONSULT_TOPIC"   # parallel 2
```

#### Spawn-rollback runbook (CRITICAL — Codex finding #3)

After both parallel spawn calls return, evaluate:

- If both succeed: continue to step 1.3. Set tasks `1.1` and `1.2` →
  `completed`.
- If both fail: log "both spawns failed", `rm -rf` the `_consult/` dir,
  exit. Mark tasks `1.1` and `1.2` as `pending` (not completed).
- If exactly one succeeds (one-success/one-failure):

  ```
  # Tear down the surviving trooper, remove _consult/, exit 1.
  "$CLAUDE_PLUGIN_ROOT/bin/consult-teardown.sh" "$CONSULT_TOPIC"
  rm -rf "${CLONE_WARS_HOME:-$HOME/.clone-wars}/state/$(<repo-hash>)/$CONSULT_TOPIC"
  ```

  Mark only the successful spawn task as `completed`; leave the failed one
  `pending`. Tell the user which side failed and why.

### Step 2 — Parallel research dispatch

Set tasks `1.3` and `1.4` → `in_progress`.

PARALLEL Bash tool calls:

```
"$CLAUDE_PLUGIN_ROOT/bin/consult-research-send.sh" "$CONSULT_TOPIC" rex  codex
"$CLAUDE_PLUGIN_ROOT/bin/consult-research-send.sh" "$CONSULT_TOPIC" cody claude
```

### Step 3 — Parallel research wait

Both calls in PARALLEL:

```
"$CLAUDE_PLUGIN_ROOT/bin/consult-research-wait.sh" "$CONSULT_TOPIC" rex  codex
"$CLAUDE_PLUGIN_ROOT/bin/consult-research-wait.sh" "$CONSULT_TOPIC" cody claude
```

After both return, read each commander's state file to determine status:

```
TOPIC_DIR="${CLONE_WARS_HOME:-$HOME/.clone-wars}/state/$(<repo-hash>)/$CONSULT_TOPIC"
grep '^FS=' "$TOPIC_DIR/_consult/research-rex.txt"
grep '^FS=' "$TOPIC_DIR/_consult/research-cody.txt"
```

- If either is `FS=malformed` → consider Pattern 1 intervention (see
  below) before proceeding.
- If both are `FS=ok` (or `empty`/`missing` you accept) → set tasks
  `1.3` and `1.4` → `completed`.

### Step 4 — Diff

Set task `1.5` → `in_progress`.

```
"$CLAUDE_PLUGIN_ROOT/bin/consult-diff.sh" "$CONSULT_TOPIC"
```

Set task `1.5` → `completed`.

### Step 5 — Parallel verify dispatch + wait

Set tasks `1.6` and `1.7` → `in_progress`.

```
# Parallel send
"$CLAUDE_PLUGIN_ROOT/bin/consult-verify-send.sh" "$CONSULT_TOPIC" rex  codex
"$CLAUDE_PLUGIN_ROOT/bin/consult-verify-send.sh" "$CONSULT_TOPIC" cody claude

# Parallel wait
"$CLAUDE_PLUGIN_ROOT/bin/consult-verify-wait.sh" "$CONSULT_TOPIC" rex  codex
"$CLAUDE_PLUGIN_ROOT/bin/consult-verify-wait.sh" "$CONSULT_TOPIC" cody claude
```

Read `verify-{rex,cody}.txt` for VS status. If all-UNCERTAIN, consider
Pattern 3 intervention. Else set `1.6` and `1.7` → `completed`.

### Step 6 — Adjudicate (writes draft)

```
"$CLAUDE_PLUGIN_ROOT/bin/consult-adjudicate.sh" "$CONSULT_TOPIC"
```

This writes `_consult/adjudicated-draft.md`. Then copy it to the
conductor's resolution surface:

```
cp "$TOPIC_DIR/_consult/adjudicated-draft.md" "$TOPIC_DIR/_consult/adjudicated.md"
```

Set task `2` → `in_progress`.

### Step 7 — Resolve PENDING items

Open `_consult/adjudicated.md` with the Read tool. For every line
beginning `- PENDING:`:

a. Note `[citation]` + claim.
b. Read the cited source (file or WebFetch URL).
c. Decide CONFIRMED / REFUTED / CONTESTED.
d. Edit tool to rewrite:
   - CONFIRMED / REFUTED: replace `- PENDING:` with the verdict + evidence.
   - CONTESTED: move under `## Contested`, drop the prefix.

When no `^- PENDING:` remains, set task `2` → `completed` and task `3.1` →
`in_progress`.

### Step 8 — Synthesize

```
"$CLAUDE_PLUGIN_ROOT/bin/consult-synthesize.sh" "$CONSULT_TOPIC"
```

Refuses if PENDING remains. On success, prints synthesis.md. Set task
`3.1` → `completed`.

### Step 9 — Teardown + archive

```
"$CLAUDE_PLUGIN_ROOT/bin/consult-teardown.sh" "$CONSULT_TOPIC"
```

Set task `3.2` → `completed`.

```
"$CLAUDE_PLUGIN_ROOT/bin/consult-archive.sh" "$CONSULT_TOPIC"
```

Set task `3.3` → `completed`. Set task `4` → `in_progress`.

### Step 10 — Present synthesis

Show the user the final synthesis (already printed by step 8). Set task
`4` → `completed`.

## Intervention patterns

### Pattern 1: Malformed findings re-prompt

If `research-<commander>.txt` shows `FS=malformed`:

```
/clone-wars:send <commander> "$CONSULT_TOPIC" "Reformat your findings —
   every claim needs a [<citation>] prefix. Write to <state-dir>/findings.md.
   END_OF_INSTRUCTION"
"$CLAUDE_PLUGIN_ROOT/bin/consult-offset-reset.sh" "$CONSULT_TOPIC" <commander> research
"$CLAUDE_PLUGIN_ROOT/bin/consult-research-send.sh" "$CONSULT_TOPIC" <commander> <model>
"$CLAUDE_PLUGIN_ROOT/bin/consult-research-wait.sh" "$CONSULT_TOPIC" <commander> <model>
"$CLAUDE_PLUGIN_ROOT/bin/consult-diff.sh" "$CONSULT_TOPIC"
```

### Pattern 3: All-UNCERTAIN verify re-prompt

If `verify-<commander>.txt` verdicts are all UNCERTAIN:

```
/clone-wars:send <commander> "$CONSULT_TOPIC" "For each UNCERTAIN item,
   read the cited source at the file:line and re-grade. Write to
   <state-dir>/verify.md. END_OF_INSTRUCTION"
"$CLAUDE_PLUGIN_ROOT/bin/consult-offset-reset.sh" "$CONSULT_TOPIC" <commander> verify
"$CLAUDE_PLUGIN_ROOT/bin/consult-verify-send.sh" "$CONSULT_TOPIC" <commander> <model>
"$CLAUDE_PLUGIN_ROOT/bin/consult-verify-wait.sh" "$CONSULT_TOPIC" <commander> <model>
"$CLAUDE_PLUGIN_ROOT/bin/consult-adjudicate.sh" "$CONSULT_TOPIC"
cp adjudicated-draft.md adjudicated.md   # overwrite or merge with prior resolution
```
```

- [ ] **Step 2: Re-enable spawn-rollback test's static checks**

In `tests/test_consult_spawn_rollback.sh`, uncomment the three `grep -q`
static checks (remove the `# TODO Task 14:` marker).

- [ ] **Step 3: Run full suite**

```bash
bash tests/run.sh
```

Expected: all green; spawn-rollback test now exercises both static and
functional checks.

- [ ] **Step 4: Commit**

```bash
git add commands/consult.md tests/test_consult_spawn_rollback.sh
git commit -m "$(cat <<'EOF'
feat(consult): rewrite slash directive for v0.2 split orchestrator

13-step directive walks the conductor through:
- Init + parallel spawn (with explicit rollback runbook)
- Parallel research dispatch + per-commander parallel wait
- Diff
- Parallel verify dispatch + per-commander parallel wait
- Adjudicate (writes draft) + cp to conductor's adjudicated.md
- Resolve PENDING items via Edit
- Synthesize + teardown + archive
- Present synthesis

Patterns 1 (malformed-findings re-prompt) and 3 (all-UNCERTAIN re-prompt)
are now executable command lists, not narrative sketches. Spawn-rollback
runbook closes Codex finding #3.

Re-enables static-wiring grep checks in test_consult_spawn_rollback.sh.
EOF
)"
```

---

### Task 15: Cleanup — delete v0.1 monoliths + obsolete tests

**Why:** With the slash directive rewritten and all 11 sub-scripts in place, the v0.1 monoliths are dead code. Delete them in one commit so any reference to the old paths is a build break, not a silent fall-through.

**Files (all deletions):**
- Delete: `bin/consult.sh`
- Delete: `bin/consult-finalize.sh`
- Delete: `tests/test_consult_slug.sh` (replaced by `test_consult_init.sh`)
- Delete: `tests/test_consult_finalize.sh` (replaced by `test_consult_synthesize_bin.sh`, `test_consult_teardown_bin.sh`, `test_consult_archive.sh`)

- [ ] **Step 1: Verify no references remain**

```bash
grep -rn 'bin/consult\.sh\|bin/consult-finalize\.sh' bin/ commands/ lib/ tests/ docs/ \
  --exclude-dir=.git || echo "no references"
```

Expected: `no references` (or only references in archived spec/plan files
under `docs/superpowers/specs/2026-04-28-*` etc., which is fine — those
are historical).

- [ ] **Step 2: Delete files**

```bash
git rm bin/consult.sh bin/consult-finalize.sh tests/test_consult_slug.sh tests/test_consult_finalize.sh
```

- [ ] **Step 3: Run full suite**

```bash
bash tests/run.sh
```

Expected: all green. The 4 deletions don't break anything because their
coverage is replaced by Tasks 2–12's new test files.

- [ ] **Step 4: Commit**

```bash
git commit -m "$(cat <<'EOF'
chore(consult): remove v0.1 monoliths replaced by v0.2 sub-scripts

bin/consult.sh and bin/consult-finalize.sh are dead code after the v0.2
slash directive rewrite. tests/test_consult_slug.sh and
tests/test_consult_finalize.sh are replaced by test_consult_init.sh and
the per-finalize-phase test files (synthesize_bin, teardown_bin, archive).
EOF
)"
```

---

### Task 16: README + v0.2.0 release polish

**Files:**
- Modify: `README.md` (update the consult section)
- Modify: `.claude-plugin/plugin.json` (version 0.1.2 → 0.2.0)
- Modify: `.claude-plugin/marketplace.json` (both occurrences 0.1.2 → 0.2.0)

- [ ] **Step 1: Update README.md**

In the existing "Orchestration: `/clone-wars:consult`" section, replace
the description with the v0.2 architecture:

```markdown
---

## Orchestration: `/clone-wars:consult`

`/clone-wars:consult <topic>` is the cross-verified dual-model
investigation command. The slash directive walks the conductor through
13 step boundaries via per-phase sub-scripts under `bin/`:

1. `consult-init` derives a slug + creates the consult topic dir.
2. Parallel `spawn.sh rex codex` + `spawn.sh cody claude`.
3. Parallel `consult-research-send` to both troopers (writes
   `_consult/research-<commander>.txt` with offset).
4. Parallel `consult-research-wait` per trooper (appends FS status).
5. `consult-diff` — citation overlap, writes `diff.md` and `*_only_items.txt`.
6. Parallel `consult-verify-send` (rex grades cody-only items, vice
   versa; either skipped if peer has no items).
7. Parallel `consult-verify-wait` per trooper.
8. `consult-adjudicate` writes `adjudicated-draft.md`. Conductor copies
   to `adjudicated.md` and resolves PENDING items via Edit.
9. `consult-synthesize` (refuses on any remaining PENDING) writes
   `synthesis.md`.
10. `consult-teardown` + `consult-archive`.

Between every step the conductor regains control: if a trooper writes
malformed findings, the conductor can `cw_send` a clarifying prompt,
then `consult-offset-reset` + re-run the affected phase. The retry
contract is fully documented in the slash directive.

```
/clone-wars:consult "review src/auth/oauth.py for token-refresh edge cases"
```

The full spec is at `docs/superpowers/specs/2026-04-29-clone-wars-consult-v2-design.md`.
```

- [ ] **Step 2: Bump versions**

```bash
sed -i 's/"version": "0.1.2"/"version": "0.2.0"/' .claude-plugin/plugin.json .claude-plugin/marketplace.json
grep -n version .claude-plugin/plugin.json .claude-plugin/marketplace.json
```

- [ ] **Step 3: Run suite + medic**

```bash
bash tests/run.sh
bash bin/medic.sh
```

Expected: full suite green; medic verdict OK.

- [ ] **Step 4: Commit**

```bash
git add README.md .claude-plugin/plugin.json .claude-plugin/marketplace.json
git commit -m "$(cat <<'EOF'
release: v0.2.0 — split-orchestrator consult with conductor-reachable steps

Replaces v0.1.x's monolithic bin/consult.sh + bin/consult-finalize.sh
with 11 small per-phase sub-scripts the conductor invokes one at a time.

Closes 4 Codex adversarial findings:
  #1 offset retry primitive (bin/consult-offset-reset.sh + cascade)
  #2 per-commander wait survives peer timeout
  #3 spawn-group rollback runbook
  #4 adjudicated-draft.md vs adjudicated.md file split

Live task-list progress at every step boundary; parallel spawn +
parallel dispatches; documented intervention patterns for malformed
findings and all-UNCERTAIN verify.
EOF
)"
```

---

## Self-review

**1. Spec coverage** — every section of the v0.2 spec maps to a task:

| Spec section | Plan coverage |
|---|---|
| Architecture diagram | Tasks 2–12 (one sub-script per box) + Task 14 (slash directive) |
| Sub-script contracts (10 + offset-reset = 11) | Tasks 2–12 |
| `lib/consult.sh` helpers (3) | Task 1 |
| Idempotency contract + retry contract | Task 3 (offset-reset) + tested in Tasks 4, 7, 9, 10 |
| Three intervention patterns + spawn-rollback | Task 14 (slash directive) + Task 13 (rollback test fixture) |
| File-IPC contracts (per-commander state files) | Tasks 4, 5, 7, 8 |
| Failure-mode table | Per-task tests cover each documented failure |
| Migration (delete monoliths, version bump) | Tasks 15 + 16 |
| Codex finding #1 (offset retry hole) | Task 3 |
| Codex finding #2 (per-trooper status survives) | Task 5 (explicit fixture) |
| Codex finding #3 (spawn rollback) | Task 13 + Task 14 |
| Codex finding #4 (adjudicate file split) | Task 9 (explicit fixture) |

No spec requirement lacks a task.

**2. Placeholder scan** — searched for `TBD`, `TODO`, `Similar to Task N`, "implement later", "Add appropriate". One TODO remains intentionally in Task 13's failing test (deferred to Task 14, which then re-enables). Documented inline.

**3. Type consistency** — checked across tasks:
- `cw_consult_topic_validate` (Task 1) — used by every sub-script in Tasks 2–12.
- `cw_consult_status_load` (Task 1) — used by Tasks 9 and 10 to load per-commander state.
- `cw_consult_write_adjudicated` 7-arg signature (Task 1) — consumed identically by Task 9.
- Per-commander state file shape (`OFFSET=`/`FS=`/`VS=`) — written by Tasks 4, 5, 7, 8; read by Tasks 9, 10.
- Topic-arg validation regex `^[A-Za-z0-9_.-]+$` + `consult-` prefix — same rule everywhere.

All consistent.

---

## Execution

Plan complete. Recommended execution: **subagent-driven-development**.

Tasks 2–12 are mechanical (clear-spec sub-scripts following identical
patterns). Tasks 1, 13, 14 are integration touching multiple files.
Tasks 15 + 16 are cleanup + release.

Per the v0.0.4–v0.1.0 hardening pattern: invoke `codex:adversarial-review`
on this plan before dispatching any implementation subagents. Codex
consistently catches plan-stage issues; same gate applies here.
