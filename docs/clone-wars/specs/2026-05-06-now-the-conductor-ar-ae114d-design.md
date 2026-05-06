# Now The Conductor Are Always Master Yoda, I Want Each Time It Can Randomly Choice From Master Windo, Master Keno Bi, Master Qui-gan, Etc. Get It From Star Wars Design

**Goal:** [config/prompt-templates/identity.md:7] Every generated trooper identity currently tells the trooper that "Master Yoda" will write and nudge inbox.md, so randomized conductor names must be injected in

**Architecture:** The conductor identity (the persona Claude Code adopts when running `/clone-wars:*` commands) becomes a **per-topic randomized choice** drawn from a separate Jedi-Master pool, decoupled from the existing clone-trooper commander pool.

**Tech Stack:**
- (see Components section)

---

## Architecture

## Architecture

The conductor identity (the persona Claude Code adopts when running `/clone-wars:*` commands) becomes a **per-topic randomized choice** drawn from a separate Jedi-Master pool, decoupled from the existing clone-trooper commander pool.

**Three load-bearing principles:**

1. **Topic-scoped, not global.** The conductor is resolved once on the first spawn for a given topic and pinned for the duration of that operation. Two consults running in parallel can have different conductors; subsequent spawns / sends / consult phases on the same topic always read the pinned value. Re-rolling mid-flight would scramble the trooper-visible `From:` header and break the autonomy contract.

2. **Slug + display-name pair.** Every entry in the pool carries a `slug` (`master-windu`) used for `--from` attribution and matched against the existing `^[a-zA-Z0-9_-]+$` validator, plus a `display` (`Master Mace Windu`) used in narrative UI text. The slug is the load-bearing identifier; the display name is purely cosmetic.

3. **Test-pinnable via env override.** A `CW_CONDUCTOR_OVERRIDE=master-yoda` env var bypasses randomization. Existing dogfood tests that grep for `master-yoda` keep working without rewrites; CI runs deterministically.

**What stays the same:** the existing `cw_inbox_write --from <name>` validator, the `commanders.yaml` clone-trooper pool, and all current sender-attribution semantics. We are layering a new resolution step on top, not replacing existing primitives.

**What's new:** a `config/conductors.yaml` pool, a `lib/conductor.sh` helper module (mirrors the shape of `lib/commanders.sh`), and a small sidecar file `<topic-state-dir>/conductor.txt` storing the pinned slug for each topic. The identity-template gains two mustache tokens (`{{conductor_slug}}` and `{{conductor_display}}`); the slash-command directives read either `$CW_CONDUCTOR` (set at directive entry) or the sidecar.

**Out of scope:** replacing the clone-trooper commander pool, multi-conductor coordination (>1 Jedi per topic), historical replay (rolling back conductor choice for a finished run), and species/title metadata beyond the slug+display pair. Pole-vault into Council canon trivia is rejected — keep the pool to ~12 named Jedi Masters of the prequel/Clone-Wars era.

## Components

## Components

**1. `config/conductors.yaml`** — new file, 5 entries. YAML shape mirrors `commanders.yaml` (one entry per line, `slug: display` form):

```yaml
master-yoda:     "Master Yoda"
master-windu:    "Master Mace Windu"
master-kenobi:   "Master Obi-Wan Kenobi"
master-qui-gon:  "Master Qui-Gon Jinn"
master-luminara: "Master Luminara Unduli"
```

Tight, recognizable pool. The four user-named Jedi plus Luminara as a fifth voice. Adding entries later is a one-line change.

**2. `lib/conductor.sh`** — new helper module, modeled on `lib/commanders.sh`:

- `cw_conductor_pool()` — emits `slug<TAB>display` lines from conductors.yaml; falls back to a single hard-coded `master-yoda<TAB>Master Yoda` row if the file is missing.
- `cw_conductor_pick_random()` — picks one slug uniformly via `shuf | head -n1` (no exclusion logic — pool is small, repetition across topics is fine).
- `cw_conductor_display(slug)` — returns the display name for a slug, or the slug itself if not found in pool.
- `cw_conductor_resolve(topic_dir)` — the orchestrator: returns existing sidecar content if present; otherwise picks random, writes sidecar atomically (`tmp + rename`), returns slug. Honors `$CW_CONDUCTOR_OVERRIDE` first.

**3. Sidecar file** — `<topic-state-dir>/conductor.txt`. Single line, slug only. Written once on the first `cw_conductor_resolve` call for a topic. Survives across spawn/send/collect cycles in the same topic.

**4. Modifications to existing files:**

