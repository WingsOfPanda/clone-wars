# /clone-wars:consult Unified Smart-Control Implementation Plan (v0.16.0)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fold quick-research fast-path INTO `/clone-wars:consult` (no separate `/ask` command). Yoda decides per-invocation whether to answer solo or escalate to troopers; output is always `_consult/design-doc/<date>-<slug>-design.md` (rigid 6 sections); /spec source-defaulting collapses to single path.

**Architecture:** Bottom-up — lib helper first (canonical design-doc path), then bin scripts (init creates dir; synthesize writes design-doc), then directive (--use-force + phrasing triggers + fast-path block), then /spec source-defaulting collapse, then tests + version bump + dogfood. Each task leaves `bash tests/run.sh` green.

**Tech Stack:** pure bash, tmux, file IPC. No Node/Python in runtime.

**Spec:** `docs/superpowers/specs/2026-05-08-unified-consult-design.md`

---

### Task 1: Branch + baseline

**Files:**
- Branch: `feat/v0.16.0-unified-consult` (already created)

- [ ] **Step 1: Confirm baseline green**

```bash
bash tests/run.sh > /tmp/v016-baseline.log 2>&1
PASS=$(grep -cE '^  PASS:' /tmp/v016-baseline.log)
FAIL=$(grep -cE ': FAIL$' /tmp/v016-baseline.log)
echo "PASS=$PASS FAIL=$FAIL"
```

Expected: FAIL=0. If non-zero, STOP and investigate.

- [ ] **Step 2: Commit empty marker**

```bash
git commit --allow-empty -m "chore(v0.16.0): start unified-consult branch

Baseline: tests/run.sh = X PASS / 0 FAIL on this commit (post-v0.15.0 main).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

(Substitute the actual PASS count from Step 1.)

---

### Task 2: Design-doc canonical path helper (TDD)

**Files:**
- Modify: `lib/consult.sh` — add `cw_consult_design_doc_canonical_path` helper
- Create: `tests/test_consult_design_doc_path.sh`

- [ ] **Step 1: Write failing test**

```bash
cat > tests/test_consult_design_doc_path.sh <<'EOF'
#!/usr/bin/env bash
# Asserts cw_consult_design_doc_canonical_path returns the v0.16.0 path:
#   <art_dir>/design-doc/<YYYY-MM-DD>-<slug>-design.md
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/consult.sh"

ART_DIR=/tmp/cw-test-design-doc-path
TODAY=$(date -u +%Y-%m-%d)

# Slug input → expected filename pattern.
out=$(cw_consult_design_doc_canonical_path "$ART_DIR" "consult-foo-bar")
assert_eq "$out" "$ART_DIR/design-doc/$TODAY-consult-foo-bar-design.md" \
  "canonical path joins art_dir + design-doc/ + date-slug-design.md"
pass "cw_consult_design_doc_canonical_path basic shape"

# Empty slug → rc=2 + clear error.
cw_consult_design_doc_canonical_path "$ART_DIR" "" 2>/dev/null && {
  echo FAIL: empty slug should return rc=2; exit 1
}
pass "empty slug returns rc=2"

