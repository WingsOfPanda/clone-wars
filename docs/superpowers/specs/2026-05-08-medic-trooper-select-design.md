# Medic Trooper-Select Design (v0.18.0)

**Date:** 2026-05-08
**Status:** spec — pending implementation plan
**Goal:** Add interactive trooper selection to `/clone-wars:medic`. After the
health table renders, the user picks which subset of detected providers
should be the active roster for `/clone-wars:consult`. Selection persists
across sessions in `$state_root/providers-active.txt` (global, one per
machine/install).

## Problem

Today, `bin/medic.sh` writes `$state_root/providers-available.txt` with
every provider whose binary is on PATH and has a row in `contracts.yaml`.
`bin/consult-init.sh:59` reads that file directly to determine the consult
trooper roster.

Two friction points:

1. **No way to "skip" a detected provider for /consult** without
   uninstalling its binary or hand-editing `providers-available.txt` (which
   gets clobbered on the next medic run). Users with all four providers
   installed (`claude`, `codex`, `opencode`, `gemini`) cannot easily run a
   2-trooper consult on their preferred pair without `--targets`-style
   plumbing per invocation.
2. **No persistence across sessions.** The N=2 vs N=3 choice for a
   /consult run today comes from "what does medic happen to detect", not
   from the user's stated preference.