- `bin/spawn.sh` — call `cw_conductor_resolve` early; export `CW_CONDUCTOR=<slug>` and `CW_CONDUCTOR_DISPLAY=<display>` for downstream `cw_identity_write`.
- `lib/state.sh` (or wherever `cw_identity_write` lives) — substitute `{{conductor_slug}}` and `{{conductor_display}}` mustache tokens in the identity template.
- `config/prompt-templates/identity.md` — replace literal "Master Yoda" with `{{conductor_display}}` (and the slug equivalent if it appears separately).
- `bin/send.sh` — when `--from` is omitted, attempt `cw_conductor_resolve` against the topic state dir; if that fails (no sidecar yet, no topic), keep `master-yoda` as the legacy default.
- `commands/consult.md` (and other directives that hard-code `master-yoda` or "Master Yoda") — Step 0 reads `$TOPIC_DIR/conductor.txt` after `consult-init.sh`, exports `CW_CONDUCTOR` and `CW_CONDUCTOR_DISPLAY`, then uses those variables in `--from` args, `description=` strings, and prose templates.
- `lib/consult.sh:308,315` — replace literal "Master Yoda" in adjudicated.md template HTML comments with `${CW_CONDUCTOR_DISPLAY:-Master Yoda}`.

**5. Comments-only updates** (cosmetic):

- `bin/spawn.sh:137` and `lib/tmux.sh:10` — pane-layout comments saying "right-split of Master Yoda" change to "right-split of the conductor pane" (provider-agnostic; no need to thread the variable through comments).

## Data Flow

## Data Flow

**1. First spawn for a topic (`/clone-wars:spawn rex codex topic-foo`):**

```
bin/spawn.sh
  → cw_state_ensure
  → cw_conductor_resolve(topic_dir)
       └─ $CW_CONDUCTOR_OVERRIDE set?  → return override slug, write sidecar
       └─ <topic_dir>/conductor.txt exists?  → return its contents (idempotent)
       └─ else: cw_conductor_pick_random
            → atomic write (tmp + rename) → <topic_dir>/conductor.txt
            → return chosen slug
  → export CW_CONDUCTOR=<slug>  CW_CONDUCTOR_DISPLAY=<display>
  → cw_identity_write trooper_dir <conductor_display>
       └─ substitutes {{conductor_display}} into identity.md
  → tmux split-window … (existing flow)
  → ack ready event in outbox
```

The trooper sees an identity prompt that says e.g. "Master Mace Windu (your commanding officer in Claude Code) will write to inbox.md..." instead of "Master Yoda".

**2. Second spawn on same topic (`/clone-wars:spawn cody claude topic-foo`):**

`cw_conductor_resolve` reads the existing sidecar and returns the same slug — both troopers report to the same conductor for the duration of the topic. No re-roll.

**3. Sending to a trooper (`/clone-wars:send <commander> <topic> <prompt>` with no `--from`):**

```
bin/send.sh
  → if --from explicit → use it (existing behavior)
  → else: cw_conductor_resolve(topic_dir)
       └─ sidecar present → use its slug
       └─ sidecar absent (e.g. send to a topic with no spawned troopers) → fall back to "master-yoda"
  → cw_inbox_write --from <slug> <topic> <prompt> (existing flow)
```

**4. Slash-directive entry (e.g. `/clone-wars:consult`):**

```
commands/consult.md Step 0
  → consult-init.sh "$ARG_RAW"
  → CW_CONDUCTOR=$(cw_conductor_resolve "$TOPIC_DIR")
  → CW_CONDUCTOR_DISPLAY=$(cw_conductor_display "$CW_CONDUCTOR")
  → export both for the rest of the directive
  → all subsequent /clone-wars:send --from <…> calls use $CW_CONDUCTOR
  → all subsequent description='<conductor> await captain rex …' use $CW_CONDUCTOR_DISPLAY
```

**5. Trooper question-loop response:**

When Yoda (now Mace Windu / Obi-Wan / etc.) answers a `FS=question` event, the response inbox carries the resolved conductor slug in the `From:` header — so the trooper's audit trail attributes the answer correctly to the persona it sees in its identity prompt. Self-consistent.

**6. Teardown:** `consult-teardown.sh` is unchanged; the sidecar file moves to archive along with the rest of the topic state. No special cleanup.

## Error Handling

## Error Handling

**1. Missing `config/conductors.yaml`** — `cw_conductor_pool` falls back to a single hard-coded row `master-yoda<TAB>Master Yoda`. `cw_conductor_pick_random` always returns `master-yoda`. The system stays functional with the legacy persona; no spawn fails. `medic.sh` warns when the file is absent so users notice.

**2. Empty / malformed `conductors.yaml`** — same fallback. `cw_conductor_pool` validates each line with the `^[a-zA-Z0-9_-]+$` slug regex before emitting; entries that fail are skipped (with a stderr warning). If zero valid entries remain, fall through to the master-yoda baseline.

