# Clone Wars Consult — Design-Doc Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in design-doc phase to `/clone-wars:consult` that walks the user through brainstorming-style per-section approval over the synthesized investigation output, then writes `docs/clone-wars/specs/YYYY-MM-DD-<topic-slug>-design.md`.

**Architecture:** The investigation engine (Steps 1-8 of consult: research / verify / adjudicate / synthesize) is unchanged. A new Step 8.5 is added between synthesize and teardown. Step 8.5 has two entry conditions: implicit (auto-prompt when `cw_consult_classify_topic` returned `brainstorming`) or explicit (`--design-doc` flag). All five new helpers are pure functions on `lib/consult.sh`; the interactive walk lives in the directive (`commands/consult.md`); a new orchestrator script `bin/consult-design-doc.sh` does the final assembly + commit.

**Tech Stack:** Pure bash + tmux + file IPC. Uses existing helpers (`cw_consult_classify_topic`, `cw_outbox_wait_since`, `cw_state_root`, `cw_repo_hash`, `cw_consult_topic_validate`). No new runtime deps. Tests are bash scripts run by `tests/run.sh`.

---

## File Structure

**Created:**
- `lib/consult.sh` — five new helpers appended at end of file (sorted by call order):
  - `cw_consult_design_doc_filename`
  - `cw_consult_design_doc_assemble`
  - `cw_consult_design_doc_self_review`
  - `cw_consult_design_doc_drilldown_prompt`
  - `cw_consult_design_doc_resume_state`
- `bin/consult-design-doc.sh` — final-assembly + commit orchestrator (~80 lines).
- `tests/test_consult_design_doc_filename.sh`
- `tests/test_consult_design_doc_assemble.sh`
- `tests/test_consult_design_doc_self_review.sh`
- `tests/test_consult_design_doc_drilldown_prompt.sh`
- `tests/test_consult_design_doc_resume.sh`
- `tests/test_consult_design_doc_walkthrough.sh` — interactive manual test (committed but skipped by `tests/run.sh`).

**Modified:**
- `commands/consult.md` — adds Step 8.5 directive (~120 lines).
- `tests/run.sh` — adds `test_consult_design_doc_walkthrough.sh` to skip-list.
- `.claude-plugin/plugin.json` + `.claude-plugin/marketplace.json` — version 0.3.2 → 0.4.0.
- `README.md` — mention design-doc mode in feature table.
- `CLAUDE.md` — status checkbox for v0.4.0.

---

## Task 1: Helper — `cw_consult_design_doc_filename`

**Files:**
- Modify: `lib/consult.sh` (append at end)
- Test: `tests/test_consult_design_doc_filename.sh`

**Contract:** Given a topic slug (the suffix after `consult-`), emit `docs/clone-wars/specs/YYYY-MM-DD-<slug>-design.md`. Uses `${CW_TEST_DATE:-$(date +%Y-%m-%d)}` so tests can stub the date. Rejects empty slug or slug containing chars outside `[a-z0-9-]` with rc=2.

- [ ] **Step 1: Write the failing test**

Create `tests/test_consult_design_doc_filename.sh`:

```bash
#!/usr/bin/env bash
# tests/test_consult_design_doc_filename.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/state.sh
source ../lib/consult.sh

# Stub the date so tests are deterministic.
export CW_TEST_DATE=2026-04-29

# Happy path.
P=$(cw_consult_design_doc_filename "lru-vs-lfu") || { echo "FAIL: rc nonzero on valid slug"; exit 1; }
assert_eq "$P" "docs/clone-wars/specs/2026-04-29-lru-vs-lfu-design.md" "filename for valid slug"
pass "filename happy path"

# Empty slug rejects.
if cw_consult_design_doc_filename "" 2>/dev/null; then echo "FAIL: empty slug should reject"; exit 1; fi
pass "empty slug rejects"

# Slash in slug rejects.
if cw_consult_design_doc_filename "foo/bar" 2>/dev/null; then echo "FAIL: slash should reject"; exit 1; fi
pass "slash rejects"

# Uppercase rejects.
if cw_consult_design_doc_filename "FooBar" 2>/dev/null; then echo "FAIL: uppercase should reject"; exit 1; fi
pass "uppercase rejects"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_consult_design_doc_filename.sh`
Expected: FAIL with "command not found: cw_consult_design_doc_filename" or unbound function error.

- [ ] **Step 3: Implement helper**

Append to `lib/consult.sh`:

```bash
# cw_consult_design_doc_filename <topic-slug>  (v0.4.0)
# Emits docs/clone-wars/specs/YYYY-MM-DD-<slug>-design.md.
# Uses ${CW_TEST_DATE:-$(date +%Y-%m-%d)} for testability.
# Rejects empty slug or slug outside [a-z0-9-] with rc=2.
cw_consult_design_doc_filename() {
  local slug="${1:-}"
  [[ -n "$slug" ]] || { echo "cw_consult_design_doc_filename: empty slug" >&2; return 2; }
  [[ "$slug" =~ ^[a-z0-9-]+$ ]] || {
    echo "cw_consult_design_doc_filename: slug '$slug' has invalid chars (need [a-z0-9-])" >&2
    return 2
  }
  local date_str="${CW_TEST_DATE:-$(date +%Y-%m-%d)}"
  printf 'docs/clone-wars/specs/%s-%s-design.md\n' "$date_str" "$slug"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_consult_design_doc_filename.sh`