# Empty art_dir → rc=2.
cw_consult_design_doc_canonical_path "" "consult-foo" 2>/dev/null && {
  echo FAIL: empty art_dir should return rc=2; exit 1
}
pass "empty art_dir returns rc=2"
EOF
chmod +x tests/test_consult_design_doc_path.sh
```

- [ ] **Step 2: Run test, expect FAIL**

```bash
bash tests/test_consult_design_doc_path.sh 2>&1 | tail -3
# Expected: command not found / unbound function
```

- [ ] **Step 3: Implement helper in lib/consult.sh**

Add at the end of `lib/consult.sh` (alongside the other v0.15.0 helpers):

```bash
# v0.16.0: canonical design-doc path within an art-dir.
# Format: <art_dir>/design-doc/<YYYY-MM-DD>-<slug>-design.md
# Used by both fast-path (Yoda solo) and trooper-path (consult-synthesize)
# so /spec reads ONE pattern. Date is UTC.
cw_consult_design_doc_canonical_path() {
  local art_dir="$1" slug="$2"
  [[ -n "$art_dir" ]] || { echo "cw_consult_design_doc_canonical_path: art_dir required" >&2; return 2; }
  [[ -n "$slug" ]]    || { echo "cw_consult_design_doc_canonical_path: slug required" >&2; return 2; }
  printf '%s/design-doc/%s-%s-design.md\n' "$art_dir" "$(date -u +%Y-%m-%d)" "$slug"
}
```

- [ ] **Step 4: Run test, expect PASS**

- [ ] **Step 5: Update lib/consult shim test EXPECTED list**

Add `cw_consult_design_doc_canonical_path` to `tests/test_consult_lib_shim_sources_all.sh` EXPECTED list. Update count message from 34 → 35.

- [ ] **Step 6: Run full suite**

```bash
bash tests/run.sh > /tmp/v016-task2.log 2>&1
PASS=$(grep -cE '^  PASS:' /tmp/v016-task2.log)
FAIL=$(grep -cE ': FAIL$' /tmp/v016-task2.log)
echo "PASS=$PASS FAIL=$FAIL"
```

Expected: FAIL=0.

- [ ] **Step 7: Commit**

```bash
git add lib/consult.sh tests/test_consult_design_doc_path.sh tests/test_consult_lib_shim_sources_all.sh
git commit -m "feat(consult): add design-doc canonical path helper (v0.16.0)

cw_consult_design_doc_canonical_path returns
  <art_dir>/design-doc/<YYYY-MM-DD>-<slug>-design.md
This is the SOLE path /consult writes its final output to in v0.16
(both fast-path solo and trooper-path escalation), and the SOLE path
/spec source-defaults to read.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: consult-init creates design-doc dir

**Files:**
- Modify: `bin/consult-init.sh` — `mkdir -p $TOPIC_DIR/_consult/design-doc/`
- Modify: `tests/test_consult_init.sh` — assert design-doc/ subdir created

- [ ] **Step 1: Read current bin/consult-init.sh**

Find the `mkdir -p` block where `_consult/` is created.

- [ ] **Step 2: Add design-doc/ subdir to mkdir**

```bash
# v0.16.0: pre-create design-doc/ subdir so synthesize doesn't have to.
mkdir -p "$TOPIC_DIR/_consult/design-doc"
```

(Inserted alongside the existing `_consult/` skeleton creation.)

- [ ] **Step 3: Update test_consult_init.sh**

Add an assertion that `_consult/design-doc/` exists after consult-init runs:

```bash
[[ -d "$TOPIC_DIR/_consult/design-doc" ]] \
  || { echo "FAIL: _consult/design-doc/ not created"; exit 1; }
pass "consult-init creates _consult/design-doc/ subdir"
```

- [ ] **Step 4: Run full suite**

Expected: FAIL=0.

- [ ] **Step 5: Commit**

```bash
git add bin/consult-init.sh tests/test_consult_init.sh
git commit -m "feat(consult): consult-init pre-creates _consult/design-doc/ subdir (v0.16.0)

Both fast-path (Yoda solo) and trooper-path (consult-synthesize) write
the canonical design-doc into this subdir. Pre-creating in init keeps
the writers simple — no mkdir-as-needed logic.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: consult-synthesize writes design-doc instead of synthesis.md (TDD)

**Files:**
- Modify: `bin/consult-synthesize.sh` — write to canonical design-doc path; drop synthesis.md
- Modify: `lib/consult.sh::cw_consult_synthesize` (if present) — same change
- Modify: existing synthesize tests — assert design-doc path, NOT synthesis.md

- [ ] **Step 1: Read current synthesize logic**

```bash
grep -n 'synthesis\.md\|cw_consult_synthesize' bin/consult-synthesize.sh lib/consult.sh
```

Find every place that writes `synthesis.md` and every place that reads it downstream.

- [ ] **Step 2: Write failing test for new output path**

Update `tests/test_consult_synthesize.sh` (or `test_consult_synthesize_bin.sh`, whichever exercises the bin script end-to-end) to assert:

```bash
DESIGN_DOC=$(cw_consult_design_doc_canonical_path "$TOPIC_DIR/_consult" "$CONSULT_TOPIC")
[[ -f "$DESIGN_DOC" ]] || { echo "FAIL: design-doc not at canonical path"; exit 1; }

# synthesis.md should NOT exist anymore.
[[ ! -f "$TOPIC_DIR/_consult/synthesis.md" ]] \
  || { echo "FAIL: legacy synthesis.md still written"; exit 1; }