**3. Slug not in pool** (e.g. `CW_CONDUCTOR_OVERRIDE=master-jar-jar` or stale sidecar after pool edit) — `cw_conductor_resolve` validates against the pool. If invalid: log a warning, fall back to `master-yoda`, do NOT overwrite the sidecar (preserves user intent for inspection). `cw_conductor_display` returns the slug verbatim if not found, so display strings degrade gracefully.

**4. Sidecar write race** — two parallel spawns on the same topic could both call `cw_conductor_resolve` simultaneously. Resolve via `tmp + rename`: if the rename target already exists (second spawn lost the race), re-read the sidecar and use its value. Both spawns end up pointing at the same conductor; whichever wrote first wins.

**5. Sidecar write failure** (read-only FS, permission error) — log warning, return the picked slug for the current process only. Subsequent processes will re-roll, which is suboptimal but not catastrophic — the conductor identity is cosmetic for the trooper, not load-bearing for IPC. Dogfood smoke test exercises this with a chmod'd state dir.

**6. `CW_CONDUCTOR_OVERRIDE` always wins** — even if the sidecar exists with a different value. This makes test pinning bullet-proof: tests that grep for `master-yoda` set the env var and the resolver bypasses both the pool and the sidecar. Documented in `tests/README.md` (or test-suite header comments).

**7. Identity-template rendering failure** (mustache token unsubstituted) — `cw_identity_write` already validates output for unsubstituted `{{...}}` tokens; an unsubstituted `{{conductor_display}}` causes spawn to abort with a clear error. No silent degradation.

**8. Backward compatibility** — existing topic state dirs from before this feature ships have no `conductor.txt`. On the next spawn for such a topic, `cw_conductor_resolve` writes a fresh sidecar (random pick) and proceeds. The trooper sees the new persona; no migration needed.

## Testing

## Testing

**1. New `tests/test_conductor.sh`** — focused unit tests for `lib/conductor.sh`. Mirror the structure of `tests/test_commanders.sh`. Cover:

- `cw_conductor_pool` — happy path (5 entries from shipped yaml), missing file (single fallback), malformed line (skipped + warned).
- `cw_conductor_pick_random` — returns a slug from the pool; never blank; deterministic when `CW_CONDUCTOR_OVERRIDE` set.
- `cw_conductor_display` — round-trip slug → display for every shipped entry; unknown slug returns slug verbatim.
- `cw_conductor_resolve` — first-call writes sidecar atomically; second-call reads existing sidecar (idempotency); race-condition simulation (two concurrent calls land on the same value); override wins over both pool and sidecar; invalid override falls back to `master-yoda` without overwriting sidecar.
- Slug validation — every shipped slug passes `^[a-zA-Z0-9_-]+$`.

**2. Pin existing tests with override.** The current dogfood + send-flag tests grep for the literal string `master-yoda`. Wrap them with `CW_CONDUCTOR_OVERRIDE=master-yoda` (env var prefix on each test invocation, or set in a shared `tests/setup.sh`):

- `tests/test_send_from_flag.sh` — assert default-sender = `master-yoda` requires pinning.
- `tests/test_consult_v050_dogfood.sh` — full-pipeline grep assertions.
- Any `tests/test_*` that currently asserts `master-yoda` in identity-template output.

The env-var-override approach keeps test fixtures unchanged; rolling out the feature doesn't churn existing tests.

**3. New integration test** `tests/test_conductor_integration.sh` (gated on tmux + codex):

- Spawn a single trooper without override → confirm sidecar exists, slug is in pool, identity prompt rendered with matching display name.
- Spawn a second trooper on the same topic → confirm sidecar unchanged, both troopers' identity prompts use the same display name.
- Tear down → confirm sidecar archived alongside topic state.
- Skip cleanly (rc=0 with SKIP banner) when tmux/$TMUX/codex is missing.

**4. `medic.sh` extension** — add a check for `config/conductors.yaml` presence (warn-only, mirrors the existing `commanders.yaml` check). New deploy-helpers-load probe should also validate `lib/conductor.sh` sources cleanly.

**5. Manual dogfood gate** (release checklist, not automated):

- Run `/clone-wars:consult <topic>` two times in a row without override; confirm the conductor changes between runs (probabilistic but high-likelihood given pool size 5).
- Inspect a trooper's `identity.md` and confirm the display name matches the sidecar slug.
- Run a full deploy via `/clone-wars:deploy <design-doc>` and confirm the cody-codex trooper sees the resolved conductor in its prompt + question-response replies.

**6. Test-suite invariant** — `tests/run.sh` runs all `test_*.sh` files. New tests use the same `set -euo pipefail` discipline and `cw_assert_*` helpers as existing tests; no new test framework or dependency.