The user wants a checklist after medic detects providers, where they pick
which detected providers should actually be used in consult. The choice
should survive across sessions (re-runs of medic must offer "keep current
selection" as the default).

## Goal

Add an interactive trooper-selection flow to `/clone-wars:medic` that:

- runs every time `/clone-wars:medic` is invoked (always interactive — no
  opt-in flag); whether the user actually sees a prompt depends on the
  detected count (Step C — auto-handles 0 and 1 detected, prompts for
  2+);
- writes `$state_root/providers-active.txt` (one provider per line, same
  format as `providers-available.txt`) only after the user explicitly
  picks a non-empty subset;
- is consumed by `bin/consult-init.sh` in preference to
  `providers-available.txt` when present, falling back to today's
  behavior otherwise;
- keeps `bin/medic.sh` mechanical (no bash interactivity); the prompt
  flow lives in `commands/medic.md`, matching every other interactive
  command in this codebase.

## Architecture

Three thin changes; no new top-level files beyond this spec.

1. **`commands/medic.md`** — gains an interactive selection block AFTER
   the existing `bin/medic.sh` invocation. Reads `providers-available.txt`
   that the script just wrote, presents one `AskUserQuestion` with preset
   subsets, falls through to a per-provider walk on `Customize`, writes
   `providers-active.txt` via the Write tool.
2. **`bin/medic.sh`** — unchanged. Same checks, same
   `providers-available.txt` output (line 211–224), same FAIL/OK
   verdict. No bash `read` interactivity; the prompt is Claude-side
   only.
3. **`bin/consult-init.sh:59`** — replace direct read of
   `providers-available.txt` with `cw_active_providers_path` (a new
   helper in `lib/state.sh`) that returns the user-selected file when
   present and the medic-detected file otherwise.

`providers-active.txt` lives at `$state_root/providers-active.txt`,
i.e. global (`~/.clone-wars/providers-active.txt` by default), the same
scope as `providers-available.txt`. Per-repo state is one level deeper
under `$state_root/state/<repo-hash>/…`; this is above that line — one
selection per machine/install, not per project.

**File format** mirrors `providers-available.txt`:

```
# generated 2026-05-08T14:23:01Z by /clone-wars:medic
# active providers selected by user
codex
claude
```

**Why this shape:**

- The slash-command directive is the only place in the codebase that
  holds Claude-side interactive state (matches `/consult`, `/spec`,
  `/deploy`). Putting the prompt there keeps `medic.sh` runnable from
  CI or a one-shot bash invocation.
- consult-init's contract becomes "active set if you've expressed a
  preference, otherwise everything detected" — back-compatible with
  every consult run that pre-dates this feature.
- `cw_active_providers_path` becomes the single source of truth for
  precedence; future consumers (e.g. `cw_list` with provider filter)
  reuse it instead of duplicating the fallback logic.

## Selection flow

After `bin/medic.sh` returns and the verdict line is printed, the
directive runs Steps A–G Claude-side.

### Step A — Read detected set

Read `$state_root/providers-available.txt`, skipping `#`/blank lines.
Call this `DETECTED`.

### Step B — Read prior selection if any

If `$state_root/providers-active.txt` exists, parse it the same way into
`PRIOR`. Filter `PRIOR` against `DETECTED` (drop entries that are no
longer detected — e.g. user uninstalled a binary, or renamed the
provider in `contracts.yaml`).

If anything was dropped, log `note: removed <provider> from active set
(no longer detected)`.

### Step C — Decide whether to prompt

| Detected count | Behavior |
|---|---|
| `0` | No prompt. medic already FAILed; nothing to choose. |
| `1` | No prompt. Auto-write `providers-active.txt = DETECTED`. Print `auto-selected: <provider> (only detected provider)`. |
| `2` or `3` | Prompt via Step D (preset subsets + Customize fallback). |
| `4` | Skip the preset menu (11+ subset options is too cluttered) and go directly to Step E (per-provider walk). |

### Step D — Preset-subset menu (N=2 or N=3)

Single `AskUserQuestion`. The exact options depend on N:

- **N=2** — 4 options:
  - `Both` (recommended unless `PRIOR` says otherwise)
  - `<commander-A> only`
  - `<commander-B> only`
  - `Customize…`
- **N=3** — 5 options:
  - `All three` (recommended unless `PRIOR` says otherwise)
  - `<A> + <B>` (drop C)
  - `<A> + <C>` (drop B)
  - `<B> + <C>` (drop A)
  - `Customize…`

If `PRIOR` exists and matches one of the preset subsets, label that
option `Keep current selection (X + Y)` and move it to the top as the
recommended option. (`Keep current selection (all three)` for the full-N
case.)

Picking anything except `Customize…` writes `providers-active.txt` with
the chosen subset and exits the flow.

### Step E — Per-provider walk (Customize, or N≥4)

One `AskUserQuestion` per detected provider, in the order they appear in
`providers-available.txt` (which itself follows `contracts.yaml`'s row
order — stable). Options: `Include` / `Exclude`.

Pre-recommended option per provider:

- `Include` if the provider is in `PRIOR` (after the Step B filter), OR
  there is no `PRIOR` (first-time selection treats every detected
  provider as a candidate).
- `Exclude` otherwise (i.e. previously not in `PRIOR`).

After walking all providers, write `providers-active.txt` with the
included set.

### Step F — Empty-set guard

If the user excluded every provider in the walk, refuse to write the
file: print `error: must select at least one provider; selection
unchanged` and leave `providers-active.txt` as-is (or absent if it
didn't exist). Don't re-prompt automatically; user can re-run medic.

### Step G — Atomic write

Write `providers-active.txt` via the **Write tool** (single-shot atomic
write; matches every other Claude-side persistence point in this
codebase). File contents:

```
# generated <ISO-8601 UTC> by /clone-wars:medic
# active providers selected by user
<provider-1>
<provider-2>
…
```

Print a confirmation line: `active set: <commander-A>, <commander-B>
(written to providers-active.txt)`.

## Components

Files touched and their responsibilities, in order of significance.

### `commands/medic.md` (modified — bulk of the work)

Adds a new "Trooper selection" section with Steps A–G. Approximately +60
lines of directive prose. Key requirements:

- **Always-interactive**: every `/clone-wars:medic` run executes Steps
  A–G after step 4 of the existing directive (the verbatim-print step).
- Reads `providers-available.txt` via `Read` tool (or via Bash `cat`).
- Builds preset-subset options dynamically from the detected list and
  `lib/commanders.sh`'s provider-to-commander map (so the menu shows
  human-friendly commander names like "rex + cody" not raw provider
  names).
- Writes `providers-active.txt` via the **Write tool** after a
  non-empty selection.

### `lib/state.sh` (new helper, ~10 lines)

```bash
# cw_active_providers_path — canonical path the consult roster reads.
# Prefers providers-active.txt (user-selected) over providers-available.txt
# (medic-detected). Pure path resolution; does not validate contents.
cw_active_providers_path() {
  local sr; sr="$(cw_state_root)"
  if [[ -f "$sr/providers-active.txt" ]]; then
    printf '%s\n' "$sr/providers-active.txt"
  else
    printf '%s\n' "$sr/providers-available.txt"
  fi
}
```

Lives in `state.sh` because it's pure path resolution alongside
`cw_state_root` / `cw_repo_hash`. Single source of truth for precedence;
future consumers reuse it.

### `bin/consult-init.sh:59` (one-line change)

Replace:

```bash
PROVIDERS_FILE="$(cw_state_root)/providers-available.txt"
```

with:

```bash
PROVIDERS_FILE="$(cw_active_providers_path)"
```

Tweak the error message at line 61 from
`"providers-available.txt not found at $PROVIDERS_FILE"` to
`"$PROVIDERS_FILE not found"` so the message is always accurate
regardless of which file the resolver returned.

### `bin/medic.sh` (unchanged)

Still writes `providers-available.txt` at line 211–224. Selection is not
the bash script's responsibility.

### Files NOT touched

`lib/contracts.sh`, `lib/deps.sh`, `lib/log.sh`, `lib/consult.sh`,
`bin/spawn.sh`, `bin/consult-research-send.sh`. The selection is
invisible below `consult-init.sh` — once the roster is computed, the
rest of the pipeline doesn't care how it was filtered.

## Error handling

| Scenario | Behavior |
|---|---|
| `bin/medic.sh` exits FAIL but `providers-available.txt` has ≥1 entry | Proceed to selection flow regardless. Verdict failure may be unrelated (e.g. `$TMUX` not set warning, deploy-helper warn). User can still pick which detected providers they want — picking is never blocked by non-provider check failures. |
| `providers-available.txt` missing or unreadable after medic | Log `warn: providers-available.txt not found; skipping trooper selection`. Exit the directive's selection block. consult-init's existing missing-file error fires later if user runs /consult. |
| `providers-available.txt` is empty (0 providers) | medic already FAILs the verdict; selection skipped per Step C. |
| `providers-active.txt` corrupted (manually edited, contains junk) | Parser treats unparseable lines as comments. If the parsed `PRIOR` is empty, treat it as no-prior and prompt fresh. Never throws. |
| `providers-active.txt` contains a provider not in `providers-available.txt` (stale) | Step B filters it out and logs `note: removed <provider> from active set (no longer detected)`. Survives "user uninstalled binary" and "provider renamed in contracts.yaml". |
| User cancels / dismisses AskUserQuestion mid-walk | No file is written until the walk completes (single Write call at end). Prior `providers-active.txt` is untouched. Re-running medic re-prompts. |
| User picks Customize → excludes everything | Step F refuses to write empty file. Logs error, leaves prior state intact. Don't auto re-prompt. |
| Write tool fails (disk full, permissions) | Surfaces as a tool error in the conversation. consult-init falls back to `providers-available.txt`. Self-healing. |
| Concurrent `/clone-wars:medic` runs (two conductors) | Atomic Write tool semantics keep the file structurally valid; second writer wins. Acceptable — Clone Wars is single-conductor by design. |
| `providers-active.txt` exists but parses to empty after Step B filter | Treat as `PRIOR=∅` and proceed to prompt as if no prior. Don't auto-delete the stale file; the next successful write overwrites it. |

## Testing

New bash tests under `tests/`, all `tests/run.sh`-compatible:

- **`tests/test_active_providers_path.sh`** — unit test for
  `cw_active_providers_path`. Three scenarios: only
  `providers-available.txt` exists (returns that path), both files
  exist (returns active path), only `providers-active.txt` exists
  (returns active — defensive against medic having never run).
- **`tests/test_consult_init_prefers_active.sh`** — integration. Stage
  both files where active is a strict subset of available; verify
  consult-init's roster (via `troopers.txt` in topic dir) matches the
  active subset.
- **`tests/test_consult_init_falls_back_to_available.sh`** — verify
  today's behavior when only `providers-available.txt` is present
  (regression guard).
- **`tests/test_consult_init_handles_stale_active.sh`** —
  `providers-active.txt` references a provider whose binary is not
  in `cw_consult_eligible_providers`'s output; existing eligible-filter
  drops it; roster is the surviving subset; consult-init exits cleanly
  when the surviving subset is still ≥2.
- **`tests/test_medic_directive_v018_static_wiring.sh`** — static
  wiring asserts on `commands/medic.md`: Steps A–G present, references
  to `providers-active.txt` + Write tool + `AskUserQuestion`, fallback
  path documented for stale entries, no orphan `providers-available.txt`
  references in the selection block (everything reads via the resolver).

The AskUserQuestion option-rendering logic itself is directive prose —
not unit-testable in bash. Final UX validation comes from the v0.18.0
strict-dogfood pass.

## Success criteria

- After `/clone-wars:medic` runs, `providers-active.txt` exists with the
  user's chosen subset (or zero new bytes are written if user excluded
  all in Customize).
