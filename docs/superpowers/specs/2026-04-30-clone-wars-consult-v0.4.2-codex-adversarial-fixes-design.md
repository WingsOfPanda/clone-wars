# Clone Wars Consult — v0.4.2 Codex adversarial-review fixes

**Status:** Design (2026-04-30)
**Target version:** v0.4.2
**Author:** Master Yoda + WingsOfPanda
**Source incident:** Codex adversarial review of v0.3.2..main returned `needs-attention` with 2 high + 4 medium findings.

## Goal

Patch the six issues Codex flagged in v0.4.0/v0.4.1 design-doc mode. All fixes are localized to `commands/consult.md`, `bin/consult-design-doc.sh`, `lib/consult.sh`, and one new helper. No new IPC, no new sub-script, no Step 8.5 rearchitecture.

## Motivation

Codex review surfaced six release-blocking-or-frustrating issues:

1. **[high] Self-review writes to the final path before checking for placeholders** → next rerun is blocked by the collision guard. Recovery is manual `rm`.
2. **[high] Slug-derived filename collisions** — two same-day topics whose first 20 slug chars match produce the same `docs/clone-wars/specs/<date>-<slug>-design.md`. Reproduced.
3. **[medium] Panes idle through unbounded user-review gate** — model TTYs left alive across review pauses with no keepalive or recovery.
4. **[medium] Classifier-only reachability** — topics that don't match the regex (e.g., "evaluate Postgres vs SQLite") never get a Step 8.5 offer, even when shaped like a design choice.
5. **[medium] Drill-down only accepts `rex`/`cody`** — user can't request both troopers; falls into improvised handling.
6. **[medium] `--design-doc` parsed as substring** — any topic containing the literal substring is mutated and forced into design-doc mode.

Each is small individually; rolling all six into a single patch prevents v0.4.3/v0.4.4/v0.4.5 churn for issues that were all surfaced in the same review pass.

## Architecture

No structural changes. Five files patched:

