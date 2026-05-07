# /clone-wars:consult — 3-Trooper Mode (v0.15.0)

**Status:** approved (brainstorming → writing-plans handoff)
**Author:** liupan + Master Yoda
**Date:** 2026-05-07
**Branch base:** main (post-v0.14.0 merge)

## Summary

Add **opencode (DeepSeek V4 Pro)** as a 3rd trooper in `/clone-wars:consult`,
giving every claim 2 independent verifiers instead of 1. Trooper count is
**dynamic**, driven by a remark file `providers-available.txt` written by
`/clone-wars:medic`. /consult reads the remark to learn which providers
are healthy and spawns N parallel troopers (cap N=3, codex/claude/opencode
only — gemini is not consult-eligible in this version). N=1 (only claude
available) plain-exits with a redirect; cross-verification needs ≥2
independent voices.

Commander mapping (locked): `codex → rex`, `claude → cody`, `opencode → bly`.

## Motivation

The 2-trooper /consult ships every claim with exactly 1 independent verifier
(the other trooper). Adding opencode bumps that to 2 verifiers per claim
(via topology A — full symmetric verify), which is the strongest cross-
verification we can get from a 4-provider closed set without invoking
adjudication-of-adjudications complexity. opencode (DeepSeek V4 Pro) was
added in v0.13.0 for `/clone-wars:deploy`; this proposal extends its reach
to /consult, the highest-value cross-verify command in the plugin.

Independent of the 3rd trooper, the **medic-driven trooper enumeration**
formalizes a dependency that was previously implicit: medic detects
providers, /consult uses them. The remark file makes the contract explicit
and lets /consult fail loud (with a clear "run medic first" message) when
the prerequisite hasn't run.

## Scope

### In
- `bin/medic.sh`: write `$state_root/providers-available.txt` after provider enumeration (atomic; all medic runs refresh it)
- `bin/consult-init.sh`: read the remark, derive N, set up trooper roster, refuse if remark missing or N < 2
- New helpers (`lib/consult.sh` or new `lib/consult-troopers.sh`): `cw_consult_eligible_providers`, `cw_consult_provider_to_commander`, `cw_consult_load_troopers`
- N-way refactor of `bin/consult-diff.sh` + `lib/consult.sh::cw_consult_diff`
- N-way refactor of `bin/consult-verify-send.sh` (each trooper verifies the union of items NOT in their findings)
- N-way refactor of `bin/consult-adjudicate.sh` + `lib/consult.sh::cw_consult_write_adjudicated`
- 3-source attribution refactor in `bin/consult-synthesize.sh`
- Drilldown option-list expansion in `commands/consult.md` Step 8.4 (3 troopers + 3 pairs + all-three)
- `commands/consult.md`: spawn N troopers (loop, not hardcoded pair); update task list; update spawn-rollback runbook for N
- 3-trooper happy-path test + N=1 refuse test + N=2 pairing tests + N=3 dogfood test

### Out
- Gemini consult support (gemini stays out of consult; medic still detects it but consult-init filters it out)
- Opencode for /spec (spec is conductor-only; not affected)
- Any change to `/clone-wars:deploy` (deploy uses single-trooper turn pattern; unchanged)
- More than 3 troopers (cap N=3 even if a 5th provider is added later)
- Different verify topologies (B pair+tiebreaker, C round-robin) — locked on A per brainstorm

## Architecture

### Provider enumeration contract

**Medic side** (`bin/medic.sh`):
After the provider enumeration loop (Section "5. providers in contracts.yaml"),
write `$state_root/providers-available.txt`:

```
# generated <ISO-8601 UTC> by /clone-wars:medic
# providers detected with binary on PATH + contracts.yaml row
codex
claude
opencode
```

Atomic write via `cw_atomic_write`. Only providers with `providers_ok=1`
(binary present + contracts.yaml row + (for opencode) auto-approve check
unblocked) are listed. Missing-binary providers are NOT in the file.

**Consult-init side** (`bin/consult-init.sh`):

```bash
PROVIDERS_FILE="$state_root/providers-available.txt"
if [[ ! -f "$PROVIDERS_FILE" ]]; then
  log_error "providers-available.txt not found. Run /clone-wars:medic first."
  exit 2
fi

# Filter to consult-eligible providers (codex/claude/opencode).
mapfile -t CONSULT_PROVIDERS < <(
  grep -v '^#' "$PROVIDERS_FILE" \
    | grep -E '^(codex|claude|opencode)$'
)
N=${#CONSULT_PROVIDERS[@]}

case "$N" in
  0|1) log_error "/consult requires ≥2 consult-eligible providers; got $N. Just ask claude directly."; exit 1 ;;
  2|3) ;;
  *)   log_error "/consult cap is 3 troopers; got $N (filter dropped non-eligible)"; exit 1 ;;
esac
```

