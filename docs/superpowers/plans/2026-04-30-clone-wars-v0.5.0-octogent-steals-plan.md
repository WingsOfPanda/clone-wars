# Clone Wars v0.5.0 — Octogent Steals Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land four octogent-inspired primitives (prompt-template registry, lifecycle stale state, `cw_send --from` sender attribution, background-await pattern) as a single coherent v0.5.0 release that makes Master Yoda observable, identifiable, and interactive during long waits.

**Architecture:** Pure bash + tmux + file IPC. New helper `cw_consult_load_prompt` reads versioned mustache templates under `config/prompt-templates/`. `bin/list.sh` gains a display-only `stale` classifier driven by outbox mtime. `cw_send` accepts an optional `--from` flag whose default keeps every existing call site working unchanged. The directive (`commands/consult.md`) flips long `cw_outbox_wait_since`-bound calls to `run_in_background:true`, and the wait-scripts touch a `.done` sentinel after writing terminal `FS=` so the controller can distinguish a clean exit from a notification race.

**Tech Stack:** bash 4.2+, tmux, sed (mustache substitution), `stat` (GNU + BSD fallback for mtime), Claude Code's `Bash(run_in_background: true)` background-task primitive.

**Plan deviations from spec:** the spec listed five `consult/design-doc/<section>.md` templates as future migration targets; in v0.4.2 those sections are produced by trooper synthesis, not by inline-prompt code, so there is no byte-equality baseline to regression-test against. This plan defers the `design-doc/*.md` template family to v0.5.1+ once a concrete inline prompt exists. The other three templates (`research.md`, `verify.md`, `drilldown.md`) ship in v0.5.0 as planned.

---

## File Structure

**Created (5 new files):**

- `config/prompt-templates/identity.md` — moved from `config/identity-template.md`.
- `config/prompt-templates/consult/research.md` — extracted from `cw_consult_build_research_prompt`.
- `config/prompt-templates/consult/verify.md` — extracted from `cw_consult_build_verify_prompt`.
- `config/prompt-templates/consult/drilldown.md` — extracted from `cw_consult_design_doc_drilldown_prompt`.
- `config/identity-template.md` — replaced by a relative symlink to the new path (one-release back-compat; drop in v0.6).

**New helpers (in existing files):**

- `lib/consult.sh::cw_consult_load_prompt` — mustache renderer with surviving-token guard.
- `lib/ipc.sh::cw_send` *(does not currently exist as a separate function)* → introduced in Task 7 as a thin wrapper around `cw_inbox_write` plus the new `--from` header handling. Existing callers keep using `cw_inbox_write` directly; new flag-aware path goes through `cw_send`.

**Modified (existing files):**

- `lib/ipc.sh` — `cw_identity_write` updated to read the new `prompt-templates/identity.md` location, with the existing `$CLONE_WARS_HOME/identity-template.md` user-override path retained.
- `lib/consult.sh` — `cw_consult_build_research_prompt`, `cw_consult_build_verify_prompt`, and `cw_consult_design_doc_drilldown_prompt` collapse from heredocs to single `cw_consult_load_prompt` calls.
- `bin/list.sh` — adds `stale` classification based on outbox mtime + `CW_STALE_THRESHOLD_S` env override.
- `bin/consult-research-wait.sh` + `bin/consult-verify-wait.sh` — `touch "$STATE_FILE.done"` immediately before exit, after the existing `FS=` write.
- `commands/consult.md` — Steps 3 and 5 flip wait-script invocations to `Bash(run_in_background: true)`; question-protocol re-arm path uses background re-spawn instead of foreground await.
- `config/prompt-templates/identity.md` — gains a single line about the optional `From: <sender>` header.
- `.claude-plugin/plugin.json` + `.claude-plugin/marketplace.json` — bump `0.4.2` → `0.5.0`.
- `CLAUDE.md` + `README.md` — status checklist + release-notes preview.

**New tests (6 new test files):**

- `tests/test_consult_load_prompt.sh` — A: helper unit tests.
- `tests/test_consult_load_prompt_migration.sh` — A: byte-equality regression guard against pre-refactor heredoc output.
- `tests/test_list_stale.sh` — B: stale rendering cases.
- `tests/test_send_from_flag.sh` — C: sender-attribution cases.
- `tests/test_consult_wait_state_file.sh` — D: `.done` sentinel + final `FS=` line invariants.
- `tests/test_consult_wait_question_rearm.sh` — D: question→re-arm loop survives the foreground→background flip.
- `tests/test_consult_v050_dogfood.sh` — D: manual T7 dogfood checklist (skipped by `tests/run.sh`).

---

## Task Ordering

| # | Task | Bundle | Depends on |
|---|---|---|---|
| 1 | `cw_consult_load_prompt` helper + unit tests | A | — |
| 2 | Move `identity-template.md` → `prompt-templates/identity.md` + back-compat symlink | A | T1 |
| 3 | Migrate research prompt to template | A | T1, T2 |
| 4 | Migrate verify prompt to template | A | T1, T2 |
| 5 | Migrate drilldown prompt to template | A | T1, T2 |
| 6 | Stale state in `bin/list.sh` | B | — (independent) |
| 7 | `cw_send --from` flag + identity-template note | C | T2 (identity location) |
| 8 | `.done` sentinel in wait-scripts | D | — (independent) |
| 9 | Question→re-arm regression test under background semantics | D | T8 |
| 10 | `commands/consult.md` Step 3 (research) → background-await | D | T8, T9 |
| 11 | `commands/consult.md` Step 5 (verify) → background-await | D | T8, T9, T10 |
| 12 | Release polish: version bump, README, CLAUDE.md, manual T7 stub | — | all prior |

Execution order respects dependencies. Tasks 1, 6, 8 are leaf entry points and could run in parallel under `subagent-driven-development`; sequential ordering shown is the default for `executing-plans`.

---

## Task 1: `cw_consult_load_prompt` helper + unit tests (A)

**Files:**
- Modify: `lib/consult.sh` (append new helper near the end of file, before final `# vim:` line if any).
- Test: `tests/test_consult_load_prompt.sh` (new file).
- Reference: `tests/test_consult_flag_parse.sh:1-60` (test pattern), `lib/consult.sh:686-707` (existing heredoc pattern for sanity).

- [ ] **Step 1: Write the failing test**

Create `tests/test_consult_load_prompt.sh`:

```bash
#!/usr/bin/env bash
# tests/test_consult_load_prompt.sh — v0.5.0 prompt-template loader unit tests.
#
# Contract: cw_consult_load_prompt <relpath> [VAR=value ...]
#   - Reads $CLAUDE_PLUGIN_ROOT/config/prompt-templates/<relpath>
#   - Substitutes {{VAR}} tokens via single-pass sed
#   - rc=1 if template missing, rc=2 if any {{VAR}} survives substitution
#   - Refuses if CLAUDE_PLUGIN_ROOT unset (rc=2)
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

# Sandbox: stub plugin root with a fake template tree so the loader has
# something real to read without depending on the live config/.
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/config/prompt-templates/consult"
export CLAUDE_PLUGIN_ROOT="$SANDBOX"
PLUGIN_ROOT="$SANDBOX"
source ../lib/log.sh
source ../lib/consult.sh

# Case 1: simple substitution.
cat > "$SANDBOX/config/prompt-templates/consult/hello.md" <<'EOF'
hello {{NAME}}!
EOF
out=$(cw_consult_load_prompt consult/hello.md NAME=world)
[[ "$out" == "hello world!" ]] || { echo "FAIL c1 got '$out'"; exit 1; }
pass "simple {{NAME}} substitution"

# Case 2: multiple variables, single pass.
cat > "$SANDBOX/config/prompt-templates/consult/multi.md" <<'EOF'
{{A}}-{{B}}-{{A}}
EOF
out=$(cw_consult_load_prompt consult/multi.md A=foo B=bar)
[[ "$out" == "foo-bar-foo" ]] || { echo "FAIL c2 got '$out'"; exit 1; }
pass "multi-variable substitution"

# Case 3: missing template → rc=1.
if cw_consult_load_prompt consult/nope.md X=y 2>/dev/null; then
  echo "FAIL c3: expected rc=1 on missing template"; exit 1
fi
pass "missing template → rc=1"

# Case 4: surviving {{VAR}} → rc=2.
cat > "$SANDBOX/config/prompt-templates/consult/incomplete.md" <<'EOF'
hello {{NAME}}, today is {{DATE}}
EOF
if cw_consult_load_prompt consult/incomplete.md NAME=world 2>/dev/null; then
  echo "FAIL c4: expected rc=2 on surviving {{DATE}}"; exit 1
fi
pass "surviving {{VAR}} → rc=2"

# Case 5: special chars in value (sed delimiter pipe + ampersand).
cat > "$SANDBOX/config/prompt-templates/consult/special.md" <<'EOF'
path={{PATH}}
EOF
out=$(cw_consult_load_prompt consult/special.md "PATH=/a|b/c&d")
[[ "$out" == "path=/a|b/c&d" ]] || { echo "FAIL c5 got '$out'"; exit 1; }
pass "special chars (| &) in value"

# Case 6: newline in value.
cat > "$SANDBOX/config/prompt-templates/consult/nl.md" <<'EOF'
body={{BODY}}
EOF
out=$(cw_consult_load_prompt consult/nl.md "BODY=line1
line2")
expected="body=line1
line2"
[[ "$out" == "$expected" ]] || { echo "FAIL c6 got '$out'"; exit 1; }
pass "newline preserved in value"

# Case 7: missing CLAUDE_PLUGIN_ROOT → rc=2.
unset CLAUDE_PLUGIN_ROOT
unset PLUGIN_ROOT
if cw_consult_load_prompt consult/hello.md NAME=x 2>/dev/null; then
  echo "FAIL c7: expected rc=2 with no CLAUDE_PLUGIN_ROOT"; exit 1
fi
pass "missing CLAUDE_PLUGIN_ROOT → rc=2"

echo "ALL PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_consult_load_prompt.sh`
Expected: FAIL with `cw_consult_load_prompt: command not found` (function not yet defined).