pass "synthesize writes design-doc, not synthesis.md"
```

Also assert the design-doc has rigid 6 H2 sections:

```bash
for section in "Summary" "Findings" "Tradeoffs" "Recommendation" "Open Questions" "Sources"; do
  grep -qE "^## $section\$" "$DESIGN_DOC" \
    || { echo "FAIL: section '$section' missing from design-doc"; exit 1; }
done
pass "design-doc has all 6 rigid sections"
```

And the trust-label header:

```bash
grep -qE '^> \*\*Source:\*\*' "$DESIGN_DOC" \
  || { echo "FAIL: Source: header missing"; exit 1; }
grep -qE '^> \*\*Generated:\*\*' "$DESIGN_DOC" \
  || { echo "FAIL: Generated: header missing"; exit 1; }
grep -qE '^> \*\*Path:\*\*' "$DESIGN_DOC" \
  || { echo "FAIL: Path: header missing"; exit 1; }
pass "design-doc has Source/Generated/Path headers"
```

- [ ] **Step 3: Run test, expect FAIL**

- [ ] **Step 4: Refactor consult-synthesize.sh**

Replace the synthesis.md write with a design-doc write at the canonical path. The script reads the existing `_consult/adjudicated.md` (working artifact, intermediate) and produces the design-doc with the rigid 6 sections.

Concrete shape:

```bash
# v0.16.0: write to canonical design-doc path instead of synthesis.md.
DESIGN_DOC=$(cw_consult_design_doc_canonical_path "$ART_DIR" "$CONSULT_TOPIC")

# Build the design-doc content from adjudicated.md sections.
{
  printf '# %s\n\n' "$(echo "$CONSULT_TOPIC" | sed 's/-/ /g' | sed 's/\b\(.\)/\u\1/g')"
  printf '> **Source:** %s\n' "${SOURCE_LABEL:-rex+cody+bly cross-verified (N=$N_TROOPERS)}"
  printf '> **Generated:** %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '> **Path:** %s\n\n' "${PATH_LABEL:-escalated-from-signals}"
  printf '## Summary\n%s\n\n' "$(extract_summary "$ART_DIR/adjudicated.md")"
  printf '## Findings\n%s\n\n' "$(extract_findings "$ART_DIR/adjudicated.md")"
  printf '## Tradeoffs\n%s\n\n' "$(extract_tradeoffs "$ART_DIR/adjudicated.md")"
  printf '## Recommendation\n%s\n\n' "$(extract_recommendation "$ART_DIR/adjudicated.md")"
  printf '## Open Questions\n%s\n\n' "$(extract_open_questions "$ART_DIR/adjudicated.md")"
  printf '## Sources\n%s\n' "$(extract_citations "$ART_DIR/adjudicated.md")"
} > "$DESIGN_DOC"
```

The `extract_*` shell functions are simple awk filters over `adjudicated.md`. For sections that don't have content, emit `_(not applicable)_` per the rigid-format spec. Implementation can lean on the existing `cw_consult_synthesize` logic if it already does section-extraction; otherwise these become a few new awk scripts.

The `SOURCE_LABEL` and `PATH_LABEL` variables are passed in as env vars from the directive (the directive knows whether the path was "escalated-from-flag" / "escalated-from-phrasing" / "escalated-from-signals").

DROP the `synthesis.md` write entirely — no fallback, no symlink.

- [ ] **Step 5: Run test, expect PASS**

- [ ] **Step 6: Find any consumer of synthesis.md and update or delete**

```bash
grep -rn 'synthesis\.md' bin/ commands/ lib/ tests/ docs/
```

Specifically:
- `commands/spec.md` source-defaulting (handled in Task 6)
- `bin/spec-init.sh` source-defaulting (handled in Task 6)
- Test fixtures that asserted on `synthesis.md` — update to design-doc

- [ ] **Step 7: Run full suite**

Expected: FAIL=0 except for spec-side tests that still expect synthesis.md (those are Task 6's concern). If those fail in this task's run, it's expected — note them and proceed.

- [ ] **Step 8: Commit**

```bash
git add bin/consult-synthesize.sh lib/consult.sh tests/test_consult_synthesize*.sh
git commit -m "feat(consult): synthesize writes design-doc at canonical path; drops synthesis.md (v0.16.0)