(N=0 case is theoretically impossible — claude is always present in a
Claude Code session — but the case arm is included as a defense.)

After validation, write the trooper roster to `_consult/troopers.txt` so
downstream scripts read who's who:

```
# generated 2026-05-07T16:42:00Z by bin/consult-init.sh
codex	rex
claude	cody
opencode	bly
```

(One line per trooper, tab-separated provider+commander.)

### Trooper roster + commander mapping

```bash
cw_consult_provider_to_commander() {
  case "$1" in
    codex)    echo rex ;;
    claude)   echo cody ;;
    opencode) echo bly ;;
    *)        echo "no-commander-for-$1" >&2; return 1 ;;
  esac
}
```

Mapping is **hardcoded** in `lib/consult.sh` (or a new `lib/consult-troopers.sh`).
Not user-configurable for v0.15.0 — the symmetry rex/cody/bly is intentional
and the mapping is part of the audit gate ("if you see `bly`, opencode ran;
if you see `rex`, codex ran").

### N=1/2/3 behavior table

| N (consult-eligible providers) | Behavior |
|---|---|
| **0** | (impossible) hard error |
| **1** | Plain-exit with redirect message; `log_warn "/consult requires ≥2 providers ... just ask claude directly."` |
| **2** | Spawn 2 troopers (whichever pairing of {rex, cody, bly} matches available providers). Current 2-way verify topology preserved. |
| **3** | Spawn 3 troopers (rex + cody + bly). New 3-way symmetric verify topology A. |

### Topology A — full symmetric verify (3 troopers)

After research, each trooper produces `findings.md` with claims. Diff
computes the **3-way Venn**:

- **All-3 set** = `rex_findings ∩ cody_findings ∩ bly_findings` → no verify needed (auto-CONSENSUS)
- **rex_only**  = `rex_findings \ (cody_findings ∪ bly_findings)`
- **cody_only** = `cody_findings \ (rex_findings ∪ bly_findings)`
- **bly_only**  = `bly_findings \ (rex_findings ∪ cody_findings)`
- **rex+cody only** = `(rex_findings ∩ cody_findings) \ bly_findings`
- **rex+bly only** = `(rex_findings ∩ bly_findings) \ cody_findings`
- **cody+bly only** = `(cody_findings ∩ bly_findings) \ rex_findings`

Verify routing:

| Claim category | Verifier(s) | Verifier count |
|---|---|---|
| All-3 set | (none — auto-CONSENSUS) | 0 |
| rex+cody (no bly) | bly | 1 |
| rex+bly (no cody) | cody | 1 |
| cody+bly (no rex) | rex | 1 |
| rex_only | cody, bly | 2 |
| cody_only | rex, bly | 2 |
| bly_only | rex, cody | 2 |

Each trooper's verify inbox = the union of all categories where they're a
verifier. Concretely: trooper T verifies all claims that are NOT in T's
own findings.

(For N=2, the verify topology degenerates back to current behavior:
each trooper verifies the other's only-items.)

### Adjudicate — 5-tier output

Adjudicate takes the per-claim verdicts and writes `adjudicated.md` with
5 sections:

```markdown
## Consensus findings (all troopers)
- ...

## Cross-verified
- [rex+cody+bly] foo bar baz   ← all-3 cases that fell here via verify
- [rex+cody, verified by bly] ...
- [rex_only, verified by cody+bly] ...

## Contested
- [bly DISPUTES rex+cody claim] ...
- [cody AGREES, bly DISPUTES rex_only claim] ...

## Refuted
- [rex_only, both cody+bly DISPUTE] ...

## - PENDING:
- [unresolved UNCERTAIN verdicts; Master Yoda resolves manually]
```

**Decision rules:**

- A claim is **CONSENSUS** if it's in the All-3 set (no verify needed).
- A claim is **CROSS-VERIFIED** if all required verifiers AGREE.
- A claim is **CONTESTED** if any verifier DISPUTES (1+ AGREE, 1+ DISPUTE)
  OR all verifiers UNCERTAIN.
- A claim is **REFUTED** if all required verifiers DISPUTE.
- A claim is **PENDING** if any required verifier emitted UNCERTAIN with
  evidence ambiguous enough to need human read.

Backward compat: for N=2 runs, only "Cross-verified", "Contested",
"Refuted", "- PENDING:" sections appear (no "Consensus findings" since
all-2-set is symmetric with cross-verified). Adjudicate handles N=2 and
N=3 with the same code path; the section header is gated on the
all-N-set being non-empty.

### Synthesize — 3-source attribution

Each finding in the synthesis is tagged with its source set: `[rex]`,
`[cody]`, `[bly]`, `[rex+cody]`, `[rex+bly]`, `[cody+bly]`, or
`[rex+cody+bly]`. The synthesize script reads adjudicated.md and copies
the source tags forward; no new logic beyond following the existing
attribution pattern (which already exists for 2-trooper).

### Drilldown — option list expansion

`commands/consult.md` Step 8.4's AskUserQuestion option list grows from
3 (rex/cody/both) to 7 in N=3 mode:

- `rex (codex)` / `cody (claude)` / `bly (opencode)` (3 single)
- `rex + cody` / `rex + bly` / `cody + bly` (3 pairs)
- `all three (parallel)` (1 fan-out)

For N=2 mode, the option list is the current 3 (the 2 singles + both).
The directive selects the option list dynamically based on N.

### Spawn-rollback runbook (N-trooper)

Initialize before parallel spawn:
```bash
SPAWN_RETRY_COUNT=0
```

Invoke spawn for each provider in `_consult/troopers.txt` as parallel
Bash tool calls. After all spawns return, evaluate the rc tuple:

- **All N succeed** → continue.
- **At least one fails AND `SPAWN_RETRY_COUNT == 0`** → tear down any
  surviving panes (keep `_consult/`), `SPAWN_RETRY_COUNT=1`, retry the
  parallel spawn block. Same auto-retry semantics as v0.11.2 (codex
  cold-start mitigation).
- **At least one fails AND `SPAWN_RETRY_COUNT == 1`** → teardown +
  `rm -rf _consult/`, exit 1. Tell the user which provider(s) failed
  twice.

The runbook scales to N because the parallel-Bash-tool-call pattern is
already N-aware (the directive issues N tool calls in one message).

## File-level diff plan

### Modify
| File | Change |
|---|---|
| `bin/medic.sh` | After provider enumeration, write `providers-available.txt` (atomic) |
| `bin/consult-init.sh` | Read providers-available.txt; derive N; refuse N<2; write `_consult/troopers.txt` |
| `bin/consult-diff.sh` | N-way Venn (currently 2-way) |
| `bin/consult-verify-send.sh` | Each trooper verifies items NOT in their own findings (currently: items in the OTHER trooper's only set) |
| `bin/consult-verify-wait.sh` | (no change — works per-trooper) |
| `bin/consult-adjudicate.sh` | 5-tier output with consensus + N-way verdict aggregation |
| `bin/consult-synthesize.sh` | 3-source attribution tags |
| `bin/consult-teardown.sh` | Iterate troopers.txt instead of hardcoded pair |
| `commands/consult.md` | Spawn N troopers (loop); update Step 0 to read troopers.txt; update Step 1 spawn-rollback for N; update Step 8.4 drill option list |
| `lib/consult.sh` (or new `lib/consult-troopers.sh`) | `cw_consult_provider_to_commander`, `cw_consult_load_troopers`, `cw_consult_eligible_providers` |
| `lib/consult.sh::cw_consult_diff` | N-way set algebra |
| `lib/consult.sh::cw_consult_write_adjudicated` | 5-tier formatter |
| `tests/test_medic_*.sh` | Add coverage for providers-available.txt write |
| `tests/test_consult_init.sh` | Coverage for remark-missing → exit 2; N detection; N=1 refuse |

### Create
| File | Contents |
|---|---|
| `tests/test_consult_init_providers_remark.sh` | Test medic remark + consult-init read interaction |
| `tests/test_consult_3trooper_diff.sh` | 3-way Venn diff fixtures |
| `tests/test_consult_3trooper_adjudicate.sh` | 5-tier output fixtures |
| `tests/test_consult_3trooper_dogfood.sh` | Skipped-by-default end-to-end test (run by hand for release gate) |
| `docs/superpowers/specs/2026-05-07-consult-3-trooper-design.md` | This spec |
| `docs/superpowers/plans/2026-05-07-consult-3-trooper-plan.md` | Implementation plan (next step) |

### Untouched
- `bin/spawn.sh`, `bin/teardown.sh`, `bin/send.sh`, `bin/list.sh` — provider-agnostic, no change
- `lib/{ipc,tmux,state,deps,argsfile,log,colors,opencode_preflight,...}.sh`
- `lib/spec.sh`, `bin/spec-init.sh`, `bin/spec-assemble.sh` — /spec is conductor-only, no troopers
- `commands/spec.md`, `commands/medic.md`, `commands/list.md`, `commands/teardown.md`, `commands/deploy.md`
- `bin/deploy-*.sh` and the v0.13.0 `--provider opencode` flag — unchanged

## Test plan

1. **Pre-implementation baseline.** `bash tests/run.sh` on current `main` (post-v0.14.0).
2. **Per-task green.** After each task in the plan, re-run `tests/run.sh`. Fail-fast on regressions.
3. **Unit: medic remark write.** Stage temp state-root, run `bash bin/medic.sh`, assert `providers-available.txt` exists and has at least the `claude` line. Negative: when contracts.yaml is missing, the remark file should still be written (with whatever providers are available — possibly empty).
4. **Unit: consult-init remark read.**
   - **Missing remark** → exit 2 with "run /clone-wars:medic first" message.
   - **N=1 (only claude)** → exit 1 with redirect message.
   - **N=2 (claude + codex)** → write troopers.txt with rex+cody.
   - **N=2 (claude + opencode)** → write troopers.txt with cody+bly.
   - **N=3** → write troopers.txt with rex+cody+bly.
   - **N=4 (filter drops gemini)** → write troopers.txt with rex+cody+bly (gemini ignored).
5. **Unit: 3-way diff.** Fixtures with all 7 Venn cells; assert `cw_consult_diff` produces the expected `*_only_items.txt` files + a new `consensus.txt` (all-3 set) + 3 pair-overlap files.
6. **Unit: 3-way adjudicate.** Fixtures covering every (claim category × verdict combo); assert `adjudicated-draft.md` has the right 5 sections in the right order.
7. **End-to-end dogfood (release gate; manual).**
   - Topic: any 1-line research question.
   - Pre: `/clone-wars:medic` → providers-available.txt shows codex+claude+opencode.
   - Run `/clone-wars:consult <topic>` → expect 3 panes spawned (rex-codex + cody-claude + bly-opencode).
   - Confirm `_consult/troopers.txt` lists 3 entries.
   - Confirm `findings-rex.md`, `findings-cody.md`, `findings-bly.md` all written.
   - Confirm `diff.md` shows 3-way Venn with at least one cell populated.
   - Confirm `adjudicated.md` has Consensus + Cross-verified sections.
   - Confirm `synthesis.md` has 3-source attribution tags.
   - Drill once with "all three (parallel)" option; confirm 3 drilldown files written.
   - Teardown + archive.

## Risks + rollback

**Risk: medic remark stale.** User installs new provider but doesn't re-run medic; consult uses stale provider list. Mitigation: medic remark includes ISO timestamp; if /consult sees a remark older than 24h it could log_warn — though the v0.15 plan defers this to a follow-up to keep scope small.

**Risk: opencode trooper dispatch races.** Opencode auto-approve config (`opencode.json` with `permission: allow`) is required for unattended trooper operation. Medic preflight already checks this in v0.13.0; consult-init does NOT re-check. If user removed `permission: allow` between medic and consult, the bly trooper will hang waiting for permission prompts. Mitigation: out-of-scope for v0.15; relies on user discipline (medic preflight is the audit gate).

**Risk: 3-way adjudicate complexity.** The 5-tier output has more conditionals than the 2-way 4-tier. Mitigation: thorough unit tests on every (claim category × verdict combo); plan task is "TDD: write the fixture-driven test first, then implement".

**Risk: cost.** 3 troopers ≈ 1.5x parallel research time (longest tail wins) + 1.5x token cost. Mitigation: medic-driven N detection means users without opencode automatically run 2-trooper mode; explicit cost is paid only when opencode is installed AND working.

**Rollback:** single PR; git revert if regressions surface post-merge. v0.14.0 is the last 2-trooper-only version and stays installable from marketplace history.

## Versioning

Bump plugin to **v0.15.0** (additive feature; no breaking change).
CLAUDE.md status block gets:
- `[x] v0.15.0: 3-trooper /consult — opencode (DeepSeek V4 Pro) joins as bly; topology A symmetric verify (every claim 2 independent verifiers); medic-driven trooper enumeration via providers-available.txt; N=1 plain-exits with redirect; N=2 unchanged; N=3 new mode.`
- `[ ] v0.15.0 strict-dogfood pass on a real machine (release gate — verify rex+cody+bly all spawn, 3-way diff/adjudicate/synthesis, drill across 7 options).`

## Out of scope (re-stated)

- Gemini /consult integration (gemini stays out)
- Adjudicate timestamp / staleness checks on medic remark
- More than 3 troopers
- Different verify topologies (B / C from brainstorm)
- /spec changes (spec is conductor-only, unaffected)
- Migrating /deploy to multi-trooper (deploy uses single-turn pattern; out of scope)

## Acceptance

- All tests in `tests/run.sh` pass with new test files added
- A clean N=3 dogfood run produces the 5-tier `adjudicated.md`, 3-source synthesis, and 3 drilldown files (when "all three" is chosen)
- Medic remark file is created on every medic run and consumed by consult-init
- No regression on N=2 happy path (key 2-trooper tests still green)
- `bin/medic.sh` exits OK on a clean repo