- [ ] **Step 3: Write minimal implementation**

Append to `lib/consult.sh` (just before the final shebang/end):

```bash
# cw_consult_load_prompt <relpath> [VAR=value ...]  (v0.5.0)
# Reads $CLAUDE_PLUGIN_ROOT/config/prompt-templates/<relpath> and substitutes
# every {{VAR}} placeholder using single-pass sed. Returns:
#   rc=0 — rendered prompt printed to stdout
#   rc=1 — template not found (path printed to stderr)
#   rc=2 — bad call (no CLAUDE_PLUGIN_ROOT, surviving {{VAR}}, or no relpath)
#
# Single-pass: a value containing {{...}} is NOT recursively expanded; if a
# user-supplied value reintroduces a placeholder the surviving-token guard
# fires. This is the safer behavior — recursion would amplify mistakes.
cw_consult_load_prompt() {
  local relpath="${1:-}"
  [[ -n "$relpath" ]] || { echo "cw_consult_load_prompt: relpath required" >&2; return 2; }
  shift
  local plugin_root="${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}"
  [[ -n "$plugin_root" ]] || { echo "cw_consult_load_prompt: CLAUDE_PLUGIN_ROOT not set" >&2; return 2; }
  local tmpl="$plugin_root/config/prompt-templates/$relpath"
  [[ -f "$tmpl" ]] || { echo "cw_consult_load_prompt: template not found: $tmpl" >&2; return 1; }

  # Build a sed script: one s|{{KEY}}|escaped-value|g per VAR=value pair.
  # Pipe delimiter so / in values stays literal; escape \, &, and | in value.
  local script="" pair key val esc
  for pair in "$@"; do
    key="${pair%%=*}"
    val="${pair#*=}"
    [[ "$pair" == *=* && -n "$key" ]] || { echo "cw_consult_load_prompt: bad VAR=value '$pair'" >&2; return 2; }
    esc=${val//\\/\\\\}    # \  → \\
    esc=${esc//&/\\&}      # &  → \&
    esc=${esc//|/\\|}      # |  → \|
    esc=${esc//$'\n'/\\$'\n'}   # newlines: sed `s` needs a literal newline escape
    script+="s|{{${key}}}|${esc}|g;"
  done

  local rendered
  rendered=$(sed -e "$script" "$tmpl") || return 1

  if printf '%s\n' "$rendered" | grep -qE '\{\{[A-Z_][A-Z0-9_]*\}\}'; then
    {
      echo "cw_consult_load_prompt: unresolved placeholders in $relpath:"
      printf '%s\n' "$rendered" | grep -oE '\{\{[A-Z_][A-Z0-9_]*\}\}' | sort -u | sed 's/^/  /'
    } >&2
    return 2
  fi

  printf '%s\n' "$rendered"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_consult_load_prompt.sh`
Expected: 7x `pass` lines, then `ALL PASS`, exit 0.

- [ ] **Step 5: Run the full suite to confirm no regressions**

Run: `bash tests/run.sh`
Expected: every `=== test_*.sh ===` line followed by `ok`; exit 0.

- [ ] **Step 6: Commit**

```bash
git add lib/consult.sh tests/test_consult_load_prompt.sh
git commit -m "feat(consult): add cw_consult_load_prompt mustache template loader (v0.5.0 #1)"
```

---

## Task 2: Move `identity-template.md` to `prompt-templates/` + back-compat symlink (A)

**Files:**
- Create: `config/prompt-templates/identity.md` (moved from `config/identity-template.md`).
- Modify: `config/identity-template.md` (replaced by a relative symlink).
- Modify: `lib/ipc.sh` `cw_identity_write` (add new template path to lookup chain).
- Reference: `lib/ipc.sh:60-94` (existing `cw_identity_write` body).

- [ ] **Step 1: Move the file**

```bash
mkdir -p config/prompt-templates/consult
git mv config/identity-template.md config/prompt-templates/identity.md
ln -s prompt-templates/identity.md config/identity-template.md
git add config/identity-template.md
```

- [ ] **Step 2: Verify the symlink resolves**

Run: `cat config/identity-template.md | head -1`
Expected: same first line as `cat config/prompt-templates/identity.md | head -1` (the original "You are **{{commander}}**..." line).

- [ ] **Step 3: Update `cw_identity_write` lookup chain**

In `lib/ipc.sh`, locate the line:

```bash
  tmpl="$(cw_state_root)/identity-template.md"
  [[ -f "$tmpl" ]] || tmpl="$PLUGIN_ROOT/config/identity-template.md"
```

Replace the second line so the new canonical path is preferred and the old path is kept as a one-release fallback:

```bash
  tmpl="$(cw_state_root)/identity-template.md"
  [[ -f "$tmpl" ]] || tmpl="$PLUGIN_ROOT/config/prompt-templates/identity.md"
  [[ -f "$tmpl" ]] || tmpl="$PLUGIN_ROOT/config/identity-template.md"
```

- [ ] **Step 4: Run the full suite**

Run: `bash tests/run.sh`
Expected: every existing test passes; the symlink + dual-path lookup keeps `cw_identity_write` working both ways.

- [ ] **Step 5: Commit**

```bash
git add lib/ipc.sh config/prompt-templates/identity.md config/identity-template.md
git commit -m "refactor(config): move identity-template.md to prompt-templates/ + back-compat symlink (v0.5.0 #2)"
```

---

## Task 3: Migrate research prompt to template (A)