Expected: 4 PASS lines, rc=0.

- [ ] **Step 5: Commit**

```bash
git add lib/consult.sh tests/test_consult_design_doc_filename.sh
git commit -m "feat(consult): add cw_consult_design_doc_filename helper"
```

---

## Task 2: Helper — `cw_consult_design_doc_assemble`

**Files:**
- Modify: `lib/consult.sh` (append after Task 1's helper)
- Test: `tests/test_consult_design_doc_assemble.sh`

**Contract:** Given a section dir and an output path, concatenate `architecture.md`, `components.md`, `data-flow.md`, `error-handling.md`, `testing.md` with the standard header block prepended. If a section file is missing, insert `_(skipped)_` placeholder body under that section's heading. Header reads `Goal:`, `Architecture:`, `Tech Stack:` from the first paragraph of `architecture.md` (line 1 = goal; lines 2-4 of architecture file = architecture paragraph; lines under "## Tech Stack" if present, else empty list).

- [ ] **Step 1: Write the failing test**

Create `tests/test_consult_design_doc_assemble.sh`:

```bash
#!/usr/bin/env bash
# tests/test_consult_design_doc_assemble.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/consult.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
SECTIONS="$TMP/sections"; mkdir -p "$SECTIONS"
OUT="$TMP/design.md"

# Fixture: 4 sections present, error-handling missing.
cat > "$SECTIONS/architecture.md" <<'MD'
The system uses pane-based file IPC.

Two troopers run in tmux panes; conductor coordinates via inbox/outbox files.
The design-doc phase consumes their cross-verified output.

## Tech Stack
- bash 4.2+
- tmux 3.0+
MD

cat > "$SECTIONS/components.md" <<'MD'
- consult-design-doc.sh: orchestrator
- lib/consult.sh: helpers
MD

cat > "$SECTIONS/data-flow.md" <<'MD'
Inputs read from $TOPIC_DIR/_consult/.
MD

cat > "$SECTIONS/testing.md" <<'MD'
Five unit-style tests + one manual dogfood.
MD

# error-handling.md intentionally missing.

cw_consult_design_doc_assemble "$SECTIONS" "$OUT" "Test Topic"

[[ -s "$OUT" ]] || { echo "FAIL: output empty"; exit 1; }
grep -q '^# Test Topic Design$'                    "$OUT" || { echo "FAIL: title"; exit 1; }
grep -q '^\*\*Goal:\*\*'                           "$OUT" || { echo "FAIL: goal line"; exit 1; }
grep -q '^\*\*Architecture:\*\*'                   "$OUT" || { echo "FAIL: arch line"; exit 1; }
grep -q '^\*\*Tech Stack:\*\*'                     "$OUT" || { echo "FAIL: tech stack line"; exit 1; }
grep -q '^---$'                                    "$OUT" || { echo "FAIL: separator"; exit 1; }
grep -q '^## Architecture$'                        "$OUT" || { echo "FAIL: arch heading"; exit 1; }
grep -q '^## Components$'                          "$OUT" || { echo "FAIL: components heading"; exit 1; }
grep -q '^## Data Flow$'                           "$OUT" || { echo "FAIL: data flow heading"; exit 1; }
grep -q '^## Error Handling$'                      "$OUT" || { echo "FAIL: error handling heading"; exit 1; }
grep -q '^## Testing$'                             "$OUT" || { echo "FAIL: testing heading"; exit 1; }
grep -q '_(skipped)_'                              "$OUT" || { echo "FAIL: missing-section placeholder"; exit 1; }
pass "assemble produces full doc with skipped-section placeholder"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_consult_design_doc_assemble.sh`
Expected: FAIL — function not defined.

- [ ] **Step 3: Implement helper**

Append to `lib/consult.sh`:

```bash
# cw_consult_design_doc_assemble <section-dir> <output-path> <title>  (v0.4.0)
# Concatenates 5 section files into a single design doc with the standard
# header. Missing sections get a _(skipped)_ placeholder body.
cw_consult_design_doc_assemble() {
  local section_dir="$1" out="$2" title="$3"
  [[ -d "$section_dir" ]] || { echo "cw_consult_design_doc_assemble: missing $section_dir" >&2; return 1; }
  [[ -n "$title" ]] || { echo "cw_consult_design_doc_assemble: empty title" >&2; return 2; }

  # Header — pull goal/arch/tech-stack from architecture.md if present.
  local goal="(see Architecture section)" arch_line="(see Architecture section)" tech_block=""
  if [[ -f "$section_dir/architecture.md" ]]; then
    goal=$(head -n1 "$section_dir/architecture.md")
    # 2-3-sentence architecture paragraph: lines 3..first-blank-line-or-EOF.
    arch_line=$(awk 'NR>=3 && NF==0 {exit} NR>=3 {print}' "$section_dir/architecture.md" | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')
    [[ -n "$arch_line" ]] || arch_line="(see Architecture section)"
    # Tech Stack: anything under "## Tech Stack" line in architecture.md.
    tech_block=$(awk '/^## Tech Stack$/{flag=1; next} /^## /{flag=0} flag' "$section_dir/architecture.md")
  fi

  {
    printf '# %s Design\n\n' "$title"
    printf '**Goal:** %s\n\n' "$goal"
    printf '**Architecture:** %s\n\n' "$arch_line"
    printf '**Tech Stack:**\n'
    if [[ -n "$tech_block" ]]; then
      printf '%s\n' "$tech_block"
    else
      printf '- (see Components section)\n'
    fi
    printf '\n---\n\n'

    local section
    for section in architecture:Architecture components:Components data-flow:"Data Flow" error-handling:"Error Handling" testing:Testing; do
      local key="${section%%:*}" heading="${section##*:}"
      printf '## %s\n\n' "$heading"
      if [[ -f "$section_dir/$key.md" ]]; then
        cat "$section_dir/$key.md"
        printf '\n'
      else
        printf '_(skipped)_\n\n'
      fi
    done
  } > "$out"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_consult_design_doc_assemble.sh`
Expected: 1 PASS, rc=0.

- [ ] **Step 5: Commit**

```bash
git add lib/consult.sh tests/test_consult_design_doc_assemble.sh
git commit -m "feat(consult): add cw_consult_design_doc_assemble helper"
```

---

## Task 3: Helper — `cw_consult_design_doc_self_review`

**Files:**
- Modify: `lib/consult.sh` (append after Task 2's helper)
- Test: `tests/test_consult_design_doc_self_review.sh`

**Contract:** Scan a written doc for placeholder strings: `\bTBD\b`, `\bTODO\b`, `\bFIXME\b`, and bare three-dot ASCII (`\.\.\.`) when surrounded by alpha or whitespace (not inside a regex pattern itself). Report each match to stderr as `<path>:<lineno>: <line>`. rc=0 if clean, rc=1 if any match found. Does NOT auto-fix.

- [ ] **Step 1: Write the failing test**

Create `tests/test_consult_design_doc_self_review.sh`:

```bash
#!/usr/bin/env bash
# tests/test_consult_design_doc_self_review.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/consult.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Clean doc — rc=0.
CLEAN="$TMP/clean.md"
cat > "$CLEAN" <<'MD'
# Foo Design

This is a complete spec with no placeholders.
MD
cw_consult_design_doc_self_review "$CLEAN" 2>"$TMP/err1" || { echo "FAIL: clean doc should pass"; exit 1; }
[[ ! -s "$TMP/err1" ]] || { echo "FAIL: clean doc produced stderr"; cat "$TMP/err1"; exit 1; }
pass "clean doc passes"

# Doc with TBD.
DIRTY1="$TMP/dirty1.md"
cat > "$DIRTY1" <<'MD'
# Foo Design

The retry logic is TBD.
MD
if cw_consult_design_doc_self_review "$DIRTY1" 2>"$TMP/err2"; then
  echo "FAIL: TBD should fail"; exit 1
fi
grep -q 'TBD' "$TMP/err2" || { echo "FAIL: stderr should mention TBD"; exit 1; }
pass "TBD detected"

# Doc with bare ellipsis.
DIRTY2="$TMP/dirty2.md"
cat > "$DIRTY2" <<'MD'
# Foo Design

The flow goes here ... and then onward.
MD
if cw_consult_design_doc_self_review "$DIRTY2" 2>"$TMP/err3"; then
  echo "FAIL: bare ellipsis should fail"; exit 1
fi
pass "bare ellipsis detected"

# TBD inside fenced code block — still flagged (placeholders shouldn't appear anywhere).
DIRTY3="$TMP/dirty3.md"
cat > "$DIRTY3" <<'MD'
# Foo Design

```bash
echo TBD
```
MD
if cw_consult_design_doc_self_review "$DIRTY3" 2>/dev/null; then
  echo "FAIL: TBD in code fence should still flag"; exit 1
fi
pass "TBD in code fence still flagged (no false-negative)"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_consult_design_doc_self_review.sh`
Expected: FAIL — function not defined.

- [ ] **Step 3: Implement helper**

Append to `lib/consult.sh`:

```bash
# cw_consult_design_doc_self_review <doc-path>  (v0.4.0)
# Scans for placeholder strings (TBD/TODO/FIXME/bare ...).
# Reports each as <path>:<lineno>: <line> to stderr.
# rc=0 if clean, rc=1 if any match.
cw_consult_design_doc_self_review() {
  local doc="$1"
  [[ -f "$doc" ]] || { echo "cw_consult_design_doc_self_review: $doc not found" >&2; return 2; }
  local found=0
  # Word-boundaried TBD/TODO/FIXME.
  if grep -nE '\b(TBD|TODO|FIXME)\b' "$doc" >&2; then
    found=1
  fi
  # Bare three-dot — letters or whitespace on both sides (catches "x ... y", "go ...").
  if grep -nE '([[:alpha:]]|[[:space:]])\.\.\.([[:alpha:]]|[[:space:]]|$)' "$doc" >&2; then
    found=1
  fi
  return $found
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_consult_design_doc_self_review.sh`
Expected: 4 PASS, rc=0.

- [ ] **Step 5: Commit**

```bash
git add lib/consult.sh tests/test_consult_design_doc_self_review.sh
git commit -m "feat(consult): add cw_consult_design_doc_self_review helper"
```

---

## Task 4: Helper — `cw_consult_design_doc_drilldown_prompt`

**Files:**
- Modify: `lib/consult.sh` (append after Task 3's helper)
- Test: `tests/test_consult_design_doc_drilldown_prompt.sh`

**Contract:** Given a section name, synthesis path, commander, and design-doc dir, emit a focused inbox payload (multi-line string) instructing the trooper to drill into that section. Output ends with `END_OF_INSTRUCTION`. The trooper writes to `<design-doc-dir>/drilldown-<lower-section>-<commander>.md`.

- [ ] **Step 1: Write the failing test**

Create `tests/test_consult_design_doc_drilldown_prompt.sh`:

```bash
#!/usr/bin/env bash
# tests/test_consult_design_doc_drilldown_prompt.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/consult.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
SYN="$TMP/synthesis.md"; touch "$SYN"
DD_DIR="$TMP/_consult/design-doc"; mkdir -p "$DD_DIR"

P=$(cw_consult_design_doc_drilldown_prompt "Architecture" "$SYN" "rex" "$DD_DIR" "the trade-offs feel hand-wavy")
echo "$P" | grep -q 'Architecture'                           || { echo "FAIL: section name"; exit 1; }
echo "$P" | grep -q 'END_OF_INSTRUCTION$'                    || { echo "FAIL: sentinel"; exit 1; }
echo "$P" | grep -q 'drilldown-architecture-rex.md'          || { echo "FAIL: output path"; exit 1; }
echo "$P" | grep -qF "$SYN"                                  || { echo "FAIL: synthesis path"; exit 1; }
echo "$P" | grep -q 'hand-wavy'                              || { echo "FAIL: focus text"; exit 1; }
pass "drilldown prompt has section, sentinel, output path, synthesis ref, focus text"

# Lowercase + space-stripped section in output filename.
P2=$(cw_consult_design_doc_drilldown_prompt "Data Flow" "$SYN" "cody" "$DD_DIR" "")
echo "$P2" | grep -q 'drilldown-data-flow-cody.md' || { echo "FAIL: multi-word slug"; exit 1; }
pass "multi-word section produces hyphen-slug filename"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_consult_design_doc_drilldown_prompt.sh`
Expected: FAIL — function not defined.

- [ ] **Step 3: Implement helper**

Append to `lib/consult.sh`:

```bash
# cw_consult_design_doc_drilldown_prompt <section> <synthesis-path> <commander> <dd-dir> <focus>  (v0.4.0)
# Builds a focused inbox payload asking <commander> to drill into <section>.
# Trooper writes to <dd-dir>/drilldown-<slug>-<commander>.md.
# <focus> is optional pushback text from the user.
cw_consult_design_doc_drilldown_prompt() {
  local section="$1" syn="$2" commander="$3" dd_dir="$4" focus="${5:-}"
  local section_slug
  section_slug=$(printf '%s' "$section" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
  local out_path="$dd_dir/drilldown-${section_slug}-${commander}.md"

  cat <<EOF
You are drilling deeper into the **$section** section of a design doc derived
from the consultation you just completed.

Read the synthesis you produced: $syn

Focus: ${focus:-Provide more depth, citations, and concrete trade-offs for the $section section.}

Write your expanded notes (with [citation] anchors) to:
  $out_path

When done, append a {"event":"done"} line to your outbox as usual.

END_OF_INSTRUCTION
EOF
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_consult_design_doc_drilldown_prompt.sh`
Expected: 2 PASS, rc=0.

- [ ] **Step 5: Commit**

```bash
git add lib/consult.sh tests/test_consult_design_doc_drilldown_prompt.sh
git commit -m "feat(consult): add cw_consult_design_doc_drilldown_prompt helper"
```

---

## Task 5: Helper — `cw_consult_design_doc_resume_state`

**Files:**
- Modify: `lib/consult.sh` (append after Task 4's helper)
- Test: `tests/test_consult_design_doc_resume.sh`

**Contract:** Given a design-doc dir, list approved section keys (one per line, no extension) on stdout. A section is "approved" if its file exists and is non-empty (and is not a `drilldown-*` file). Missing dir returns empty stdout, rc=0.

- [ ] **Step 1: Write the failing test**

Create `tests/test_consult_design_doc_resume.sh`:

```bash
#!/usr/bin/env bash
# tests/test_consult_design_doc_resume.sh
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/consult.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
DD="$TMP/dd"

# Missing dir — empty stdout, rc=0.
mapfile -t L < <(cw_consult_design_doc_resume_state "$DD")
[[ "${#L[@]}" -eq 0 ]] || { echo "FAIL: missing dir should be empty"; exit 1; }
pass "missing dir → empty"

# 2 approved sections + 1 zero-byte (not counted) + 1 drilldown (excluded).
mkdir -p "$DD"
echo "content" > "$DD/architecture.md"
echo "content" > "$DD/components.md"
: > "$DD/data-flow.md"     # zero-byte — not counted
echo "x" > "$DD/drilldown-arch-rex.md"  # drilldown — excluded

mapfile -t L < <(cw_consult_design_doc_resume_state "$DD")
[[ "${#L[@]}" -eq 2 ]] || { echo "FAIL: expected 2 approved, got ${#L[@]} (${L[*]})"; exit 1; }
printf '%s\n' "${L[@]}" | grep -q '^architecture$' || { echo "FAIL: missing arch"; exit 1; }
printf '%s\n' "${L[@]}" | grep -q '^components$'   || { echo "FAIL: missing components"; exit 1; }
printf '%s\n' "${L[@]}" | grep -q 'drilldown'      && { echo "FAIL: drilldown leaked"; exit 1; }
pass "approved sections listed; zero-byte + drilldowns excluded"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_consult_design_doc_resume.sh`
Expected: FAIL — function not defined.

- [ ] **Step 3: Implement helper**

Append to `lib/consult.sh`:

```bash
# cw_consult_design_doc_resume_state <design-doc-dir>  (v0.4.0)
# Lists approved section keys (one per line, basename without .md).
# Excludes drilldown-* and zero-byte files. Missing dir → empty, rc=0.
cw_consult_design_doc_resume_state() {
  local dd="$1"
  [[ -d "$dd" ]] || return 0
  local f
  for f in "$dd"/*.md; do
    [[ -e "$f" ]] || continue                       # nullglob fallback
    [[ -s "$f" ]] || continue                       # zero-byte skipped
    local base; base=$(basename "$f" .md)
    [[ "$base" == drilldown-* ]] && continue
    printf '%s\n' "$base"
  done
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_consult_design_doc_resume.sh`
Expected: 2 PASS, rc=0.

- [ ] **Step 5: Commit**

```bash
git add lib/consult.sh tests/test_consult_design_doc_resume.sh
git commit -m "feat(consult): add cw_consult_design_doc_resume_state helper"
```

---

## Task 6: Orchestrator — `bin/consult-design-doc.sh`

**Files:**
- Create: `bin/consult-design-doc.sh`
- Test: (covered by Task 8 walkthrough fixture; this script does no `AskUserQuestion` itself.)

**Contract:** Given a `<consult-topic>` (e.g., `consult-lru-vs-lfu`), assembles the approved sections from `_consult/design-doc/` into the final spec doc, runs self-review, refuses on dirty self-review, otherwise commits the new file. The interactive walk happens in the directive — this script is the post-walk finalizer.

- [ ] **Step 1: Create the orchestrator**

Write `bin/consult-design-doc.sh`:

```bash
#!/usr/bin/env bash
# bin/consult-design-doc.sh — assemble + self-review + commit the design doc.
#
# Usage: bin/consult-design-doc.sh <consult-topic>
#
# Inputs:  $TOPIC_DIR/_consult/design-doc/{architecture,components,data-flow,error-handling,testing}.md
#          $TOPIC_DIR/_consult/topic.txt
# Output:  docs/clone-wars/specs/YYYY-MM-DD-<slug>-design.md  (committed)

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/consult.sh"

[[ $# -eq 1 ]] || { echo "Usage: $0 <consult-topic>" >&2; exit 2; }
TOPIC="$1"
cw_consult_topic_validate "$TOPIC" || { log_error "invalid topic: $TOPIC"; exit 2; }

TOPIC_DIR="$(cw_state_root)/state/$(cw_repo_hash)/$TOPIC"
DD_DIR="$TOPIC_DIR/_consult/design-doc"
[[ -d "$DD_DIR" ]] || { log_error "$DD_DIR not found — run Step 8.5 walk first"; exit 1; }

# Slug = topic with leading "consult-" stripped.
SLUG="${TOPIC#consult-}"
[[ -n "$SLUG" ]] || { log_error "topic '$TOPIC' produced empty slug"; exit 2; }

# Title — Title-Case the slug.
TITLE=$(printf '%s' "$SLUG" | tr '-' ' ' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))} 1')

OUT_REL=$(cw_consult_design_doc_filename "$SLUG") || exit $?
REPO_ROOT=$(cw_repo_root 2>/dev/null || pwd)
OUT_ABS="$REPO_ROOT/$OUT_REL"

# Refuse silent overwrite.
if [[ -e "$OUT_ABS" ]]; then
  log_error "$OUT_REL already exists; remove or rename before re-running"
  exit 1
fi

mkdir -p "$(dirname "$OUT_ABS")"
cw_consult_design_doc_assemble "$DD_DIR" "$OUT_ABS" "$TITLE" || {
  log_error "assemble failed"; exit 1
}

if ! cw_consult_design_doc_self_review "$OUT_ABS"; then
  log_error "self-review found placeholders in $OUT_REL"
  log_error "fix the offending sections (Step 8.5 will re-present them) then re-run"
  exit 1
fi

(cd "$REPO_ROOT" && \
  git add "$OUT_REL" && \
  git commit -m "docs(consult): add design doc for $SLUG" 2>&1) || {
  log_error "git commit failed; design.md is written but uncommitted"
  exit 1
}

log_info "[design-doc] wrote and committed $OUT_REL"
echo "$OUT_REL"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x bin/consult-design-doc.sh
```

- [ ] **Step 3: Smoke test invocation refuses without inputs**

Run: `bash bin/consult-design-doc.sh consult-nonexistent`
Expected: rc=1, stderr contains "design-doc not found" or equivalent — proves arg validation + missing-input refusal work without spawning troopers. Full happy-path smoke happens in Task 11 dogfood.

- [ ] **Step 4: Commit**

```bash
git add bin/consult-design-doc.sh
git commit -m "feat(consult): add consult-design-doc.sh orchestrator"
```

---

## Task 7: Directive — Step 8.5 in `commands/consult.md`

**Files:**
- Modify: `commands/consult.md`

**Contract:** Add Step 8.5 between "Step 8 — Synthesize" and "Step 9 — Teardown + archive". Two entry conditions (implicit via classifier prompt, explicit via `--design-doc` flag). Per-section walk uses `AskUserQuestion`. Drill-deeper sub-loop uses `cw_send` + `cw_outbox_wait_since` + read of drilldown file. Final assembly via `bin/consult-design-doc.sh`. User-review gate text verbatim from brainstorming SKILL.

- [ ] **Step 1: Locate insertion point**

Run: `grep -n '^### Step 9 — Teardown' commands/consult.md`
Expected: one match. Insert Step 8.5 before that line.

- [ ] **Step 2: Add the Step 8.5 directive block**

Insert (immediately before `### Step 9`):

````markdown
### Step 8.5 — Design-doc phase (v0.4.0, optional)

**Entry conditions** (skip Step 8.5 entirely if neither holds):

1. **Explicit flag.** The user invoked `/clone-wars:consult --design-doc <topic>`.
   The flag is parsed at Step 0 and stored in shell variable `DESIGN_DOC=1`.
2. **Implicit prompt.** No flag, but `cat "$TOPIC_DIR/_consult/skill.txt"` is `brainstorming`.
   Yoda calls `AskUserQuestion`:

   > "This consult topic looks design-shaped. Want me to walk through a design doc
   > (Architecture / Components / Data flow / Error handling / Testing) and write
   > it to `docs/clone-wars/specs/YYYY-MM-DD-<slug>-design.md`?"
   > Options: `Yes — walk through design doc` / `No — synthesis is enough`.

   Yes sets `DESIGN_DOC=1`; No falls through to Step 9.

If `DESIGN_DOC=0`, skip to Step 9.

**Setup:**

```bash
DD_DIR="$TOPIC_DIR/_consult/design-doc"
mkdir -p "$DD_DIR"
SECTIONS=(architecture components data-flow error-handling testing)
SECTION_TITLES=(Architecture Components "Data Flow" "Error Handling" Testing)

# Resume detection — skip already-approved sections (offer reuse/redo first).
mapfile -t APPROVED < <("$CLAUDE_PLUGIN_ROOT/bin/consult-design-doc.sh" --resume-state "$TOPIC" 2>/dev/null) || true
```

**Per-section loop:**

For each `i` in `0..4`:

1. `key=${SECTIONS[$i]}; title=${SECTION_TITLES[$i]}`
2. If `$key` is in `${APPROVED[@]}`:
   `AskUserQuestion`: "Section '$title' already approved. Reuse / Redo / Skip?"
   - Reuse → continue to next section.
   - Redo → delete `$DD_DIR/$key.md`, fall through to draft loop.
   - Skip → write `_(skipped — user chose skip on resume)_` and continue.
3. **Draft loop:**
   - Yoda reads `$TOPIC_DIR/_consult/synthesis.md`, `adjudicated.md`, both
     troopers' `findings.md` and `verify.md`, drafts the section text inline.
   - Yoda presents the draft in chat (markdown).
   - `AskUserQuestion`: "Section '$title' — Approve / Revise / Drill deeper / Skip?"
   - Cases:
     - **Approve** → `printf '%s' "<draft>" > "$DD_DIR/$key.md"`; break draft loop.
     - **Revise** → `AskUserQuestion`: "What should change?" (free-form); fold response into draft; re-loop.
     - **Drill deeper** → see drill-down sub-loop below; on return, fold drilldown content into draft; re-loop.
     - **Skip** → `printf '_(skipped)_\n' > "$DD_DIR/$key.md"`; break draft loop.

**Drill-down sub-loop:**

```
AskUserQuestion: "Which trooper to drill the section?"
  options: rex (codex) / cody (claude)
commander=<chosen>
model=<rex→codex, cody→claude>

AskUserQuestion: "What's the focus? (e.g., 'trade-offs feel hand-wavy', 'show concrete error paths')"
focus=<free-form text>

# Build payload + record outbox cursor before send.
PROMPT=$(cw_consult_design_doc_drilldown_prompt "$title" \
  "$TOPIC_DIR/_consult/synthesis.md" "$commander" "$DD_DIR" "$focus")
OFFSET=$(wc -c < "$(cw_trooper_dir "$commander" "$model" "$TOPIC")/outbox.jsonl" 2>/dev/null || echo 0)

# Dispatch.
"$CLAUDE_PLUGIN_ROOT/bin/send.sh" "$commander" "$TOPIC" "$PROMPT"

# Wait for done. 90s default per contracts.yaml; reuse findings_timeout_s.
TIMEOUT=$(awk -F: '/findings_timeout_s/{gsub(/[^0-9]/,"",$2); print $2; exit}' \
  "${CLONE_WARS_HOME:-$HOME/.clone-wars}/contracts.yaml")
TIMEOUT=${TIMEOUT:-90}

if cw_outbox_wait_since "$commander" "$model" "$TOPIC" "$OFFSET" \
     "done|error" "$TIMEOUT" >/dev/null; then
  DRILL="$DD_DIR/drilldown-${title,,}-${commander}.md"
  DRILL="${DRILL// /-}"
  if [[ -s "$DRILL" ]]; then
    log_info "[design-doc] folded drilldown into draft for $title"
    # Yoda reads $DRILL and incorporates into the section draft.
  else
    AskUserQuestion: "Drill-down completed but $DRILL is empty. Continue / Retry / Other trooper / Skip?"
  fi
else
  AskUserQuestion: "Drill-down on $title timed out. Retry / Pick other trooper / Skip drill / Continue with current draft?"
fi
```

**Finalize:**

After all 5 sections processed:

```bash
"$CLAUDE_PLUGIN_ROOT/bin/consult-design-doc.sh" "$TOPIC" || {
  # Self-review failed — script exits nonzero with placeholder report on stderr.
  # Loop back to per-section walk for the offending sections.
  # (Implementation: parse stderr for "<file>:<lineno>: <line>", map back to
  # section by line range in the assembled doc, force the user back to that
  # section's draft loop with the placeholder pre-highlighted.)
  exit 1
}
```

**User-review gate** (verbatim from superpowers:brainstorming SKILL):

> "Spec written and committed to `<path>`. Please review it and let me know
> if you want to make any changes before we start writing out the
> implementation plan."

Wait for user response. If they request changes, edit + amend commit. Only proceed to Step 9 once user approves.
````

- [ ] **Step 3: Add `--design-doc` flag plumbing to Step 0**

Locate `### Step 0 —` in `commands/consult.md`. Add to the parsing logic:

```markdown
**Flag parsing:**

Before stage args-file, scan the raw user argument for `--design-doc`:
- If present, `DESIGN_DOC=1` and strip the flag from the topic text before writing args-file.
- If absent, `DESIGN_DOC=0` (default).

Use shell:
```
ARG_RAW="$ARGUMENTS"
DESIGN_DOC=0
if [[ "$ARG_RAW" == *"--design-doc"* ]]; then
  DESIGN_DOC=1
  ARG_RAW=$(echo "$ARG_RAW" | sed 's/--design-doc//' | sed 's/  */ /g; s/^ //; s/ $//')
fi
```
Use `$ARG_RAW` for the topic text from this point.
```

- [ ] **Step 4: Update task list at the top of consult.md**

Add a 14th task:
```markdown
| 3.5 | `3.5 Design-doc phase (optional) [yoda]` | `Walking design-doc sections` |
```
Place it between `3.1` (Synthesize) and `3.2` (Teardown panes).

- [ ] **Step 5: Sanity check the directive parses cleanly**

Run: `grep -c '^### Step' commands/consult.md`
Expected: 12 (was 11; added Step 8.5).

- [ ] **Step 6: Commit**

```bash
git add commands/consult.md
git commit -m "feat(consult): add Step 8.5 design-doc directive"
```

---

## Task 8: Skip-list update + run full suite green

**Files:**
- Modify: `tests/run.sh`
- Create: `tests/test_consult_design_doc_walkthrough.sh` (manual stub)

- [ ] **Step 1: Create walkthrough stub**

Create `tests/test_consult_design_doc_walkthrough.sh`:

```bash
#!/usr/bin/env bash
# tests/test_consult_design_doc_walkthrough.sh — MANUAL DOGFOOD ONLY.
#
# This test is skipped by tests/run.sh because it requires a live tmux
# session, real codex+claude binaries, and an interactive operator to walk
# through 5 sections of AskUserQuestion prompts. Run it directly when
# dogfooding v0.4.0 design-doc mode:
#
#   /clone-wars:consult --design-doc "decide between LRU and LFU cache eviction"
#
# Verifies:
#   1. Step 8.5 enters when --design-doc flag is present.
#   2. Per-section AskUserQuestion fires for all 5 sections.
#   3. Drill-deeper path on at least one section produces drilldown-*.md.
#   4. Final docs/clone-wars/specs/YYYY-MM-DD-...-design.md lands and is committed.
#   5. Re-running on same topic same day triggers overwrite-refuse path.
#   6. Aborting mid-walkthrough leaves design-doc/ dir intact for resume.
echo "MANUAL — see header for steps"
exit 0
```

- [ ] **Step 2: Add to run.sh skip-list**

Edit `tests/run.sh` — find the existing skip clause for question dogfood tests and add the walkthrough alongside:

```bash
# Existing clause (find this):
case "$t" in
  *test_consult_question_dogfood_*) continue ;;
esac

# Update to:
case "$t" in
  *test_consult_question_dogfood_*) continue ;;
  *test_consult_design_doc_walkthrough*) continue ;;
esac
```

- [ ] **Step 3: Run full suite — verify green**

Run: `bash tests/run.sh`
Expected: all tests pass, rc=0; the 5 new design-doc tests run; walkthrough is skipped.

- [ ] **Step 4: Commit**

```bash
git add tests/run.sh tests/test_consult_design_doc_walkthrough.sh
git commit -m "test(consult): skip design-doc walkthrough in run.sh (manual gate)"
```

---

## Task 9: Update README + CLAUDE.md status

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update README feature mention**

In `README.md`, find the section listing consult features (likely around the v0.3 question protocol bullet). Add:

```markdown
- **`/clone-wars:consult --design-doc <topic>`** (v0.4.0) — after the
  cross-verified investigation, walks the user through a per-section
  approval flow (Architecture / Components / Data flow / Error handling /
  Testing) and commits a `docs/clone-wars/specs/YYYY-MM-DD-<slug>-design.md`.
  Without the flag, design-shaped topics auto-prompt; investigation topics
  end at synthesis.md as before.
```

- [ ] **Step 2: Update CLAUDE.md Status section**

Append to the Status checklist:

```markdown
- [x] v0.4.0: design-doc mode — opt-in brainstorming-style spec output (Step 8.5)
```

- [ ] **Step 3: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "docs(v0.4.0): mention design-doc mode in README + CLAUDE.md"
```

---

## Task 10: Version bump 0.3.2 → 0.4.0

**Files:**
- Modify: `.claude-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json`

- [ ] **Step 1: Bump plugin.json**

Edit `.claude-plugin/plugin.json`:
```json
"version": "0.3.2"   →   "version": "0.4.0"
```

- [ ] **Step 2: Bump marketplace.json**

Edit `.claude-plugin/marketplace.json`:
```json
"version": "0.3.2"   →   "version": "0.4.0"   (both top-level "version" and plugins[0].version)
```

- [ ] **Step 3: Verify both changed**

Run: `grep -n '"version"' .claude-plugin/*.json`
Expected: all three lines say `"version": "0.4.0"`.

- [ ] **Step 4: Run tests one more time**

Run: `bash tests/run.sh`
Expected: green, rc=0.

- [ ] **Step 5: Commit**

```bash
git add .claude-plugin/plugin.json .claude-plugin/marketplace.json
git commit -m "chore(release): bump version to 0.4.0"
```

---

## Task 11: Manual dogfood + tag

**Files:** none modified.

- [ ] **Step 1: Open a fresh tmux window**

```bash
tmux new -s cw-dogfood
```
Run inside it.

- [ ] **Step 2: Reload plugin in a Claude Code session**

In Claude Code: `/plugin update clone-wars` then `/reload-plugins`.

- [ ] **Step 3: Run explicit-flag dogfood**

Type to Claude Code:
```
/clone-wars:consult --design-doc decide between LRU and LFU cache eviction
```
- Confirm Step 8.5 enters automatically (no implicit prompt — flag was set).
- Walk all 5 sections.
- On the **Architecture** section, choose "Drill deeper" → pick rex → focus "show concrete eviction-cost trade-offs" → verify drilldown file lands and content folds into draft.
- Approve all sections.

- [ ] **Step 4: Verify the spec was written and committed**

```bash
ls docs/clone-wars/specs/
git log -1 --stat docs/clone-wars/specs/
```
Expected: file `YYYY-MM-DD-decide-between-lru-an-design.md` (slug truncated to 20 chars by init) listed; one commit reference.

- [ ] **Step 5: Run overwrite-refuse path**

Re-run the same command. Expected behavior: Yoda surfaces the existing-file error and asks (overwrite / suffix / abort). Pick abort.

- [ ] **Step 6: Run implicit-prompt dogfood**

```
/clone-wars:consult should we use Redis or Memcached for the session store
```
- No flag — classifier should mark `brainstorming` (per `cw_consult_classify_topic` regex).
- Confirm the auto-prompt fires after synthesis.
- Decline ("synthesis is enough") — confirm Step 9 runs and no design.md is written.

- [ ] **Step 7: Run non-design topic — confirm no prompt**

```
/clone-wars:consult review the auth middleware for security bugs
```
- Classifier should mark `systematic-debugging`.
- Confirm NO auto-prompt fires; consult ends at synthesis.md.

- [ ] **Step 8: Tag the release**

```bash
git tag v0.4.0
git push origin main --tags
```

- [ ] **Step 9: Verify on the marketplace side**

In a Claude Code session:
```
/plugin update clone-wars
/reload-plugins
```
Confirm version reads 0.4.0.

---

## Self-Review (controller, before handoff)

Spec coverage check:
- Architecture (spec §3) → Tasks 6, 7 ✓
- Components (spec §4) → Tasks 1-7 (5 helpers + orchestrator + directive) ✓
- Data Flow (spec §5) → Task 7 (directive Step 8.5) covers the per-section loop and drill-down IPC ✓
- Error Handling (spec §6) → Tasks 6 (refuse-overwrite, self-review-fail), 7 (timeout/abort/skip via `AskUserQuestion`) ✓
- Testing (spec §7) → Tasks 1-5 (one test per helper), Task 8 (run.sh skip), Task 11 (manual dogfood) ✓

Placeholder scan: none in plan steps — every step has executable code or exact commands.

Type consistency:
- Helper names match across spec, plan, and tests.
- File paths are absolute or relative-to-repo-root consistently.
- `<topic>` always means the full `consult-<slug>` form; `<slug>` always means the post-`consult-` suffix used in the design.md filename.

Plan complete and saved to `docs/superpowers/plans/2026-04-29-clone-wars-consult-design-doc-mode-plan.md`.