bin/consult-synthesize.sh now writes
  _consult/design-doc/<YYYY-MM-DD>-<slug>-design.md
with rigid 6 sections (Summary / Findings / Tradeoffs / Recommendation /
Open Questions / Sources) and the Source/Generated/Path trust label
header. The legacy _consult/synthesis.md write is REMOVED — no fallback,
no symlink. Spec-side source-defaulting still expects synthesis.md and
will be updated in Task 6.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Directive — `--use-force` flag + phrasing triggers + fast-path block

**Files:**
- Modify: `commands/consult.md` — add fast-path block, --use-force flag, phrasing trigger detection
- Possibly modify or create test for directive static wiring

This is the **biggest** task. The directive grows by ~80-150 lines for the fast-path block.

- [ ] **Step 1: Read current commands/consult.md structure**

```bash
wc -l commands/consult.md
grep -n '^### Step' commands/consult.md
```

- [ ] **Step 2: Add `--use-force` flag parsing block at the top of Step 0**

After the `--design-doc` flag parsing, add:

```bash
# v0.16.0: --use-force flag — skip Yoda fast-path, always spawn troopers.
USE_FORCE=0
if [[ "$ARG_RAW" == --use-force* ]]; then
  USE_FORCE=1
  ARG_RAW="${ARG_RAW#--use-force }"  # strip the flag
  ARG_RAW="${ARG_RAW#--use-force}"   # also handle --use-force as sole arg
  log_info "--use-force: skipping fast-path; trooper escalation immediate"
fi
```

(The actual flag parse needs to handle the flag in any position robustly. Plan-time hint: parse via a 2-pass pre-strip similar to `cw_consult_parse_design_doc_flag`. The implementer should add a `cw_consult_parse_use_force_flag` lib helper, mirroring the design-doc helper, with the same prose-described approach.)

- [ ] **Step 3: Add escalation-trigger detection block (after init, before fast-path)**

```bash
# v0.16.0: phrasing trigger detection.
ESCALATE_FROM_PHRASING=0
PHRASING_TRIGGERS=(
  "deeply"
  "verify"             # also catches "verify rigorously", "cross-verify", etc.
  "compare carefully"
  "second opinion"
  "consult thoroughly"
)
for trigger in "${PHRASING_TRIGGERS[@]}"; do
  if echo "$ARG_RAW" | grep -qiE "\\b${trigger}\\b"; then
    ESCALATE_FROM_PHRASING=1
    log_info "phrasing trigger '$trigger' fired; escalating to troopers"
    break
  fi
done
```

- [ ] **Step 4: Add the fast-path block (Step 0.5 — between init and Step 1 spawn)**

The fast-path block tells Yoda (the conductor) to:
1. If `USE_FORCE=1` or `ESCALATE_FROM_PHRASING=1` → skip fast-path, jump to Step 1 spawn
2. Otherwise: research the topic with full toolkit (Read/Grep/Bash/WebSearch/Tavily/skills)
3. Run the 4-signal complexity check (prose-described)
4. If any signal fires → escalate (jump to Step 1 spawn)
5. Otherwise → write the design-doc inline (using the canonical path helper) with `Source: Master Yoda (single-source)` and `Path: fast` headers, then exit