**Files:**
- Create: `config/prompt-templates/consult/research.md`.
- Modify: `lib/consult.sh::cw_consult_build_research_prompt` (lines 227-275 of v0.4.2).
- Test: `tests/test_consult_load_prompt_migration.sh` (new file; covers research + the next two tasks' migrations).
- Reference: `lib/consult.sh:227-275` (current heredoc to extract).

- [ ] **Step 1: Capture the v0.4.2 baseline output for byte-equality**

Run:

```bash
PLUGIN_ROOT=$(pwd) bash -c 'source lib/log.sh; source lib/state.sh; source lib/consult.sh; cw_consult_build_research_prompt "decide between LRU and LFU" "/tmp/findings.md"' > /tmp/baseline-research.txt
wc -c /tmp/baseline-research.txt
```

Save the byte count for Step 6's assertion. Expected: somewhere in 1500-2000 bytes given the prompt body.

- [ ] **Step 2: Extract the heredoc into a template**

Create `config/prompt-templates/consult/research.md` with the exact body of the heredoc in `cw_consult_build_research_prompt` (lib/consult.sh:229-273), replacing `$topic` with `{{TOPIC}}` and `$write_to` with `{{WRITE_TO}}`. The closing `END_OF_INSTRUCTION` line is part of the template:

```
Investigate the following topic and produce structured findings.

Topic: {{TOPIC}}

Output requirements — write to {{WRITE_TO}} with this EXACT structure:

  # Findings: {{TOPIC}}

  ## Summary
  <2-3 sentence overview, free-form prose>

  ## Claims
  1. [<source citation>] <one-sentence claim>
  2. [<source citation>] <one-sentence claim>
  ...

  ## Notes
  <any free-form additions; not parsed by Master Yoda>

Citation format options:
  - <file path>:<line>          e.g. src/auth/store.py:42
  - <file path>:<line-range>    e.g. src/auth/refresh.py:15-30
  - <URL>                       e.g. https://datatracker.ietf.org/doc/html/rfc6749
  - runtime: <command>          e.g. runtime: pytest tests/test_auth.py

Each claim must have a citation in [brackets]. Claims without citations
will be silently dropped by Master Yoda — and if NO claim has a
citation, your findings will be flagged as malformed in the report.

Research methods (v0.3.2):
You may use any tool available in your environment to investigate this
topic. When local repository evidence is insufficient or the topic
references external knowledge (RFCs, standards, library docs, vendor
APIs, recent CVEs, design patterns), you SHOULD use WebSearch / WebFetch
(or the equivalent in your TUI) to find authoritative sources and cite
them as URL citations. The citation parser already handles `https://...`
strings — see the URL row in the citation-format list above. Prefer
primary sources (specifications, official docs, source repos) over blog
posts. If a tool is not available in your environment, fall back to
local-only investigation and note the gap as an [unverified] claim.

Then emit {"event":"done", "summary":"researched {{TOPIC}}", "ts":"<iso>"} to your outbox.

END_OF_INSTRUCTION
```

- [ ] **Step 3: Refactor `cw_consult_build_research_prompt` to use the loader**

In `lib/consult.sh`, replace the existing function body (currently lines 227-275 of v0.4.2):

```bash
cw_consult_build_research_prompt() {
  local topic="$1" write_to="$2"
  cw_consult_load_prompt consult/research.md "TOPIC=$topic" "WRITE_TO=$write_to"
}
```

- [ ] **Step 4: Write the failing migration test**

Create `tests/test_consult_load_prompt_migration.sh`:

```bash
#!/usr/bin/env bash
# tests/test_consult_load_prompt_migration.sh — v0.5.0 byte-equality regression
# guard: each refactored helper must produce identical output to the v0.4.2
# inline heredoc. Baseline files are captured from main HEAD before this PR
# and committed alongside the test as fixtures.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/log.sh
source ../lib/state.sh
export CLAUDE_PLUGIN_ROOT="$(cd .. && pwd)"
PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT"
source ../lib/consult.sh

# Case 1: research prompt regression.
expected="$(cat fixtures/v0.4.2-research-prompt.txt)"
actual=$(cw_consult_build_research_prompt "decide between LRU and LFU" "/tmp/findings.md")
[[ "$actual" == "$expected" ]] || {
  diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") | head -20
  echo "FAIL c1: research prompt diverged from v0.4.2 baseline"
  exit 1
}
pass "research prompt byte-equal to v0.4.2 baseline"

echo "ALL PASS"
```

- [ ] **Step 5: Capture the fixture**

Move the baseline captured in Step 1 into the test fixtures directory:

```bash
mkdir -p tests/fixtures
mv /tmp/baseline-research.txt tests/fixtures/v0.4.2-research-prompt.txt
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `bash tests/test_consult_load_prompt_migration.sh`
Expected: `pass: research prompt byte-equal to v0.4.2 baseline`, then `ALL PASS`.

If the diff prints, the template body diverged from the heredoc — fix the template (most likely cause: a missing trailing newline or a `$topic` that should have been `{{TOPIC}}`).

- [ ] **Step 7: Run the full suite**

Run: `bash tests/run.sh`
Expected: all green.

- [ ] **Step 8: Commit**

```bash
git add config/prompt-templates/consult/research.md \
        lib/consult.sh \
        tests/test_consult_load_prompt_migration.sh \
        tests/fixtures/v0.4.2-research-prompt.txt
git commit -m "refactor(consult): migrate research prompt to template (v0.5.0 #3)"
```

---

## Task 4: Migrate verify prompt to template (A)

**Files:**
- Create: `config/prompt-templates/consult/verify.md`.
- Modify: `lib/consult.sh::cw_consult_build_verify_prompt` (lines 144-181 of v0.4.2).
- Modify: `tests/test_consult_load_prompt_migration.sh` (add Case 2).
- Create: `tests/fixtures/v0.4.2-verify-prompt.txt`.

- [ ] **Step 1: Capture the v0.4.2 baseline**

Build a fixture items file and capture the heredoc output:

```bash
cat > /tmp/items.txt <<'EOF'
[src/auth/store.py:42] sessions are stored as plaintext
[https://example.com/rfc] RFC says X
EOF
git stash  # so we render against pre-refactor cw_consult_build_verify_prompt
PLUGIN_ROOT=$(pwd) bash -c 'source lib/log.sh; source lib/state.sh; source lib/consult.sh; cw_consult_build_verify_prompt "/tmp/items.txt" "/tmp/verify.md"' > /tmp/baseline-verify.txt
git stash pop
mkdir -p tests/fixtures
mv /tmp/baseline-verify.txt tests/fixtures/v0.4.2-verify-prompt.txt
```

If `git stash`/`git stash pop` is awkward (uncommitted Task 3 changes), instead capture the baseline from the v0.4.2 git tag:

```bash
git show v0.4.2:lib/consult.sh > /tmp/v0.4.2-consult.sh
PLUGIN_ROOT=$(pwd) bash -c '
  source lib/log.sh; source lib/state.sh
  source /tmp/v0.4.2-consult.sh
  cw_consult_build_verify_prompt "/tmp/items.txt" "/tmp/verify.md"
' > tests/fixtures/v0.4.2-verify-prompt.txt
```

- [ ] **Step 2: Extract the heredoc into a template**

Create `config/prompt-templates/consult/verify.md` from the body at lib/consult.sh:146-180 of v0.4.2. The items file content is interpolated by the caller (not the template), so the template uses a `{{ITEMS}}` placeholder for the rendered list and `{{WRITE_TO}}` for the output path:

```
You researched a topic in your previous turn. Below are claims the OTHER researcher raised that you did not. For EACH item, do ONE of:

  AGREE     — confirm with your own evidence (cite a file/line/source)
  DISPUTE   — explain why it's wrong, with counter-evidence
  UNCERTAIN — you cannot tell from available evidence; say so

Items to verify:
{{ITEMS}}

Write your verdicts to {{WRITE_TO}} in this exact format:

  # Verify
  ## Verdicts
  1. <TAG> <original [citation] and text>
     <one-line evidence>
  2. ...

Where <TAG> is one of: AGREE / DISPUTE / UNCERTAIN.

Verification methods (v0.3.2):
You may use any tool in your environment to verify these claims —
WebSearch / WebFetch are explicitly authorized when an item cites a
URL, references external standards/docs, or makes a claim that local
repo evidence cannot resolve. For URL-cited items, fetching the source
is the default verification step. For file-cited items, prefer reading
the local file but reach for web tools when the file references an
external behavior (e.g., HTTP semantics, library APIs). If a tool is
unavailable in your environment, mark the item UNCERTAIN and note the
gap rather than fabricating evidence.

Then emit {"event":"done", "summary":"verified N items", "ts":"<iso>"} to your outbox.

END_OF_INSTRUCTION
```

- [ ] **Step 3: Refactor `cw_consult_build_verify_prompt` to use the loader**

In `lib/consult.sh`, replace the existing function body:

```bash
cw_consult_build_verify_prompt() {
  local items_file="$1" write_to="$2"
  local items
  items=$(nl -ba -w1 -s'. ' "$items_file")
  cw_consult_load_prompt consult/verify.md "ITEMS=$items" "WRITE_TO=$write_to"
}
```

- [ ] **Step 4: Add Case 2 to the migration test**

Append to `tests/test_consult_load_prompt_migration.sh` before the `echo "ALL PASS"` line:

```bash
# Case 2: verify prompt regression.
cat > /tmp/items.txt <<'EOF'
[src/auth/store.py:42] sessions are stored as plaintext
[https://example.com/rfc] RFC says X
EOF
expected="$(cat fixtures/v0.4.2-verify-prompt.txt)"
actual=$(cw_consult_build_verify_prompt /tmp/items.txt /tmp/verify.md)
[[ "$actual" == "$expected" ]] || {
  diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") | head -20
  echo "FAIL c2: verify prompt diverged from v0.4.2 baseline"
  exit 1
}
pass "verify prompt byte-equal to v0.4.2 baseline"
```

- [ ] **Step 5: Run the test**

Run: `bash tests/test_consult_load_prompt_migration.sh`
Expected: 2x `pass` lines, then `ALL PASS`.

- [ ] **Step 6: Run the full suite**

Run: `bash tests/run.sh`
Expected: all green.

- [ ] **Step 7: Commit**

```bash
git add config/prompt-templates/consult/verify.md \
        lib/consult.sh \
        tests/test_consult_load_prompt_migration.sh \
        tests/fixtures/v0.4.2-verify-prompt.txt
git commit -m "refactor(consult): migrate verify prompt to template (v0.5.0 #4)"
```

---

## Task 5: Migrate drilldown prompt to template (A)

**Files:**
- Create: `config/prompt-templates/consult/drilldown.md`.
- Modify: `lib/consult.sh::cw_consult_design_doc_drilldown_prompt` (lines 686-707 of v0.4.2).
- Modify: `tests/test_consult_load_prompt_migration.sh` (add Case 3).
- Create: `tests/fixtures/v0.4.2-drilldown-prompt.txt`.

- [ ] **Step 1: Capture the v0.4.2 baseline**

```bash
git show v0.4.2:lib/consult.sh > /tmp/v0.4.2-consult.sh
PLUGIN_ROOT=$(pwd) bash -c '
  source lib/log.sh; source lib/state.sh
  source /tmp/v0.4.2-consult.sh
  cw_consult_design_doc_drilldown_prompt \
    "Architecture" \
    "/path/to/synthesis.md" \
    "rex" \
    "/path/to/dd-dir" \
    "Add more depth on the IPC contract."
' > tests/fixtures/v0.4.2-drilldown-prompt.txt
```

- [ ] **Step 2: Extract the heredoc into a template**

Create `config/prompt-templates/consult/drilldown.md` (from lib/consult.sh:692-705 of v0.4.2; placeholders `{{SECTION}}`, `{{SYN}}`, `{{FOCUS}}`, `{{OUT_PATH}}`):

```
You are drilling deeper into the **{{SECTION}}** section of a design doc derived
from the consultation you just completed.

Read the synthesis you produced: {{SYN}}

Focus: {{FOCUS}}

Write your expanded notes (with [citation] anchors) to:
  {{OUT_PATH}}

When done, append a {"event":"done"} line to your outbox as usual.

END_OF_INSTRUCTION
```

- [ ] **Step 3: Refactor `cw_consult_design_doc_drilldown_prompt` to use the loader**

In `lib/consult.sh`, replace the existing function body (lines 686-707):

```bash
cw_consult_design_doc_drilldown_prompt() {
  local section="$1" syn="$2" commander="$3" dd_dir="$4" focus="${5:-}"
  local section_slug
  section_slug=$(printf '%s' "$section" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
  local out_path="$dd_dir/drilldown-${section_slug}-${commander}.md"
  local resolved_focus="${focus:-Provide more depth, citations, and concrete trade-offs for the $section section.}"
  cw_consult_load_prompt consult/drilldown.md \
    "SECTION=$section" \
    "SYN=$syn" \
    "FOCUS=$resolved_focus" \
    "OUT_PATH=$out_path"
}
```

- [ ] **Step 4: Add Case 3 to the migration test**

Append to `tests/test_consult_load_prompt_migration.sh` before `echo "ALL PASS"`:

```bash
# Case 3: drilldown prompt regression.
expected="$(cat fixtures/v0.4.2-drilldown-prompt.txt)"
actual=$(cw_consult_design_doc_drilldown_prompt \
  "Architecture" \
  "/path/to/synthesis.md" \
  "rex" \
  "/path/to/dd-dir" \
  "Add more depth on the IPC contract.")
[[ "$actual" == "$expected" ]] || {
  diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") | head -20
  echo "FAIL c3: drilldown prompt diverged from v0.4.2 baseline"
  exit 1
}
pass "drilldown prompt byte-equal to v0.4.2 baseline"
```

- [ ] **Step 5: Run the test**

Run: `bash tests/test_consult_load_prompt_migration.sh`
Expected: 3x `pass` lines, then `ALL PASS`.

- [ ] **Step 6: Run the full suite**

Run: `bash tests/run.sh`
Expected: all green. Pay special attention to `test_consult_design_doc_drilldown_prompt.sh` — its existing assertions must keep passing.

- [ ] **Step 7: Commit**

```bash
git add config/prompt-templates/consult/drilldown.md \
        lib/consult.sh \
        tests/test_consult_load_prompt_migration.sh \
        tests/fixtures/v0.4.2-drilldown-prompt.txt
git commit -m "refactor(consult): migrate drilldown prompt to template (v0.5.0 #5)"
```

---

## Task 6: Stale state in `bin/list.sh` (B)

**Files:**
- Modify: `bin/list.sh` (existing case statement at lines 70-77 of v0.4.2).
- Test: `tests/test_list_stale.sh` (new).

- [ ] **Step 1: Write the failing test**

Create `tests/test_list_stale.sh`:

```bash
#!/usr/bin/env bash
# tests/test_list_stale.sh — v0.5.0 stale-state classifier in bin/list.sh.
#
# We test the threshold logic by invoking the helper directly. The full
# bin/list.sh CLI is exercised end-to-end in case 7 (env override).
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
export CLAUDE_PLUGIN_ROOT="$(cd .. && pwd)"
export CLONE_WARS_HOME="$SANDBOX"
PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT"
source ../lib/log.sh
source ../lib/state.sh
source ../lib/list_stale.sh   # new helper file extracted from list.sh

# Helper: build a fake outbox at <path> with mtime <age> seconds in the past.
fake_outbox() {
  local path="$1" age_seconds="$2"
  mkdir -p "$(dirname "$path")"
  : > "$path"
  if stat -c %Y "$path" >/dev/null 2>&1; then
    touch -d "@$(( $(date +%s) - age_seconds ))" "$path"
  else
    touch -t "$(date -r "$(( $(date +%s) - age_seconds ))" +%Y%m%d%H%M.%S 2>/dev/null || date -j -f %s $(( $(date +%s) - age_seconds )) +%Y%m%d%H%M.%S)" "$path"
  fi
}

OUTBOX="$SANDBOX/outbox.jsonl"

# Case 1: working + age < threshold → working.
fake_outbox "$OUTBOX" 30
[[ "$(cw_list_classify_stale working "$OUTBOX" 180)" == "working" ]] \
  || { echo "FAIL c1"; exit 1; }
pass "working + age 30s < 180s → working"

# Case 2: working + age > threshold → stale.
fake_outbox "$OUTBOX" 300
[[ "$(cw_list_classify_stale working "$OUTBOX" 180)" == "stale" ]] \
  || { echo "FAIL c2"; exit 1; }
pass "working + age 300s > 180s → stale"

# Case 3: idle (any age) → idle.
fake_outbox "$OUTBOX" 9999
[[ "$(cw_list_classify_stale 'idle (done)' "$OUTBOX" 180)" == "idle (done)" ]] \
  || { echo "FAIL c3"; exit 1; }
pass "idle (done) is never reclassified"

# Case 4: missing outbox → state unchanged.
[[ "$(cw_list_classify_stale working "$SANDBOX/missing.jsonl" 180)" == "working" ]] \
  || { echo "FAIL c4"; exit 1; }
pass "missing outbox → state unchanged"

# Case 5: negative age (clock skew) → not stale.
mkdir -p "$(dirname "$OUTBOX")"; : > "$OUTBOX"
touch -d "@$(( $(date +%s) + 10 ))" "$OUTBOX" 2>/dev/null \
  || touch -t "$(date -d "+10 seconds" +%Y%m%d%H%M.%S 2>/dev/null)" "$OUTBOX"
[[ "$(cw_list_classify_stale working "$OUTBOX" 180)" == "working" ]] \
  || { echo "FAIL c5"; exit 1; }
pass "future mtime (negative age) → not stale"

# Case 6: env threshold override accepted.
fake_outbox "$OUTBOX" 30
[[ "$(cw_list_classify_stale working "$OUTBOX" 10)" == "stale" ]] \
  || { echo "FAIL c6"; exit 1; }
pass "explicit threshold=10 with age=30 → stale"

# Case 7: non-numeric threshold falls back to 180 with warning to stderr.
fake_outbox "$OUTBOX" 30
warn=$(cw_list_classify_stale working "$OUTBOX" "abc" 2>&1 >/dev/null)
[[ "$warn" == *"invalid threshold"* ]] \
  || { echo "FAIL c7 stderr: $warn"; exit 1; }
out=$(cw_list_classify_stale working "$OUTBOX" "abc" 2>/dev/null)
[[ "$out" == "working" ]] || { echo "FAIL c7 out: $out"; exit 1; }
pass "non-numeric threshold → warn + fallback to 180 (working stays working)"

echo "ALL PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_list_stale.sh`
Expected: FAIL because `lib/list_stale.sh` doesn't exist yet.

- [ ] **Step 3: Implement the helper**

Create `lib/list_stale.sh`:

```bash
# lib/list_stale.sh — v0.5.0 stale-state classifier for bin/list.sh.
# Sourced. No external deps beyond `stat` (GNU + BSD fallback) and `date`.

# _outbox_mtime <path> — print mtime seconds-since-epoch on stdout.
# Tries GNU `stat -c %Y` first; falls back to BSD `stat -f %m`. rc=1 if both fail.
_outbox_mtime() {
  local path="$1"
  stat -c %Y "$path" 2>/dev/null && return 0
  stat -f %m "$path" 2>/dev/null && return 0
  return 1
}

# cw_list_classify_stale <state> <outbox-path> <threshold-secs>
# If <state> is `working` AND outbox mtime is more than <threshold-secs> in the
# past, prints `stale`; otherwise prints <state> unchanged. Missing outbox or
# clock-skew (negative age) → state unchanged. Non-numeric threshold → warn to
# stderr, fall back to 180.
cw_list_classify_stale() {
  local state="$1" outbox="$2" threshold="${3:-180}"
  if [[ ! "$threshold" =~ ^[0-9]+$ ]]; then
    echo "cw_list_classify_stale: invalid threshold '$threshold'; using 180" >&2
    threshold=180
  fi
  if [[ "$state" != "working" ]]; then
    printf '%s\n' "$state"
    return 0
  fi
  if [[ ! -f "$outbox" ]]; then
    printf '%s\n' "$state"
    return 0
  fi
  local mtime now age
  mtime=$(_outbox_mtime "$outbox") || { printf '%s\n' "$state"; return 0; }
  now=$(date +%s)
  age=$(( now - mtime ))
  if (( age > 0 && age > threshold )); then
    printf '%s\n'  "stale"
  else
    printf '%s\n' "$state"
  fi
}
```

- [ ] **Step 4: Wire the helper into `bin/list.sh`**

In `bin/list.sh`, near the top (after the existing `source` block at lines 15-20), add:

```bash
source "$PLUGIN_ROOT/lib/list_stale.sh"
```

Then in the case statement (currently lines 70-77 of v0.4.2):

```bash
      case "$last_event" in
        done)  state='idle (done)'   ;;
        error) state='idle (error)'  ;;
        ack)   state='working'       ;;
        ready) state='ready'         ;;
        '')    state='spawning'      ;;
        *)     state="$last_event"   ;;
      esac
      state=$(cw_list_classify_stale "$state" "$outbox" "${CW_STALE_THRESHOLD_S:-180}")
```

The added line at the bottom of the block reclassifies `working` to `stale` if the outbox is older than the threshold.

- [ ] **Step 5: Run the unit test**

Run: `bash tests/test_list_stale.sh`
Expected: 7x `pass`, then `ALL PASS`.

- [ ] **Step 6: Run the full suite**

Run: `bash tests/run.sh`
Expected: all green. The `bin/list.sh` change is additive and shouldn't break any existing list tests.

- [ ] **Step 7: Commit**

```bash
git add lib/list_stale.sh bin/list.sh tests/test_list_stale.sh
git commit -m "feat(list): add 'stale' classification (outbox mtime > 180s) (v0.5.0 #6)"
```

---

## Task 7: `cw_send --from` flag + identity-template note (C)

**Files:**
- Modify: `lib/ipc.sh::cw_inbox_write` (existing function at lines 107-134 of v0.4.2).
- Modify: `bin/send.sh` (CLI flag parse at the front matter; pass through to lib).
- Modify: `config/prompt-templates/identity.md` (add the metadata note).
- Test: `tests/test_send_from_flag.sh` (new).

- [ ] **Step 1: Write the failing test**

Create `tests/test_send_from_flag.sh`:

```bash
#!/usr/bin/env bash
# tests/test_send_from_flag.sh — v0.5.0 cw_send --from sender attribution.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
export CLAUDE_PLUGIN_ROOT="$(cd .. && pwd)"
export CLONE_WARS_HOME="$SANDBOX"
PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT"
source ../lib/log.sh
source ../lib/state.sh
source ../lib/ipc.sh

mkdir -p "$SANDBOX/state/$(cw_repo_hash)/topic-x/rex-codex"
INBOX="$SANDBOX/state/$(cw_repo_hash)/topic-x/rex-codex/inbox.md"

# Case 1: default sender → "From: master-yoda".
cw_inbox_write rex codex topic-x "hello rex"
head -1 "$INBOX" | grep -q '^From: master-yoda$' \
  || { echo "FAIL c1"; cat "$INBOX"; exit 1; }
pass "default sender → From: master-yoda"

# Case 2: explicit --from cody → "From: cody".
cw_inbox_write --from cody rex codex topic-x "hi from cody"
head -1 "$INBOX" | grep -q '^From: cody$' \
  || { echo "FAIL c2"; cat "$INBOX"; exit 1; }
pass "explicit --from cody → From: cody"

# Case 3: --from with no value → rc=2.
if cw_inbox_write --from 2>/dev/null; then
  echo "FAIL c3: expected rc=2"; exit 1
fi
pass "--from with no value → rc=2"

# Case 4: invalid sender chars → rc=2.
if cw_inbox_write --from "evil$(date)" rex codex topic-x "x" 2>/dev/null; then
  echo "FAIL c4: expected rc=2"; exit 1
fi
pass "invalid sender chars → rc=2"

# Case 5: body unchanged after header (smoke check on END_OF_INSTRUCTION).
cw_inbox_write --from rex rex codex topic-x "task body content"
grep -q '^task body content$' "$INBOX" \
  || { echo "FAIL c5: body missing"; cat "$INBOX"; exit 1; }
grep -q '^END_OF_INSTRUCTION$' "$INBOX" \
  || { echo "FAIL c5: sentinel missing"; cat "$INBOX"; exit 1; }
pass "body and END_OF_INSTRUCTION sentinel preserved"

echo "ALL PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_send_from_flag.sh`
Expected: FAIL — `cw_inbox_write` doesn't accept `--from`.

- [ ] **Step 3: Modify `cw_inbox_write` to accept `--from`**

In `lib/ipc.sh`, replace the existing `cw_inbox_write` (lines 107-134 of v0.4.2) with:

```bash
cw_inbox_write() {
  local sender="master-yoda"
  if [[ "${1:-}" == "--from" ]]; then
    [[ -n "${2:-}" ]] || { echo "cw_inbox_write: --from requires a sender name" >&2; return 2; }
    sender="$2"
    shift 2
    [[ "$sender" =~ ^[a-zA-Z0-9_-]+$ ]] \
      || { echo "cw_inbox_write: invalid sender name '$sender' (allowed: [a-zA-Z0-9_-])" >&2; return 2; }
  fi
  local commander="$1" model="$2" topic="$3" task="$4"
  local inbox outbox tmp
  inbox=$(cw_inbox_path "$commander" "$model" "$topic")
  outbox=$(cw_outbox_path "$commander" "$model" "$topic")
  tmp=$(mktemp "${inbox}.tmp.XXXXXX")
  trap 'rm -f "$tmp"' EXIT
  cat > "$tmp" <<EOF
From: $sender

$task

When done, append a single JSONL line to $outbox:

\`{"event":"done","summary":"<one-line summary>","ts":"<iso-timestamp>"}\`

END_OF_INSTRUCTION
EOF
  if ! mv -f "$tmp" "$inbox"; then
    log_error "cw_inbox_write: mv tmp -> inbox failed (tmp=$tmp inbox=$inbox)"
    rm -f "$tmp"
    trap - EXIT
    return 1
  fi
  trap - EXIT
}
```

- [ ] **Step 4: Add `--from` pass-through to `bin/send.sh`**

In `bin/send.sh`, between the `--args-file` block and the `usage()` definition (after line 30 of v0.4.2), add:

```bash
SENDER_ARGS=()
if [[ "${1:-}" == "--from" ]]; then
  [[ -n "${2:-}" ]] || { echo "--from requires a sender name" >&2; exit 2; }
  SENDER_ARGS=(--from "$2")
  shift 2
fi
```

Then change the `cw_inbox_write` invocation at the bottom (line 85 of v0.4.2):

```bash
cw_inbox_write "${SENDER_ARGS[@]}" "$COMMANDER" "$MODEL" "$TOPIC" "$TASK"
```

Note: with bash 4.2+, `"${SENDER_ARGS[@]}"` expands to nothing when the array is empty, so default callers stay unchanged.

- [ ] **Step 5: Add the metadata note to identity.md**

In `config/prompt-templates/identity.md`, append a new line after the existing first-action block (or wherever the inbox-format section sits):

```
**Inbox header:** Inbox messages may begin with `From: <sender>` followed by a blank line — treat that line as metadata, not part of the task.
```

- [ ] **Step 6: Run the test**

Run: `bash tests/test_send_from_flag.sh`
Expected: 5x `pass`, then `ALL PASS`.

- [ ] **Step 7: Run the full suite**

Run: `bash tests/run.sh`
Expected: all green. Existing tests for inbox-write must still pass — the `From: ...` header is additive, and any test that asserts on `inbox.md` content should be reviewed for whether it expects exact-byte content; if so, update those tests to tolerate the new header (most assert on `END_OF_INSTRUCTION` or task body, not on the first line).

If `tests/test_consult_research_send.sh` or any send-script test breaks, the most likely cause is a body-position assertion that needs to skip the new 2-line header. Fix locally and continue.

- [ ] **Step 8: Commit**

```bash
git add lib/ipc.sh bin/send.sh config/prompt-templates/identity.md \
        tests/test_send_from_flag.sh
git commit -m "feat(send): add --from sender attribution (default master-yoda) (v0.5.0 #7)"
```

---

## Task 8: `.done` sentinel in wait-scripts (D)

**Files:**
- Modify: `bin/consult-research-wait.sh` (existing exit at lines 88-89 of v0.4.2).
- Modify: `bin/consult-verify-wait.sh` (analogous structure).
- Test: `tests/test_consult_wait_state_file.sh` (new).

- [ ] **Step 1: Write the failing test**

Create `tests/test_consult_wait_state_file.sh`:

```bash
#!/usr/bin/env bash
# tests/test_consult_wait_state_file.sh — v0.5.0 wait-script .done sentinel.
#
# Each terminal exit must:
#   1. Append `FS=<state>` as the last line of $STATE_FILE.
#   2. Touch ${STATE_FILE%.txt}.done immediately after, before exit.
#
# We mock the outbox by feeding pre-canned JSONL into a fixture trooper dir
# and run the actual wait-script with a tiny timeout.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
export CLAUDE_PLUGIN_ROOT="$(cd .. && pwd)"
export CLONE_WARS_HOME="$SANDBOX"
export CW_CONSULT_RESEARCH_TIMEOUT_OVERRIDE=2  # short for tests
PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT"

# Helper: set up a trooper state dir + offset state file.
setup() {
  local commander="$1" topic="$2" outbox_lines="$3"
  source ../lib/log.sh; source ../lib/state.sh
  local repo_dir="$SANDBOX/state/$(cw_repo_hash)/$topic"
  mkdir -p "$repo_dir/_consult" "$repo_dir/${commander}-codex"
  local outbox="$repo_dir/${commander}-codex/outbox.jsonl"
  printf '%s' "$outbox_lines" > "$outbox"
  local state_file="$repo_dir/_consult/research-${commander}.txt"
  printf 'OFFSET=0\n' > "$state_file"
  printf '%s\n%s\n' "$state_file" "$outbox"
}

assert_done_sentinel() {
  local state_file="$1"
  local sentinel="${state_file%.txt}.done"
  [[ -f "$sentinel" ]] || { echo "FAIL: missing .done sentinel at $sentinel"; exit 1; }
  [[ "$(tail -1 "$state_file")" =~ ^FS= ]] \
    || { echo "FAIL: state file last line is not FS=*: $(tail -1 "$state_file")"; exit 1; }
}

# Case 1: done event → FS=ok (or empty, depending on findings.md), .done touched.
mapfile -t S < <(setup rex topic-1 \
  '{"event":"ready","ts":"2026-04-30T00:00:00Z"}
{"event":"done","summary":"researched","ts":"2026-04-30T00:00:01Z"}
')
state_file="${S[0]}"
"$PLUGIN_ROOT/bin/consult-research-wait.sh" topic-1 rex codex
assert_done_sentinel "$state_file"
grep -q '^FS=' "$state_file"
pass "done event → FS= written + .done sentinel touched"

# Case 2: error event → FS=failed, .done touched.
mapfile -t S < <(setup rex topic-2 \
  '{"event":"ready","ts":"2026-04-30T00:00:00Z"}
{"event":"error","note":"boom","ts":"2026-04-30T00:00:01Z"}
')
state_file="${S[0]}"
"$PLUGIN_ROOT/bin/consult-research-wait.sh" topic-2 rex codex
assert_done_sentinel "$state_file"
grep -q '^FS=failed$' "$state_file"
pass "error event → FS=failed + .done touched"

# Case 3: timeout (no terminal event) → FS=timeout, .done touched.
mapfile -t S < <(setup rex topic-3 \
  '{"event":"ready","ts":"2026-04-30T00:00:00Z"}
')
state_file="${S[0]}"
"$PLUGIN_ROOT/bin/consult-research-wait.sh" topic-3 rex codex
assert_done_sentinel "$state_file"
grep -q '^FS=timeout$' "$state_file"
pass "no terminal event → FS=timeout + .done touched"

# Case 4: question event → FS=question, .done touched, OFFSET advanced.
mapfile -t S < <(setup rex topic-4 \
  '{"event":"ready","ts":"2026-04-30T00:00:00Z"}
{"event":"question","text":"async or sync?","options":["async","sync"]}
')
state_file="${S[0]}"
"$PLUGIN_ROOT/bin/consult-research-wait.sh" topic-4 rex codex
assert_done_sentinel "$state_file"
grep -q '^FS=question$' "$state_file"
# Two OFFSET= lines: the original + the post-question advance.
[[ "$(grep -c '^OFFSET=' "$state_file")" -ge 2 ]] \
  || { echo "FAIL c4: expected ≥2 OFFSET= lines; got $(grep -c '^OFFSET=' "$state_file")"; exit 1; }
pass "question event → FS=question + .done + OFFSET advanced"

# Case 5: malformed question payload → FS=failed (validator rejects), .done touched.
mapfile -t S < <(setup rex topic-5 \
  '{"event":"ready","ts":"2026-04-30T00:00:00Z"}
{"event":"question","options":["a","b"]}
')
state_file="${S[0]}"
"$PLUGIN_ROOT/bin/consult-research-wait.sh" topic-5 rex codex
assert_done_sentinel "$state_file"
grep -q '^FS=failed$' "$state_file"
pass "malformed question → FS=failed + .done touched"

# Case 6: same flow with bin/consult-verify-wait.sh (sanity).
# Set up a verify state file and outbox.
TOPIC=topic-6 COMMANDER=rex MODEL=codex
mkdir -p "$SANDBOX/state/$(cw_repo_hash)/$TOPIC/_consult"
mkdir -p "$SANDBOX/state/$(cw_repo_hash)/$TOPIC/${COMMANDER}-${MODEL}"
OUTBOX="$SANDBOX/state/$(cw_repo_hash)/$TOPIC/${COMMANDER}-${MODEL}/outbox.jsonl"
printf '%s\n' \
  '{"event":"ready","ts":"2026-04-30T00:00:00Z"}' \
  '{"event":"done","summary":"verified","ts":"2026-04-30T00:00:01Z"}' \
  > "$OUTBOX"
VERIFY_STATE="$SANDBOX/state/$(cw_repo_hash)/$TOPIC/_consult/verify-${COMMANDER}.txt"
printf 'OFFSET=0\n' > "$VERIFY_STATE"
CW_CONSULT_VERIFY_TIMEOUT_OVERRIDE=2 \
  "$PLUGIN_ROOT/bin/consult-verify-wait.sh" "$TOPIC" "$COMMANDER" "$MODEL"
assert_done_sentinel "$VERIFY_STATE"
pass "verify-wait done → FS= written + .done touched"

echo "ALL PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_consult_wait_state_file.sh`
Expected: FAIL on every `assert_done_sentinel` because the wait-scripts don't yet touch the sentinel.

- [ ] **Step 3: Modify `bin/consult-research-wait.sh`**

After the closing `esac` (currently line 88 of v0.4.2, end of the case statement), append:

```bash

# v0.5.0 background-await pattern: signal terminal completion to the
# directive's notification handler. The .done sentinel lets the controller
# distinguish a clean exit from a notification-arrived-before-write race.
touch "${STATE_FILE%.txt}.done"
exit 0
```

- [ ] **Step 4: Modify `bin/consult-verify-wait.sh`**

Apply the analogous change at the equivalent end-of-case point. Locate the final `esac` in `bin/consult-verify-wait.sh` and append the same `touch ${STATE_FILE%.txt}.done` + `exit 0` block.

- [ ] **Step 5: Run the test**

Run: `bash tests/test_consult_wait_state_file.sh`
Expected: 6x `pass`, then `ALL PASS`.

- [ ] **Step 6: Run the full suite**

Run: `bash tests/run.sh`
Expected: all green. Existing wait-script tests should be unaffected — the sentinel touch is additive and the explicit `exit 0` matches the prior implicit zero exit (since the case statement doesn't fail).

- [ ] **Step 7: Commit**

```bash
git add bin/consult-research-wait.sh bin/consult-verify-wait.sh \
        tests/test_consult_wait_state_file.sh
git commit -m "feat(consult): touch .done sentinel after FS= for background-await (v0.5.0 #8)"
```

---

## Task 9: Question→re-arm regression test under background semantics (D)

**Files:**
- Test: `tests/test_consult_wait_question_rearm.sh` (new).

The wait-script behavior for re-arm doesn't change in this task — Task 8 already added the `.done` sentinel. This task adds an explicit regression test that exercises the **two-call sequence** (initial wait emits `FS=question`; second wait, after a simulated ANSWER and new outbox content, emits `FS=ok`) so we have a single test asserting the question→re-arm loop survives the foreground→background flip.

- [ ] **Step 1: Write the test**

Create `tests/test_consult_wait_question_rearm.sh`:

```bash
#!/usr/bin/env bash
# tests/test_consult_wait_question_rearm.sh — v0.5.0 question→re-arm loop.
#
# Asserts:
#   1. After call 1 (question): state file ends with FS=question, has ≥2
#      OFFSET= lines (original + post-question), .done sentinel exists.
#   2. Caller deletes .done sentinel (simulating background re-spawn).
#   3. New outbox content (ANSWER acknowledgement + done event) is appended.
#   4. Call 2 (re-arm): state file ends with FS=ok (or empty/missing depending
#      on findings.md), .done sentinel re-touched.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
export CLAUDE_PLUGIN_ROOT="$(cd .. && pwd)"
export CLONE_WARS_HOME="$SANDBOX"
export CW_CONSULT_RESEARCH_TIMEOUT_OVERRIDE=2
PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT"
source ../lib/log.sh; source ../lib/state.sh

TOPIC=topic-rearm
COMMANDER=rex
MODEL=codex
TROOPER_DIR="$SANDBOX/state/$(cw_repo_hash)/$TOPIC/${COMMANDER}-${MODEL}"
ART_DIR="$SANDBOX/state/$(cw_repo_hash)/$TOPIC/_consult"
mkdir -p "$TROOPER_DIR" "$ART_DIR"

OUTBOX="$TROOPER_DIR/outbox.jsonl"
STATE_FILE="$ART_DIR/research-$COMMANDER.txt"
DONE_SENTINEL="${STATE_FILE%.txt}.done"

# Phase 1: initial outbox with a question event after ready.
printf '%s\n' \
  '{"event":"ready","ts":"2026-04-30T00:00:00Z"}' \
  '{"event":"question","text":"async or sync?","options":["async","sync"]}' \
  > "$OUTBOX"
printf 'OFFSET=0\n' > "$STATE_FILE"

"$PLUGIN_ROOT/bin/consult-research-wait.sh" "$TOPIC" "$COMMANDER" "$MODEL"

# Case 1: post-call-1 invariants.
[[ "$(tail -1 "$STATE_FILE")" == "FS=question" ]] \
  || { echo "FAIL c1: tail=$(tail -1 "$STATE_FILE")"; exit 1; }
[[ "$(grep -c '^OFFSET=' "$STATE_FILE")" -eq 2 ]] \
  || { echo "FAIL c1: expected 2 OFFSET= lines; got $(grep -c '^OFFSET=' "$STATE_FILE")"; exit 1; }
[[ -f "$DONE_SENTINEL" ]] \
  || { echo "FAIL c1: missing .done"; exit 1; }
pass "call 1: FS=question, 2 OFFSET= lines, .done sentinel"

# Phase 2: simulate the directive's background re-spawn — remove .done and
# append a done event to the outbox (simulating the ANSWER nudge + trooper
# completion).
rm -f "$DONE_SENTINEL"
printf '%s\n' \
  '{"event":"progress","note":"got ANSWER","ts":"2026-04-30T00:00:02Z"}' \
  '{"event":"done","summary":"researched after answer","ts":"2026-04-30T00:00:03Z"}' \
  >> "$OUTBOX"

"$PLUGIN_ROOT/bin/consult-research-wait.sh" "$TOPIC" "$COMMANDER" "$MODEL"

# Case 2: post-call-2 invariants.
[[ "$(tail -1 "$STATE_FILE")" =~ ^FS=(ok|empty|missing)$ ]] \
  || { echo "FAIL c2: expected FS=ok|empty|missing; got $(tail -1 "$STATE_FILE")"; exit 1; }
[[ -f "$DONE_SENTINEL" ]] \
  || { echo "FAIL c2: missing .done after re-arm"; exit 1; }
pass "call 2: FS=ok-class terminal, .done re-touched"

# Case 3: state file is well-formed (no garbage, last line is FS=, all OFFSET=
# lines are numeric).
last=$(tail -1 "$STATE_FILE")
[[ "$last" =~ ^FS= ]] \
  || { echo "FAIL c3: last line not FS=: $last"; exit 1; }
while IFS= read -r line; do
  case "$line" in
    OFFSET=*[!0-9]*) echo "FAIL c3: bad OFFSET= line: $line"; exit 1 ;;
  esac
done < <(grep '^OFFSET=' "$STATE_FILE")
pass "state file well-formed after re-arm"

echo "ALL PASS"
```

- [ ] **Step 2: Run the test**

Run: `bash tests/test_consult_wait_question_rearm.sh`
Expected: 3x `pass`, then `ALL PASS`. The wait-script changes from Task 8 are sufficient — no implementation changes needed in this task.

- [ ] **Step 3: Run the full suite**

Run: `bash tests/run.sh`
Expected: all green.

- [ ] **Step 4: Commit**

```bash
git add tests/test_consult_wait_question_rearm.sh
git commit -m "test(consult): question→re-arm regression for background-await (v0.5.0 #9)"
```

---

## Task 10: `commands/consult.md` Step 3 (research) → background-await (D)

**Files:**
- Modify: `commands/consult.md` Step 3 block (research-wait dispatch + question loop).
- Reference: `commands/consult.md` (current `Step 3 — Parallel research wait` section).

This is a directive change, not a code change. The implementer is a Claude Code session reading the directive; the change is in the prose instructions the session follows.

- [ ] **Step 1: Locate the current Step 3 block**

Open `commands/consult.md` and find the `### Step 3 — Parallel research wait (with question loop)` heading. The body currently shows:

```
Both calls in PARALLEL:

\`\`\`
"$CLAUDE_PLUGIN_ROOT/bin/consult-research-wait.sh" "$CONSULT_TOPIC" rex  codex
"$CLAUDE_PLUGIN_ROOT/bin/consult-research-wait.sh" "$CONSULT_TOPIC" cody claude
\`\`\`
```

- [ ] **Step 2: Replace the Step 3 body with the background-await pattern**

Replace the existing Step 3 body (from "v0.3 protocol:..." through "Stop the loop when both are FS ∈ ...") with:

````markdown
v0.5 protocol: wait-scripts run as background tasks so Master Yoda's pane
stays interactive while troopers work. Each wait-script writes
`FS=<state>` to its per-commander state file before exit and touches a
`.done` sentinel; the controller reads both on the harness's completion
notification.

Dispatch BOTH waits as parallel background Bash calls:

```
Bash(
  command='"$CLAUDE_PLUGIN_ROOT/bin/consult-research-wait.sh" "$CONSULT_TOPIC" rex  codex',
  run_in_background: true,
  description='research-wait rex (background)'
) → task_id_rex

Bash(
  command='"$CLAUDE_PLUGIN_ROOT/bin/consult-research-wait.sh" "$CONSULT_TOPIC" cody claude',
  run_in_background: true,
  description='research-wait cody (background)'
) → task_id_cody
```

While the background tasks run, **Yoda's pane remains free** — the user can
chat, run `/clone-wars:list`, or interrupt with new instructions. You will
receive one harness completion notification per task.

On EACH notification, do:

1. Identify which commander finished (the bash task description names them).
2. Read the per-commander state file:
   ```
   STATE_FILE="$TOPIC_DIR/_consult/research-<commander>.txt"
   DONE_SENTINEL="${STATE_FILE%.txt}.done"
   ```
3. If `$DONE_SENTINEL` is missing, treat it as `FS=failed` (the wait-script
   crashed before writing terminal state). Surface the error to the user
   and consider Pattern 1 (re-prompt) before proceeding.
4. Otherwise, parse the last `FS=` line:
   ```
   FS=$(grep '^FS=' "$STATE_FILE" | tail -1 | cut -d= -f2)
   ```

For each commander whose `FS=question`:

a. Read the question payload — `_consult/question-<commander>.txt`. Use
   the Read tool, parse `TEXT=` and `OPTIONS=`. Decode any `%xx` you see.
b. Read `$TOPIC_DIR/<commander>-<model>/findings.md` (if it exists) for
   findings-so-far context.
c. Classify as critical / non-critical (same rules as v0.3).
d. Get an answer:
   - critical → `AskUserQuestion` with TEXT + OPTIONS.
   - non-critical → answer from topic + findings yourself.
e. Send the answer:
   ```
   /clone-wars:send --from master-yoda <commander> "$CONSULT_TOPIC" "ANSWER: <your answer>

   (end of question response — resume your skill loop)
   END_OF_INSTRUCTION"
   ```
f. **Re-arm by removing the `.done` sentinel and re-running the wait-script
   in BACKGROUND.** Do NOT call `consult-research-send.sh` and do NOT run
   the wait-script in foreground:
   ```
   rm -f "$DONE_SENTINEL"
   Bash(
     command='"$CLAUDE_PLUGIN_ROOT/bin/consult-research-wait.sh" "$CONSULT_TOPIC" <commander> <model>',
     run_in_background: true,
     description='research-wait <commander> re-arm (background)'
   ) → new task_id
   ```
   The new task will fire its own completion notification.

Continue handling notifications until both commanders' state files show
`FS ∈ {ok, empty, missing, failed, timeout, malformed}`. `FS=question` is a
transient state — only proceed to Step 4 when both have a terminal value.

- `ok` / `empty` / `missing` → set tasks `1.3` and `1.4` → `completed`.
- `failed` / `timeout` / `malformed` → consider Pattern 1 (re-prompt)
  before proceeding; set tasks → `completed` if accepting the degraded
  result.
````

- [ ] **Step 3: Verify the directive change is internally consistent**

Run a manual proofread:

```bash
grep -n 'consult-research-wait' commands/consult.md | head -10
```

Expected: every reference to `consult-research-wait.sh` is either inside a `Bash(..., run_in_background: true)` block (Step 3), inside Pattern 4 in the intervention section (which gets updated in Task 11's same-PR pass), or in the now-deprecated foreground form inside the spec — verify the latter doesn't exist by hunting for naked `bin/consult-research-wait.sh` invocations:

```bash
grep -B1 -A1 'consult-research-wait\.sh' commands/consult.md | grep -v 'run_in_background\|^--' | head -20
```

If the only naked references are in Pattern 4, leave them — Task 11 (verify) and the same-PR Pattern 4 update bring those into the new shape. If you see naked references in Step 3 itself, fix them now.

- [ ] **Step 4: Run the full suite**

Run: `bash tests/run.sh`
Expected: all green. The directive change doesn't touch any executable code paths under test, so this is a smoke check.

- [ ] **Step 5: Commit**

```bash
git add commands/consult.md
git commit -m "feat(consult): step 3 research-wait runs in background; Yoda stays interactive (v0.5.0 #10)"
```

---

## Task 11: `commands/consult.md` Step 5 (verify) + Pattern 4 → background-await (D)

**Files:**
- Modify: `commands/consult.md` Step 5 block + Intervention Pattern 4.

- [ ] **Step 1: Locate Step 5 in `commands/consult.md`**

Find the `### Step 5 — Parallel verify dispatch + wait` section. The body currently includes a foreground parallel pair:

```
"$CLAUDE_PLUGIN_ROOT/bin/consult-verify-wait.sh" "$CONSULT_TOPIC" rex  codex
"$CLAUDE_PLUGIN_ROOT/bin/consult-verify-wait.sh" "$CONSULT_TOPIC" cody claude
```

- [ ] **Step 2: Replace the wait portion with background dispatch**

Keep the parallel **send** as foreground (sends complete in <1s). Replace the **wait** portion with the same background pattern as Step 3:

````markdown
Wait phase — both wait-scripts run as background tasks (Yoda stays
interactive):

```
Bash(
  command='"$CLAUDE_PLUGIN_ROOT/bin/consult-verify-wait.sh" "$CONSULT_TOPIC" rex  codex',
  run_in_background: true,
  description='verify-wait rex (background)'
) → task_id_rex

Bash(
  command='"$CLAUDE_PLUGIN_ROOT/bin/consult-verify-wait.sh" "$CONSULT_TOPIC" cody claude',
  run_in_background: true,
  description='verify-wait cody (background)'
) → task_id_cody
```

On EACH completion notification, read the per-commander verify state file:

```
STATE_FILE="$TOPIC_DIR/_consult/verify-<commander>.txt"
DONE_SENTINEL="${STATE_FILE%.txt}.done"
```

Same 4-step parse as Step 3 (sentinel check + grep `^VS=`). The verify
phase's question-loop semantics match Step 3's exactly — see Pattern 4
(updated below) for the re-arm recipe.

If all-UNCERTAIN, consider Pattern 3 intervention. Else set `1.6` and
`1.7` → `completed`.
````

- [ ] **Step 3: Update Pattern 4 (Critical-question relay) for background-await**

Find the `### Pattern 4: Critical-question relay (v0.3)` heading. Replace its body with:

````markdown
When a wait-script reports `FS=question` (research) or `VS=question`
(verify):

1. Read `_consult/question-<commander>.txt` — note `TEXT` and `OPTIONS`.
2. Read `$TROOPER_DIR/findings.md` (or `verify.md`) for findings-so-far.
3. Classify:
   - critical → `AskUserQuestion(TEXT, OPTIONS)`.
   - non-critical → answer from topic + findings yourself.
4. Send the answer (the new `--from` flag carries Yoda's identity):
   ```
   /clone-wars:send --from master-yoda <commander> "$CONSULT_TOPIC" "ANSWER: <answer>

   (end of question response — resume your skill loop)
   END_OF_INSTRUCTION"
   ```
5. Re-arm by removing the `.done` sentinel and re-running the wait-script
   in BACKGROUND (no send-script, no offset-reset — the wait-script's
   prior pass already advanced OFFSET past the question):
   ```
   rm -f "$TOPIC_DIR/_consult/research-<commander>.done"   # research
   # or:
   rm -f "$TOPIC_DIR/_consult/verify-<commander>.done"     # verify

   Bash(
     command='"$CLAUDE_PLUGIN_ROOT/bin/consult-research-wait.sh" "$CONSULT_TOPIC" <commander> <model>',
     run_in_background: true,
     description='research-wait <commander> re-arm'
   )
   # or the verify-wait equivalent.
   ```
6. The new background task will fire a completion notification when the
   trooper either re-emits FS=question (loop), produces a terminal event,
   or times out.

Both troopers may emit questions independently. Notifications can arrive
in any order; process each as it lands.

**Kill switch:** if the question protocol misbehaves (storming,
mis-classification), set `CW_CONSULT_SKILL_OVERRIDE=none` in the
directive's environment. Send-scripts will append an empty hint
(no autonomy contract); troopers will use their default behavior.
````

- [ ] **Step 4: Stub the manual T7 dogfood test file**

Create `tests/test_consult_v050_dogfood.sh` (skipped by `tests/run.sh`'s existing skip list — add a clause there in Step 5):

```bash
#!/usr/bin/env bash
# tests/test_consult_v050_dogfood.sh — MANUAL v0.5.0 release-gate dogfood.
#
# Skipped by tests/run.sh (manual gate). Run by hand:
#   bash tests/test_consult_v050_dogfood.sh
#
# Required state: tmux session active; codex+claude on PATH.
#
# Procedure:
#   1. Run: /clone-wars:consult decide between mutex vs spin-lock for foo cache
#   2. During Step 3 (research wait), type a chat message to Yoda's pane.
#      Verify the pane responds (prompt is interactive — not "busy").
#   3. From a second terminal: bash bin/list.sh
#      Verify both troopers show `working`. Wait > $CW_STALE_THRESHOLD_S
#      seconds (default 180) and re-run; verify `stale` appears.
#   4. Answer any FS=question prompts.
#   5. Wait for synthesis; verify final shape.
#
# Pass criteria:
#   - Yoda's pane was demonstrably interactive during steps 2-3.
#   - /clone-wars:list showed `stale` after the wait elapsed.
#   - Synthesis shipped with no errors.
echo "This is a manual dogfood checklist. Read the script header and run the steps yourself."
exit 0
```

Make it executable: `chmod +x tests/test_consult_v050_dogfood.sh`.

- [ ] **Step 5: Add the skip clause to `tests/run.sh`**

In `tests/run.sh`, extend the `case "$t" in` block in lines 14-21:

```bash
    test_consult_v050_dogfood.sh)
      echo "=== $t === (SKIP — manual v0.5.0 dogfood, run explicitly)"
      continue ;;
```

Place it immediately after the existing `test_consult_design_doc_walkthrough.sh)` clause.

- [ ] **Step 6: Run the full suite**

Run: `bash tests/run.sh`
Expected: all green; the new manual dogfood test prints SKIP and continues.

- [ ] **Step 7: Commit**

```bash
git add commands/consult.md tests/test_consult_v050_dogfood.sh tests/run.sh
git commit -m "feat(consult): step 5 verify-wait + Pattern 4 → background-await (v0.5.0 #11)"
```

---

## Task 12: Release polish — version bump, docs, manual T7 (—)

**Files:**
- Modify: `.claude-plugin/plugin.json` (`0.4.2` → `0.5.0`).
- Modify: `.claude-plugin/marketplace.json` (`0.4.2` → `0.5.0`).
- Modify: `CLAUDE.md` (status checklist).
- Modify: `README.md` (release notes).

- [ ] **Step 1: Bump version in `.claude-plugin/plugin.json`**

Edit `.claude-plugin/plugin.json`: change `"version": "0.4.2"` to `"version": "0.5.0"`.

- [ ] **Step 2: Bump version in `.claude-plugin/marketplace.json`**

Edit `.claude-plugin/marketplace.json`: change both occurrences of `"version": "0.4.2"` to `"version": "0.5.0"` (the top-level marketplace version and the plugin entry's version).

- [ ] **Step 3: Update `CLAUDE.md` status checklist**

In `CLAUDE.md`'s "Status" section, locate the existing checklist and:

- Mark `[x] v0.4.2: design-doc mode — codex adversarial-review fixes` as already done.
- Add a new line below it:

```markdown
- [x] v0.5.0: octogent-steals — prompt-template registry, stale state, cw_send --from, background-await pattern
```

- [ ] **Step 4: Update `README.md` with release-notes preview**

In `README.md`, near the top below the project tagline, insert (or update if a "What's new" section exists):

```markdown
### What's new in v0.5.0 — "Octogent Steals"

- 🦑 **Yoda stays interactive during consult waits.** Background-await pattern means you can chat with Master Yoda or run `/clone-wars:list` while troopers are working.
- 👁 **`/clone-wars:list` flags stale troopers.** Working troopers whose outbox has been silent for >180s render as `stale`. Override via `CW_STALE_THRESHOLD_S`.
- ✉️ **`cw_send --from <sender>`** lets messages carry sender attribution (default `master-yoda`); paves the way for v0.6+ trooper-to-trooper messaging.
- 🧱 **Prompts are versioned templates.** Per-phase markdown under `config/prompt-templates/consult/` makes them grep-able, diff-able, and easier to evolve.

Inspired by [octogent](https://github.com/hesamsheikh/octogent)'s orchestration patterns, adapted for clone-wars' pure-shell + tmux + file-IPC model.
```

- [ ] **Step 5: Run the manual dogfood checklist (T7)**

Open a tmux session and execute the procedure documented in `tests/test_consult_v050_dogfood.sh`. Confirm:

- Yoda's pane accepts user input during research and verify waits.
- `/clone-wars:list` renders `stale` after waiting longer than `$CW_STALE_THRESHOLD_S`.
- Inbox messages received by troopers show a `From: master-yoda` header line.
- Synthesis ships without errors.

If any check fails, fix the underlying task (likely Task 10 or 11) before proceeding to Step 6.

- [ ] **Step 6: Run the full suite one last time**

Run: `bash tests/run.sh`
Expected: all green.

- [ ] **Step 7: Commit and tag**

```bash
git add .claude-plugin/plugin.json .claude-plugin/marketplace.json \
        CLAUDE.md README.md
git commit -m "chore(release): v0.5.0 — octogent-steals (A+B+C+D bundle)"
git tag v0.5.0
```

- [ ] **Step 8: Open the PR**

```bash
git push -u origin <branch-name>
gh pr create --title "v0.5.0 — Octogent Steals (A+B+C+D)" --body "$(cat <<'EOF'
## Summary

- **A.** Prompt-template registry (`config/prompt-templates/consult/{research,verify,drilldown}.md` + `cw_consult_load_prompt`).
- **B.** Lifecycle `stale` state in `/clone-wars:list` (outbox-mtime-only, 180s threshold, `CW_STALE_THRESHOLD_S` override).
- **C.** `cw_send --from <sender>` with default `master-yoda`; identity-template gains a metadata note.
- **D.** Background-await pattern in `commands/consult.md` Steps 3 + 5; wait-scripts touch `.done` sentinel after writing terminal `FS=`.

Inspired by [octogent](https://github.com/hesamsheikh/octogent). Spec: `docs/superpowers/specs/2026-04-30-clone-wars-v0.5.0-octogent-steals-design.md`.

## Test plan

- [x] `bash tests/run.sh` — all green
- [ ] Manual T7 dogfood (per `tests/test_consult_v050_dogfood.sh`) — Yoda interactive, stale detection visible, From header lands, synthesis ships
- [ ] Migration regression: `tests/test_consult_load_prompt_migration.sh` proves byte-equal output to v0.4.2 baseline for research / verify / drilldown prompts.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Self-Review

Performed against the spec sections.

**1. Spec coverage:**

- A. Prompt-template registry — covered by Tasks 1-5. Loader (T1), directory move (T2), three migrations (T3-T5). The five `design-doc/<section>.md` templates listed in the spec are deliberately deferred to v0.5.1+ as flagged in the plan header — there is no v0.4.2 inline-prompt code to byte-equality-test against.
- B. Stale state — covered by Task 6 (helper + wiring + 7 unit cases).
- C. `cw_send --from` — covered by Task 7 (flag parse + identity-template note + 5 unit cases).
- D. Background-await — covered by Tasks 8 (`.done` sentinel + 6 unit cases), 9 (re-arm regression), 10 (research directive), 11 (verify directive + Pattern 4).
- Release polish — Task 12.

No missing requirements.

**2. Placeholder scan:** 

No "TBD", "TODO", "implement later", "fill in details", or vague "add appropriate error handling" lines. Every code block contains the actual code. Every command has its expected output spelled out.

**3. Type consistency:**

- Helper named `cw_consult_load_prompt` consistently across Tasks 1, 3, 4, 5.
- `cw_list_classify_stale` consistently across Task 6.
- Sentinel filename pattern `${STATE_FILE%.txt}.done` consistent across Tasks 8, 9, 10, 11.
- `--from` flag and `From: <sender>` header consistent across Task 7 and Pattern 4 in Task 11.
- Variable names (`$STATE_FILE`, `$DONE_SENTINEL`, `$TOPIC_DIR`, `$ART_DIR`) consistent with existing scripts.

No drift detected.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-30-clone-wars-v0.5.0-octogent-steals-plan.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task with two-stage review (spec compliance, then code quality). 12 tasks, fast iteration, isolated context per task.

**2. Inline Execution** — Execute tasks in this session using `executing-plans`, batched with checkpoints for review.

Which approach?