- A subsequent `/clone-wars:consult` run uses exactly the active subset
  as its trooper roster (verifiable via `_consult/troopers.txt` in the
  topic dir).
- Re-running `/clone-wars:medic` shows the prior selection as the
  recommended option in the AskUserQuestion menu.
- Uninstalling a provider's binary causes the next medic run to silently
  drop it from the prior set + log a `note:` line; the user is not
  forced to manually edit `providers-active.txt`.
- All existing tests pass (no regressions in consult/spawn/deploy
  pipelines).
- v0.0.1-pre1 medic users (no `providers-active.txt`) see no behavior
  change in `bin/consult-init.sh` — fallback covers them.

## Out of scope

- **Per-repo selection** — `providers-active.txt` is global. If users
  want different rosters per project, that's a v0.19+ feature with its
  own design (probably reading
  `state/<repo-hash>/providers-active.txt` first, falling through to
  global).
- **`--no-select` flag for non-interactive medic runs** — there's no CI
  use case for this plugin (Claude Code is interactive only). YAGNI.
- **`--reset` flag to clear `providers-active.txt`** — user can pick
  "All N detected" on the next run, or `rm` the file manually. YAGNI.
- **Editing `providers-active.txt` from outside medic** — file is
  user-readable and grep-able; manual edits will be picked up by
  consult-init on the next run, but medic will validate on the next
  invocation and may overwrite if user makes a non-empty new selection.

## Versioning

This is v0.18.0. Bump `.claude-plugin/{plugin,marketplace}.json` to
`0.18.0`. Add `CLAUDE.md` Status entry:

```
- [x] v0.18.0: medic trooper-select — interactive checklist after
      health table picks active provider subset; persists in
      providers-active.txt; consult-init prefers active over available
- [ ] v0.18.0 strict-dogfood pass on a real machine (release gate —
      verify: (1) all-providers detected → preset menu offers all
      subsets; (2) Customize walk per-provider; (3) selection persists
      across medic re-runs; (4) /consult uses active subset; (5) stale
      provider entry filtered with note: line; (6) empty-selection
      guard refuses write)
```