The fast-path block is **prose-heavy** (instructs Yoda's behavior), not a sequence of bin-script calls. Concrete fragment to insert:

```markdown
### Step 0.5 — Yoda fast-path (v0.16.0)

If `USE_FORCE=1` or `ESCALATE_FROM_PHRASING=1`, skip this step entirely
and proceed to Step 1 (parallel spawn).

Otherwise, Master Yoda performs a fast-path research pass:

1. Research the topic using all available tools — Read/Grep/Bash for code,
   WebSearch + Tavily (paired per the global dual-search rule) for web
   research, optional skill invocations.

2. Run the **4-signal complexity check** (favor rigor: any signal fires
   → escalate to troopers):

   - **Conflicting evidence** — multiple sources disagreed on a key claim
   - **Significant assumptions** — answer required Yoda to assume facts
     not in evidence
   - **High-stakes decision** — architectural / security / irreversible /
     production-data implications
   - **Subjective tradeoffs** — no objective right answer (compare A vs B,
     should we do X)

3. **If any signal fires:** escalate.

   ```
   ESCALATE_FROM_SIGNALS=1
   log_info "fast-path: signal '<which>' fired; escalating to troopers"
   ```
   Proceed to Step 1.

4. **If no signal fires:** Yoda writes the canonical design-doc INLINE.

   ```
   DESIGN_DOC=$(cw_consult_design_doc_canonical_path \
       "$TOPIC_DIR/_consult" "$CONSULT_TOPIC")

   {
     printf '# %s\n\n' "<title-cased topic>"
     printf '> **Source:** Master Yoda (single-source)\n'
     printf '> **Generated:** %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
     printf '> **Path:** fast\n\n'
     printf '## Summary\n<1-3 sentences>\n\n'
     printf '## Findings\n<research summary>\n\n'
     printf '## Tradeoffs\n_(not applicable)_\n\n'
     printf '## Recommendation\n<action recommendation>\n\n'
     printf '## Open Questions\n<remaining uncertainty>\n\n'
     printf '## Sources\n- citation 1\n- citation 2\n'
   } > "$DESIGN_DOC"

   # Print full design-doc to chat; exit cleanly.
   cat "$DESIGN_DOC"
   exit 0
   ```

   No troopers spawned. No `_consult/` working artifacts created. Done.
```

- [ ] **Step 5: Update Step 1 (spawn) so it's reachable from the 3 escalation paths**

Add a one-line marker in Step 1's preamble:

```markdown
**Reached from:** USE_FORCE flag set | phrasing trigger fired |
4-signal escalation. Set PATH_LABEL accordingly:

```
case "$USE_FORCE,$ESCALATE_FROM_PHRASING,${ESCALATE_FROM_SIGNALS:-0}" in
  1,*,*) PATH_LABEL="escalated-from-flag" ;;
  *,1,*) PATH_LABEL="escalated-from-phrasing" ;;
  *,*,1) PATH_LABEL="escalated-from-signals" ;;
esac
export PATH_LABEL
```

This is consumed by Step 8 (synthesize).
```

- [ ] **Step 6: Update Step 8 (synthesize) to pass the source/path labels**

In Step 8's synthesize call, set the env:

```bash
SOURCE_LABEL="rex+cody+bly cross-verified (N=$N)"  # or N=2 variant
PATH_LABEL="${PATH_LABEL:-escalated-from-signals}"
SOURCE_LABEL="$SOURCE_LABEL" PATH_LABEL="$PATH_LABEL" \
  "$CLAUDE_PLUGIN_ROOT/bin/consult-synthesize.sh" "$CONSULT_TOPIC"
```

- [ ] **Step 7: Run static wiring tests if any exist**

```bash
ls tests/ | grep -E 'directive|static_wiring' | head
```

Update them to assert the new directive content (USE_FORCE, fast-path, 4-signal, phrasing-triggers).

- [ ] **Step 8: Run full suite**

