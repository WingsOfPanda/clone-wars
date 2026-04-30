# Clone Wars Consult — design-doc assemble header-extraction fixes (v0.4.1)

**Status:** Design (2026-04-30)
**Target version:** v0.4.1
**Author:** Master Yoda + WingsOfPanda
**Source incident:** v0.4.0 dogfood run on `consult-decide-between-lru-a` produced `docs/clone-wars/specs/2026-04-30-decide-between-lru-a-design.md` with three header-extraction quirks (commit `44e791f`).

## Goal

Fix three rough edges in `cw_consult_design_doc_assemble`'s header generation that v0.4.0's dogfood run surfaced. Scope is a single helper + its test fixture; no behavior changes to Step 8.5 directive, the orchestrator script, or the per-section walk.

## Motivation

The v0.4.0 dogfood produced a usable design.md but with three cosmetic-but-meaningful header bugs:

1. **Title fragment.** `consult-init.sh` truncates the topic slug to 20 chars to stay under spawn.sh's 32-char regex. For "decide between LRU and LFU cache eviction", the slug becomes `decide-between-lru-a` — Title-Case produces "Decide Between Lru A Design", which mis-implies "LRU-A" is a thing.
2. **Goal-line bloat.** The current helper uses `head -n1 architecture.md` as the **Goal** field. When architecture.md's first line is a 250-character paragraph (which it usually is — the section opens with prose, not a one-liner), the **Goal** header becomes that whole paragraph, defeating the purpose of a one-line summary.
3. **Architecture-line collapses into the next heading.** The current awk extracts "lines 3 through first-blank-line" as the **Architecture** field. When architecture.md does NOT have a 2-3-sentence summary paragraph between the opener and the next H2 (it just goes opener → `## Per-policy …`), the awk concatenates the H2 text into **Architecture**, producing `**Architecture:** ## Per-policy fixed properties`.

These are not blockers — the resulting doc is still readable, and the section bodies are correct. But the header bands are the first thing a reader sees, so the cosmetic cost is real.

## Architecture

Single bash function (`cw_consult_design_doc_assemble` in `lib/consult.sh`) is patched in three places. No new files, no new helpers, no signature changes.

### Fix 1 — Title from `topic.txt`, not slug

The orchestrator (`bin/consult-design-doc.sh`) currently builds the title by Title-Casing the truncated slug. Replace with: read `_consult/topic.txt` (the original full user topic, unmodified), Title-Case that, fall back to slug-Title-Case if topic.txt missing.

**Effect:** for slug `decide-between-lru-a` with topic.txt = `decide between LRU and LFU cache eviction`, title becomes `Decide Between Lru And Lfu Cache Eviction Design`. (Mixed-case acronyms remain Title-Case'd to "Lru" rather than "LRU"; that's the cost of a one-liner pass — acceptable.)

### Fix 2 — Goal from synthesis.md, not architecture.md

The synthesis already contains a section-zero summary block that is shorter and more decision-shaped than architecture.md's opener. Read `_consult/synthesis.md` and extract the first non-empty line under `## Agreed findings` (or, falling through, under `## Cross-verified`). If neither header is present, fall back to the current `head -n1 architecture.md` behavior with a 200-char hard truncate.

**Effect:** the **Goal:** field becomes a one-line statement of what the cross-verified findings agreed on, not architecture's lede paragraph.

### Fix 3 — Architecture-line H2-aware

Update the awk in `cw_consult_design_doc_assemble`:

```bash
# Before:
arch_line=$(awk '
  NR<3 {next}
  /^## Tech Stack$/ {exit}
  NF==0 {exit}
  {print}
' "$section_dir/architecture.md" | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')

# After:
arch_line=$(awk '
  NR<3 {next}
  /^## / {exit}                # any H2 heading boundary, not just Tech Stack
  NF==0 {exit}
  {print}
' "$section_dir/architecture.md" | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')
```

**Effect:** when architecture.md has no body paragraph between the opener and the next H2 (`## Per-policy …` etc.), the awk halts at the H2 boundary and the **Architecture:** field becomes `(see Architecture section)` (the existing fallback).

## Components

### Modified — `lib/consult.sh::cw_consult_design_doc_assemble`

Three localized changes inside the existing function:

1. **Title source.** Accept an optional 4th argument `<topic-text>` (full topic from `_consult/topic.txt`); when present, Title-Case it for the H1 line in preference to the `<title>` arg derived from the slug. Backwards-compatible: if 4th arg is empty/absent, behavior matches v0.4.0.
2. **Goal source.** When called by `bin/consult-design-doc.sh`, the orchestrator passes a 5th argument `<synthesis-path>`; the helper greps the first non-empty line under `## Agreed findings` (then `## Cross-verified`) and uses that as **Goal**, falling back to architecture.md's first line truncated to 200 chars.
3. **Arch-line awk.** Inline change — `/^## Tech Stack$/ {exit}` → `/^## / {exit}`.