- `commands/consult.md` — Step 0 flag parsing (#6); Step 8.5 entry gate (#4); drill-down option list (#5); teardown-before-review-gate (#3).
- `bin/consult-design-doc.sh` — assemble-to-tmp + atomic move (#1); slug+hash filename derivation (#2).
- `lib/consult.sh` — new `cw_consult_design_doc_filename` signature (slug + hash arg); helper supports the new path.
- `tests/test_consult_design_doc_filename.sh` — coverage for hash-suffix mode.
- `tests/test_consult_design_doc_assemble.sh` — no signature change, but new test for atomic-move + collision-on-rerun cases via the orchestrator end-to-end script.
- New: `tests/test_consult_flag_parse.sh` — token-vs-substring flag parsing for `--design-doc`.

## Components

### Fix #1 — Atomic write on self-review pass

`bin/consult-design-doc.sh` currently:
```
assemble → OUT_ABS
self_review OUT_ABS → if dirty: exit 1 (file remains)
```

Patched flow:
```
assemble → OUT_TMP   (unique tmp file under same dir)
self_review OUT_TMP → if dirty: rm OUT_TMP, exit 1, error message
                   → if clean: mv OUT_TMP OUT_ABS, then commit
```

`OUT_TMP` lives next to `OUT_ABS` so `mv` is rename-only (atomic on same filesystem). On dirty-exit the temp file is removed; rerun finds neither `OUT_TMP` nor `OUT_ABS` and assembly proceeds clean.

### Fix #2 — Filename uniqueness via hash suffix

Current: `docs/clone-wars/specs/YYYY-MM-DD-<truncated-slug>-design.md`. Two topics that share the first 20 slug chars collide.

Patch: append a 6-char hash of the **full topic text** (from `_consult/topic.txt`) to the slug. New form:

```
docs/clone-wars/specs/YYYY-MM-DD-<slug>-<hash6>-design.md
```

Hash: first 6 hex chars of `sha256(topic-text)`. For backward-compat: if the orchestrator is invoked without a topic-text source, the hash arg is empty and the old form `<date>-<slug>-design.md` is preserved. Production path always supplies the hash.

`cw_consult_design_doc_filename` accepts an optional 2nd arg `<hash6>`; when non-empty, inserts `-<hash6>` before `-design.md`.

### Fix #3 — Tear down before user-review gate

Current Step 8.5 flow:
```
walk 5 sections
  └── drill-deeper sub-loop CAN dispatch troopers (alive)
finalize → assemble + commit
user-review gate (panes still alive)  ← Codex's concern
Step 9 teardown
```

Patched flow:
```
walk 5 sections
  └── drill-deeper sub-loop CAN dispatch troopers (alive)
finalize → assemble + commit
Step 9 teardown (BEFORE the gate)        ← moved up
user-review gate (panes already gone)
Step 10 archive + present
```

Trade-off acknowledged: post-gate edits cannot drill troopers anymore. Acceptable because:
- Drill-deeper is a *during-walk* affordance, not a post-commit one.
- After commit, edits are git-tracked manual changes — appropriate for the existing-doc surface.
- Eliminates idle-pane risk in the >1-minute case.

### Fix #4 — Always-offer post-synthesis prompt

Current: implicit prompt only fires when `skill.txt == brainstorming`.

Patch: implicit prompt always fires unless `$DESIGN_DOC=1` (explicit flag already set the mode) **or** classifier returned `systematic-debugging` (clear non-design intent — auditing/triage). For `none` (the catch-all), prompt fires.

Updated entry-condition predicate (Step 8.5):
```
if DESIGN_DOC == 1:
    enter Step 8.5 (no prompt)
elif skill_txt == "systematic-debugging":
    skip Step 8.5
else:  # brainstorming OR none
    AskUserQuestion: "Want to walk through a design doc?"
    if yes: enter Step 8.5
    else:   skip
```

### Fix #5 — Drill-down "both" option

Current options: `rex (codex)` / `cody (claude)`.

Patched options: `rex (codex)` / `cody (claude)` / `both`. When `both`:
- Dispatch parallel drill-downs (two `send.sh` calls + two `cw_outbox_wait_since` calls).
- Two output files: `drilldown-<section>-rex.md` and `drilldown-<section>-cody.md` (the helper already names them by commander).
- Yoda folds both into the section draft, attributing each finding by commander.
- If one trooper times out and the other completes, ask: continue with available / retry the failed / abort drill.

### Fix #6 — Token-based flag parsing

Current:
```bash
[[ "$ARG_RAW" == *"--design-doc"* ]]
ARG_RAW=$(echo "$ARG_RAW" | sed 's/--design-doc//' | sed 's/  */ /g; s/^ //; s/ $//')
```

Patched (token-aware): split `$ARG_RAW` on whitespace, remove only exact `--design-doc` tokens, rejoin:

```bash
DESIGN_DOC=0
NEW_TOKENS=()
for tok in $ARG_RAW; do
  if [[ "$tok" == "--design-doc" ]]; then
    DESIGN_DOC=1
  else
    NEW_TOKENS+=("$tok")
  fi
done
ARG_RAW="${NEW_TOKENS[*]}"
```

`--design-documentation`, `please --design-doc-please`, `--design-docness`, etc. — none match the exact `--design-doc` token, so they pass through unmodified.

## Data Flow

No new flows. Three flow changes in existing logic:

**Step 0 flag parse:** word-tokenize `$ARG_RAW` → filter exact `--design-doc` → rejoin.

**Step 8.5 entry:** `DESIGN_DOC` flag wins; else `skill_txt` decides offer-or-skip; classifier no longer the strict gate for `brainstorming`-only.

**Finalize → teardown → review:** Step 9 teardown moves up *before* the user-review-gate prompt; pane lifecycle is bounded by the walk + finalize, not by user response time.

**Filename derivation:** `cw_repo_root` + `cw_consult_design_doc_filename "$SLUG" "$HASH6"` → `docs/clone-wars/specs/<date>-<slug>-<hash6>-design.md`.

**Atomic write:** `assemble → $OUT_ABS.tmp.$$` → `self-review` → `mv` on clean / `rm` on dirty.

## Error Handling

All preserved + extended:

- **Atomic-write dirty exit (#1):** temp file removed on self-review failure. Rerun is unblocked.
- **Filename collision (#2):** the hash-derived form makes collisions effectively impossible (sha256 first-6 collision probability ≈ 1/2²⁴). For the truly degenerate case (same topic text re-run same day), the existing `[[ -e $OUT_ABS ]]` collision-refusal still fires — same behavior as v0.4.0.
- **Trooper idle elimination (#3):** no new error path; previously-implicit risk now closed.
- **Implicit-prompt false positives (#4):** user can always say "no" to skip — no new failure mode.
- **Drill-down both/partial-failure (#5):** new branch documented above (continue / retry / abort).
- **Flag-parse exact-token (#6):** rejected substrings flow through to topic.txt — same path a no-flag topic takes.

## Testing

### Modified — `tests/test_consult_design_doc_filename.sh`

Add cases for the optional 2nd arg:
- `cw_consult_design_doc_filename "lru-vs-lfu" "abc123"` → `docs/clone-wars/specs/2026-04-29-lru-vs-lfu-abc123-design.md`.
- Empty 2nd arg → falls back to v0.4.x form.
- Hash with non-hex chars rejects (rc=2).

### Modified — `tests/test_consult_design_doc_assemble.sh`

Existing cases unaffected. No new cases here — the atomic-write logic is in the orchestrator, not the helper.

### New — `tests/test_consult_flag_parse.sh`

Standalone test of the token-parsing snippet (extracted to a shell function `cw_consult_parse_design_doc_flag` in `lib/consult.sh` so it's reusable + testable):
- `--design-doc decide foo` → `DESIGN_DOC=1`, `topic="decide foo"`.
- `--design-documentation foo` → `DESIGN_DOC=0`, `topic` unchanged.
- `decide --design-doc foo` → `DESIGN_DOC=1`, `topic="decide foo"`.
- `please --design-doc-please foo` → `DESIGN_DOC=0`, topic unchanged.
- `--design-doc --design-doc bar` → `DESIGN_DOC=1`, `topic="bar"` (multiple flags collapse).
- empty input → `DESIGN_DOC=0`, `topic=""`.

### New — `tests/test_consult_design_doc_orchestrator.sh`

End-to-end test of `bin/consult-design-doc.sh` with a fake `_consult/design-doc/` dir:
- **Atomic-write happy path:** clean sections → assembled file lands at final path, no temp leftovers.
- **Atomic-write dirty path:** sections contain `TBD` → assembly produces a temp file, self-review flags it, temp is removed, no file at final path, exit 1.
- **Atomic-write rerun-after-fix:** dirty run leaves no leftover; replace dirty section with clean → second run succeeds.
- **Filename uniqueness:** invocation passes a hash6; output path contains `-<hash6>-design.md`.

### Manual dogfood

Re-run `/clone-wars:consult --design-doc decide between LRU and LFU cache eviction` after merge:
- Expected output: `docs/clone-wars/specs/YYYY-MM-DD-decide-between-lru-a-XXXXXX-design.md` (with hash suffix).
- After commit, troopers tear down BEFORE the user-review gate.
- Aborting at the user-review-gate leaves the committed doc; troopers + state are already archived.

## Out of Scope (this patch)

- Decoupling `commands/consult.md` flag parsing into a separate `consult-flag-parse.sh` script (overkill; in-line tokenize is fine).
- Hash function alternatives (`sha256` is already a project dep via `cw_repo_hash`; no new dep).
- Re-running design-doc mode against archived state (`/clone-wars:consult-design-doc-from-archive`) — flagged by Codex but a separate feature; can ship as v0.5.0 after this stabilizes.
- Pane keepalive ping (would let panes survive long pauses) — Codex preferred teardown-before-gate, which avoids the problem entirely; deferred.
- Section-rerun mid-walk (codex didn't flag this; previous v0.4.0 review noted as known limitation).

## Open Questions

None. Each fix maps 1:1 to a Codex finding with explicit prescription.

## References

- Codex adversarial review (job `btyf3jv0l`, 2026-04-30): saved as part of conversation transcript.
- v0.4.0 spec: `docs/superpowers/specs/2026-04-29-clone-wars-consult-design-doc-mode-design.md`
- v0.4.1 spec: `docs/superpowers/specs/2026-04-30-clone-wars-consult-design-doc-assemble-fixes-design.md`
- Files under change:
  - `commands/consult.md`
  - `bin/consult-design-doc.sh`
  - `lib/consult.sh::cw_consult_design_doc_filename` + new `cw_consult_parse_design_doc_flag`
- Tests: 1 modified, 2 new.