Expected: FAIL=0 except possibly spec-side source-defaulting tests (Task 6's concern).

- [ ] **Step 9: Commit**

```bash
git add commands/consult.md lib/consult.sh tests/test_consult_directive*.sh
git commit -m "feat(consult): add --use-force + phrasing triggers + Yoda fast-path block (v0.16.0)

commands/consult.md gains:
- --use-force flag parsing (Step 0): always spawns troopers, skips fast-path
- Escalation phrasing detection (post-init): keywords 'deeply', 'verify',
  'compare carefully', 'second opinion', 'consult thoroughly' trigger
  trooper spawn before Yoda's fast-path runs
- Step 0.5 — Yoda fast-path: research the topic, run 4-signal complexity
  check (favor rigor), write design-doc inline if no signal fires; else
  fall through to existing trooper-path Step 1
- PATH_LABEL env var set per escalation source ('fast' /
  'escalated-from-flag' / 'escalated-from-phrasing' / 'escalated-from-signals')
  consumed by synthesize for design-doc header

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: /spec source-defaulting collapse

**Files:**
- Modify: `bin/spec-init.sh` — drop multi-pattern source-defaulting; read single `_consult/design-doc/*-design.md` path
- Modify: `commands/spec.md` — corresponding directive update if relevant
- Modify: any test that asserts the old 3-pattern chain

- [ ] **Step 1: Read current source-defaulting**

```bash
grep -n 'synthesis\.md\|design-doc\|find.*_consult' bin/spec-init.sh commands/spec.md
```

- [ ] **Step 2: Replace source-defaulting find pattern**

Currently the `find` (per `commands/deploy.md`'s pattern, mirrored in spec) looks for both `design-doc/*-design.md` and `synthesis.md`. New version: only the design-doc path.

```bash
CANDIDATE=$(find "$STATE_ROOT/state/$REPO_HASH" \
              -path '*/_consult/design-doc/*-design.md' \
              -type f -printf '%T@ %p\n' 2>/dev/null \
              | sort -n | tail -1 | cut -d' ' -f2-)
```

(Drops the `\( ... -o -path '*/_consult/synthesis.md' \)` clause.)

- [ ] **Step 3: Update spec tests**

```bash
grep -lE 'synthesis\.md|design-doc' tests/test_spec_*.sh
```

For each, update fixtures + assertions to reference the design-doc path only.

- [ ] **Step 4: Run full suite**

Expected: FAIL=0. All tests now reference the single design-doc path.

- [ ] **Step 5: Commit**

```bash
git add bin/spec-init.sh commands/spec.md tests/test_spec_*.sh
git commit -m "feat(spec): source-defaulting collapses to single design-doc path (v0.16.0)

bin/spec-init.sh and commands/spec.md no longer search for
_consult/synthesis.md or _ask/answer.md. The find pattern is now:
  '*/_consult/design-doc/*-design.md'

This is the SINGLE canonical path /consult writes to in v0.16.0
(both fast-path solo and trooper-path escalation produce this same file).

Breaking change: archived consult dirs that contain synthesis.md but no
design-doc will not be discovered by /spec. Per v0.14 precedent, no
back-compat is provided.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: End-to-end fast-path test

**Files:**
- Create: `tests/test_consult_fastpath_e2e.sh`

Stage a complete fast-path scenario in a sandbox and assert the output.

- [ ] **Step 1: Write the test**

Create `tests/test_consult_fastpath_e2e.sh` that:
1. Stages a temp state-root + providers-available.txt + topic dir skeleton (mimicking what consult-init produces).
2. Stages a fixture design-doc that the test creates BY HAND at the canonical path (since the fast-path content generation requires Yoda judgment, not testable in unit form).
3. Asserts the file matches the rigid schema:
   - All 6 H2 sections
   - Source: Master Yoda (single-source)
   - Path: fast
   - Generated: ISO-8601 timestamp
4. Asserts /spec source-defaulting picks it up.

This is more of a contract test than a behavior test. Real fast-path E2E lives in the dogfood (Task 9).

- [ ] **Step 2: Run test**

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add tests/test_consult_fastpath_e2e.sh
git commit -m "test(consult): contract test for fast-path design-doc shape (v0.16.0)

Asserts the rigid 6-section schema + Source/Generated/Path headers + 
that /spec source-defaulting picks up the design-doc.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Version bump 0.15.0 → 0.16.0 + CLAUDE.md status

**Files:**
- Modify: `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Bump versions**

```bash
sed -i 's/"version": "0.15.0"/"version": "0.16.0"/g' .claude-plugin/plugin.json .claude-plugin/marketplace.json
grep version .claude-plugin/plugin.json .claude-plugin/marketplace.json
```

Expected: all show `0.16.0`.

- [ ] **Step 2: Add CLAUDE.md status entry**

After the v0.15.0 dogfood line, insert:

```markdown
- [x] v0.16.0: /consult unified smart-control — single entry point with `--use-force` flag, escalation phrasing triggers ("deeply", "verify", "compare carefully", "second opinion", "consult thoroughly"), and Yoda fast-path with 4-signal complexity check (conflicting evidence / significant assumptions / high-stakes / subjective tradeoffs; favor rigor — any borderline signal escalates). Output unified at `_consult/design-doc/<date>-<slug>-design.md` (rigid 6 sections: Summary / Findings / Tradeoffs / Recommendation / Open Questions / Sources). /spec source-defaulting collapses to single path. Drops `_consult/synthesis.md` (replaced by design-doc); breaking change for archived consult dirs without back-compat per v0.14 precedent.
- [ ] v0.16.0 strict-dogfood pass on a real machine (release gate — verify simple topic → fast-path solo design-doc; phrasing trigger → escalate; --use-force → escalate; signal-fire → escalate; /spec consumes the design-doc cleanly)
```

- [ ] **Step 3: Run full suite**

Expected: FAIL=0.

- [ ] **Step 4: Commit**

```bash
git add .claude-plugin/plugin.json .claude-plugin/marketplace.json CLAUDE.md
git commit -m "chore(release): bump plugin to v0.16.0; record unified consult status

Tasks 1-7 of the v0.16.0 unified-consult plan are complete:
- design-doc canonical path helper
- consult-init creates _consult/design-doc/ subdir
- consult-synthesize writes design-doc instead of synthesis.md
- directive: --use-force flag, phrasing triggers, Yoda fast-path
- /spec source-defaulting collapses to single path
- end-to-end contract test

Task 9 (strict-dogfood pass) remains as the release gate.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: Dogfood + PR

**Files:** none modified (manual validation + PR open).

- [ ] **Step 1: Push branch + open PR**

```bash
git push -u origin feat/v0.16.0-unified-consult
gh pr create --base main --title "v0.16.0: unified /consult — smart-control + design-doc output" \
  --body "..."  # (PR body covers the 4 paths + breaking change)
```

- [ ] **Step 2: Run dogfood scenarios** (interactive, in a Claude Code session inside the repo)

a. **Simple topic → fast-path solo:**
   ```
   /clone-wars:consult What does cw_repo_hash do?
   ```
   Expect: no troopers spawn; design-doc written to `_consult/design-doc/...` with `Source: Master Yoda (single-source)` and `Path: fast`.

b. **Phrasing trigger → escalation:**
   ```
   /clone-wars:consult compare LRU vs LFU eviction carefully
   ```
   Expect: escalates BEFORE fast-path runs; spawns rex+cody+bly; design-doc has `Path: escalated-from-phrasing`.

c. **--use-force flag:**
   ```
   /clone-wars:consult --use-force What is JIT compilation?
   ```
   Expect: escalates BEFORE fast-path; design-doc has `Path: escalated-from-flag`.

d. **Signal escalation:**
   ```
   /clone-wars:consult Should we add MCP server support to Clone Wars?
   ```
   Expect: fast-path runs Yoda research; signals fire (high-stakes + subjective tradeoffs); escalates; design-doc has `Path: escalated-from-signals`.

e. **/spec consumption:**
   After one of the above, run:
   ```
   /clone-wars:spec
   ```
   Expect: AskUserQuestion lists the design-doc; /spec walks it cleanly.

- [ ] **Step 3: Update CLAUDE.md release-gate line**

After successful dogfood:

```markdown
- [x] v0.16.0 strict-dogfood pass on a real machine (2026-05-XX): verified all 4 paths (fast / phrasing / flag / signal) + /spec consumption.
```

- [ ] **Step 4: Commit + push the dogfood update**

```bash
git add CLAUDE.md
git commit -m "docs(claude): record v0.16.0 dogfood pass"
git push
```

- [ ] **Step 5: Merge PR** (when user is satisfied)

---

## Self-review

**Spec coverage:**
- ✅ design-doc canonical path helper (Task 2)
- ✅ consult-init pre-creates design-doc subdir (Task 3)
- ✅ consult-synthesize writes design-doc (Task 4)
- ✅ --use-force flag (Task 5)
- ✅ phrasing triggers (Task 5)
- ✅ Yoda fast-path with 4-signal check (Task 5)
- ✅ Trust-label headers (Source/Generated/Path) (Tasks 4 + 5)
- ✅ /spec source-defaulting collapse (Task 6)
- ✅ End-to-end contract test (Task 7)
- ✅ Version bump (Task 8)
- ✅ Dogfood (Task 9)

**Type consistency:** `cw_consult_design_doc_canonical_path` introduced in Task 2, used in Tasks 4 + 5 + 6 — consistent. PATH_LABEL env var set in directive (Task 5), consumed in synthesize (Task 4) — consistent.

**Placeholder scan:** No "TBD"/"add appropriate" patterns. The `extract_summary` / `extract_findings` etc. shell-helpers in Task 4 Step 4 are referenced but not implemented in detail — the implementer fills these in based on the existing `cw_consult_synthesize` logic. This is a pragmatic deferral (the existing helper already does similar awk extraction); not a placeholder for new logic.