### Modified — `bin/consult-design-doc.sh`

Pass `_consult/topic.txt` content as the new title arg, and `_consult/synthesis.md` as the new synthesis-path arg. No other change.

```bash
# Before:
cw_consult_design_doc_assemble "$DD_DIR" "$OUT_ABS" "$TITLE" || exit 1

# After:
TOPIC_TEXT_FILE="$TOPIC_DIR/_consult/topic.txt"
SYNTHESIS_FILE="$TOPIC_DIR/_consult/synthesis.md"
cw_consult_design_doc_assemble "$DD_DIR" "$OUT_ABS" "$TITLE" \
  "$([[ -f "$TOPIC_TEXT_FILE" ]] && cat "$TOPIC_TEXT_FILE" || echo "")" \
  "$([[ -f "$SYNTHESIS_FILE" ]] && echo "$SYNTHESIS_FILE" || echo "")" \
  || exit 1
```

### Modified — `tests/test_consult_design_doc_assemble.sh`

Add three new test cases (each TDD: write failing, then implement):

- **Case A — title from topic-text override:** call helper with 4th arg = "decide between LRU and LFU cache eviction"; assert H1 contains "Lfu" not "Lru A".
- **Case B — goal from synthesis-path:** create a fake synthesis.md with `## Agreed findings\n- claim 1\n`; call helper with 5th arg pointing to it; assert **Goal:** line contains "claim 1", not architecture.md's opener.
- **Case C — architecture-line stops at any H2:** create architecture.md with `opener\n\n## Heading immediately\nbody`; assert **Architecture:** field is `(see Architecture section)` (fallback fired).
- Existing 3 cases must still pass — no signature regression for callers passing 3 args.

## Data Flow

No new data flows. Three input sources for the header band:

```
Title:
  topic_text_arg (4th arg, optional)
    └── if empty → fall back to title_arg (3rd arg, slug-derived)
    └── Title-Case → H1

Goal:
  synthesis_path_arg (5th arg, optional)
    └── if non-empty AND file exists:
          └── awk: first non-empty line after "## Agreed findings"
          └── if not found: first non-empty line after "## Cross-verified"
          └── if not found: fall through
    └── fall through: head -n1 architecture.md, truncate to 200 chars
    └── if architecture.md missing: "(see Architecture section)"

Architecture:
  architecture.md (if present)
    └── awk: lines 3+ until first H2 boundary OR first blank line
    └── if empty result: "(see Architecture section)"
```

## Error Handling

No new errors. All three fixes preserve the existing fallback chain:

- Missing optional args → use existing 3-arg behavior (matches v0.4.0).
- Missing topic.txt → use slug-derived title (matches v0.4.0).
- Missing synthesis.md → use architecture.md head-truncate (matches v0.4.0).
- Empty arch-line awk result → existing `(see Architecture section)` fallback (matches v0.4.0).

Behavioral guarantee: every v0.4.0 caller of `cw_consult_design_doc_assemble` continues to work unchanged.

## Testing

`tests/test_consult_design_doc_assemble.sh` grows from 3 to 6 test cases (one per fix). Each follows the TDD shape: write failing test → implement → run → commit (in line with v0.4.0 plan style).

Manual verification: re-run the dogfood that surfaced the bugs:

```
/clone-wars:consult --design-doc decide between LRU and LFU cache eviction
```

Expected post-fix output:
- H1: `Decide Between Lru And Lfu Cache Eviction Design`
- **Goal:** one-line agreed-findings summary (~80 chars)
- **Architecture:** `(see Architecture section)` (since architecture.md goes straight into `## Per-policy fixed properties`)

Re-run is cheap (a fresh consult on the same topic creates `consult-decide-between-lru-a-2`); no archive cleanup needed.

## Out of Scope

- Acronym preservation in Title-Case (would require a heuristic / dictionary).
- Goal-line extraction from non-`brainstorming` synthesis layouts (only `## Agreed findings` and `## Cross-verified` are supported; defer if other layouts appear).
- Operator override of header band via CLI flag (would require argv plumbing through `commands/consult.md`; defer to v0.5 if requested).
- Re-running assemble on existing committed design.md (still requires manual `rm` of the output path; the overwrite-refuse path is unchanged).

## Open Questions

None. All decisions made above.

## References

- v0.4.0 spec: `docs/superpowers/specs/2026-04-29-clone-wars-consult-design-doc-mode-design.md`
- v0.4.0 plan: `docs/superpowers/plans/2026-04-29-clone-wars-consult-design-doc-mode-plan.md`
- v0.4.0 dogfood output: `docs/clone-wars/specs/2026-04-30-decide-between-lru-a-design.md` (commit `44e791f`)
- Helper under change: `lib/consult.sh::cw_consult_design_doc_assemble`
- Test file under change: `tests/test_consult_design_doc_assemble.sh`
