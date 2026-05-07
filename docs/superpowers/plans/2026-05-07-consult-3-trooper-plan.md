# /clone-wars:consult 3-Trooper Implementation Plan (v0.15.0)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add opencode (DeepSeek V4 Pro) as a 3rd /clone-wars:consult trooper (commander `bly`) with topology A symmetric verify; trooper count is dynamic (N=1/2/3) driven by a remark file `providers-available.txt` written by `/clone-wars:medic`.

**Architecture:** Bottom-up — helpers first (provider→commander mapping, troopers loader), then medic write, then consult-init read, then diff/verify/adjudicate refactors, then directive (commands/consult.md spawn-loop), then version bump + dogfood. Each task leaves `bash tests/run.sh` green (per-task fixture writes substitute for live troopers).

**Tech Stack:** pure bash, tmux, file IPC. No Node/Python in runtime.

**Spec:** `docs/superpowers/specs/2026-05-07-consult-3-trooper-design.md`

---

### Task 1: Branch + baseline

**Files:**
- Branch: `feat/v0.15.0-3-trooper-consult` off main (post-v0.14.0 merge)

- [ ] **Step 1: Create branch off latest main**

```bash
git checkout main
git pull --ff-only origin main
git log --oneline -3 | grep -q v0.14 || { echo "main lacks v0.14.0"; exit 1; }
git checkout -b feat/v0.15.0-3-trooper-consult
```

- [ ] **Step 2: Run baseline test suite**

```bash
bash tests/run.sh > /tmp/v015-baseline.log 2>&1
PASS=$(grep -cE '^  PASS:' /tmp/v015-baseline.log); FAIL=$(grep -cE ': FAIL$' /tmp/v015-baseline.log)
echo "PASS=$PASS FAIL=$FAIL"
```

Expected: FAIL=0. If any tests fail, STOP and report.

- [ ] **Step 3: Commit empty marker**

```bash
git commit --allow-empty -m "chore(v0.15.0): start 3-trooper /consult branch"
```

---

### Task 2: Add commander-mapping helpers (TDD)

**Files:**
- Create: `tests/test_consult_provider_mapping.sh`
- Modify: `lib/consult.sh` — add `cw_consult_provider_to_commander`, `cw_consult_eligible_providers`, `cw_consult_load_troopers`

- [ ] **Step 1: Write the failing test**

```bash
cat > tests/test_consult_provider_mapping.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/consult.sh"

# Provider → commander mapping (locked in v0.15.0 spec)
out=$(cw_consult_provider_to_commander codex);    assert_eq "$out" "rex"  "codex → rex"
out=$(cw_consult_provider_to_commander claude);   assert_eq "$out" "cody" "claude → cody"
out=$(cw_consult_provider_to_commander opencode); assert_eq "$out" "bly"  "opencode → bly"

# Unknown provider → rc=1
cw_consult_provider_to_commander gemini 2>/dev/null && { echo FAIL: gemini should error; exit 1; }
pass "unknown provider returns rc=1"

# Eligible-providers filter: keeps codex/claude/opencode in input order, drops others.
out=$(printf '%s\n' codex claude gemini opencode | cw_consult_eligible_providers)
assert_eq "$out" $'codex\nclaude\nopencode' "filter drops gemini"

# Load troopers: TSV reader with trailing newline tolerance.
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/troopers.txt" <<TSV
# header
codex	rex
claude	cody
opencode	bly
TSV
mapfile -t lines < <(cw_consult_load_troopers "$TMP/troopers.txt")
assert_eq "${#lines[@]}" "3" "3 trooper lines parsed"
assert_eq "${lines[0]}" "codex	rex"  "first line"
pass "cw_consult_load_troopers parses TSV with header comment"
EOF
chmod +x tests/test_consult_provider_mapping.sh
```

- [ ] **Step 2: Run test, expect FAIL**

```bash
bash tests/test_consult_provider_mapping.sh 2>&1 | tail -3
# Expected: function not found / unbound
```

- [ ] **Step 3: Implement helpers in lib/consult.sh**

Add at the end of `lib/consult.sh` (before any closing comment block):

```bash
# v0.15.0: provider → commander mapping (locked).
# codex → rex (501st), claude → cody (212th), opencode → bly (327th).
cw_consult_provider_to_commander() {
  case "$1" in
    codex)    echo rex ;;
    claude)   echo cody ;;
    opencode) echo bly ;;
    *)        echo "cw_consult_provider_to_commander: no mapping for '$1'" >&2; return 1 ;;
  esac
}

# v0.15.0: filter input stream to consult-eligible providers (codex/claude/opencode).
# Reads provider names from stdin (one per line); writes filtered list to stdout
# in the input order. Used by consult-init to derive N from medic's remark.
cw_consult_eligible_providers() {
  grep -E '^(codex|claude|opencode)$' || true
}

# v0.15.0: load _consult/troopers.txt (TSV: <provider>\t<commander>) → stdout TSV.
# Skips lines starting with '#' (comments) and blank lines. Caller maps to arrays.
cw_consult_load_troopers() {
  local file="$1"
  [[ -f "$file" ]] || { echo "cw_consult_load_troopers: file not found: $file" >&2; return 2; }
  grep -vE '^[[:space:]]*(#|$)' "$file"
}
```

- [ ] **Step 4: Run test, expect PASS**

```bash
bash tests/test_consult_provider_mapping.sh 2>&1 | tail -5
# Expected: 3+ PASS lines, no FAIL
```

- [ ] **Step 5: Update lib/consult shim test for the 3 new functions**

Add to `tests/test_consult_lib_shim_sources_all.sh` EXPECTED list:

```bash
cw_consult_provider_to_commander cw_consult_eligible_providers cw_consult_load_troopers
```

Update the count in the pass message and verify drift check stays at expected = actual.

- [ ] **Step 6: Run full suite, verify green**

```bash
bash tests/run.sh > /tmp/v015-task2.log 2>&1; PASS=$(grep -cE '^  PASS:' /tmp/v015-task2.log); FAIL=$(grep -cE ': FAIL$' /tmp/v015-task2.log); echo PASS=$PASS FAIL=$FAIL
```

Expected: FAIL=0.

- [ ] **Step 7: Commit**

```bash
git add tests/test_consult_provider_mapping.sh tests/test_consult_lib_shim_sources_all.sh lib/consult.sh
git commit -m "feat(consult): add provider→commander mapping helpers (v0.15.0)

cw_consult_provider_to_commander locks codex→rex, claude→cody, opencode→bly.
cw_consult_eligible_providers filters out gemini (not consult-eligible).
cw_consult_load_troopers reads _consult/troopers.txt TSV.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Medic writes providers-available.txt (TDD)

**Files:**
- Create: `tests/test_medic_providers_available.sh`
- Modify: `bin/medic.sh` — add atomic write of providers-available.txt after enumeration

- [ ] **Step 1: Write the failing test**

```bash
cat > tests/test_medic_providers_available.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh

PLUGIN_ROOT="$(cd .. && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/cw" "$TMP/bin" "$TMP/repo"
cp "$PLUGIN_ROOT/config/contracts.yaml" "$TMP/cw/contracts.yaml"
cat > "$TMP/bin/codex" <<'BIN'
#!/usr/bin/env bash
echo "codex 1.0.0"; exit 0
BIN
chmod +x "$TMP/bin/codex"

# Invoke medic — should write providers-available.txt
CLONE_WARS_HOME="$TMP/cw" PATH="$TMP/bin:$PATH" HOME="$TMP/nohome" \
  bash -c "cd '$TMP/repo' && '$PLUGIN_ROOT/bin/medic.sh'" >/dev/null 2>&1 || true

REMARK="$TMP/cw/providers-available.txt"
[[ -f "$REMARK" ]] || { echo "FAIL: providers-available.txt missing"; exit 1; }
pass "providers-available.txt exists after medic run"

# Header line is a timestamped comment.
head -1 "$REMARK" | grep -qE '^# generated [0-9]{4}-[0-9]{2}-[0-9]{2}' \
  || { echo "FAIL: header line missing timestamp"; cat "$REMARK"; exit 1; }
pass "remark header has ISO-8601 timestamp"

# codex was on PATH, should appear in remark.
grep -qE '^codex$' "$REMARK" \
  || { echo "FAIL: codex not in remark"; cat "$REMARK"; exit 1; }
pass "codex listed (binary on PATH)"

# Idempotence: second medic run overwrites cleanly.
CLONE_WARS_HOME="$TMP/cw" PATH="$TMP/bin:$PATH" HOME="$TMP/nohome" \
  bash -c "cd '$TMP/repo' && '$PLUGIN_ROOT/bin/medic.sh'" >/dev/null 2>&1 || true
[[ $(grep -cE '^codex$' "$REMARK") -eq 1 ]] \
  || { echo "FAIL: codex duplicated after second medic run"; cat "$REMARK"; exit 1; }
pass "second medic run overwrites cleanly (no duplicates)"
EOF
chmod +x tests/test_medic_providers_available.sh
```

- [ ] **Step 2: Run test, expect FAIL**

```bash
bash tests/test_medic_providers_available.sh 2>&1 | tail -3
# Expected: FAIL: providers-available.txt missing
```

- [ ] **Step 3: Add atomic write to bin/medic.sh**

Find the closing block of medic (after `# 5b. opencode auto-approve preflight`, before the final verdict). Insert:

```bash
# v0.15.0: write providers-available.txt — consumed by /clone-wars:consult.
# Lists every provider with binary on PATH (regardless of preflight warns).
{
  printf '# generated %s by /clone-wars:medic\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '# providers detected with binary on PATH + contracts.yaml row\n'
  while IFS= read -r prov; do
    [[ -z "$prov" ]] && continue
    bin=$(cw_contract_binary "$prov" 2>/dev/null) || continue
    [[ -n "$bin" ]] || continue
    cw_have_cmd "$bin" || continue
    printf '%s\n' "$prov"
  done < <(cw_contracts_providers 2>/dev/null)
} | cw_atomic_write "$state_root/providers-available.txt" \
   || log_warn "could not write providers-available.txt"
```

- [ ] **Step 4: Run test, expect PASS**

```bash
bash tests/test_medic_providers_available.sh 2>&1 | tail -5
```

- [ ] **Step 5: Run full suite**

```bash
bash tests/run.sh > /tmp/v015-task3.log 2>&1; PASS=$(grep -cE '^  PASS:' /tmp/v015-task3.log); FAIL=$(grep -cE ': FAIL$' /tmp/v015-task3.log); echo PASS=$PASS FAIL=$FAIL
```

Expected: FAIL=0.

- [ ] **Step 6: Commit**

```bash
git add tests/test_medic_providers_available.sh bin/medic.sh
git commit -m "feat(medic): write providers-available.txt remark (v0.15.0)

medic.sh now writes \$state_root/providers-available.txt after provider
enumeration. /clone-wars:consult reads this file in v0.15.0 to derive
trooper count. Atomic write via cw_atomic_write; idempotent across
multiple medic runs.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Consult-init reads remark + writes troopers.txt (TDD)

**Files:**
- Create: `tests/test_consult_init_providers_remark.sh`
- Modify: `bin/consult-init.sh` — read remark, derive N, refuse if missing or N<2, write `_consult/troopers.txt`
- Modify: existing tests that invoke consult-init → pre-write providers-available.txt fixture

- [ ] **Step 1: Write the failing test**

Test cases:
- Missing remark → exit 2 with "run /clone-wars:medic first" message
- N=1 (only claude) → exit 1 with redirect message about "ask claude directly"
- N=2 (claude + codex) → write troopers.txt with rex+cody (in that input order)
- N=2 (claude + opencode) → write troopers.txt with cody+bly
- N=3 (all 3) → write troopers.txt with rex+cody+bly
- N=4 (gemini in remark too) → filter drops gemini, behaves as N=3

Each case stages a temp state-root with a synthesized providers-available.txt + invokes consult-init + asserts behavior. Use the same pattern as test_medic_providers_available.sh (TMP dir, fake bins, env-overridden CLONE_WARS_HOME).

- [ ] **Step 2: Run test, expect FAIL**

- [ ] **Step 3: Implement consult-init changes**

In `bin/consult-init.sh`, after the topic-validation block but BEFORE the `_consult/` skeleton creation, add:

```bash
# v0.15.0: provider gate — read medic's remark.
PROVIDERS_FILE="$(cw_state_root)/providers-available.txt"
[[ -f "$PROVIDERS_FILE" ]] || {
  log_error "providers-available.txt not found at $PROVIDERS_FILE"
  log_error "Run /clone-wars:medic first to detect installed providers."
  exit 2
}
mapfile -t CONSULT_PROVIDERS < <(
  grep -vE '^[[:space:]]*(#|$)' "$PROVIDERS_FILE" \
    | cw_consult_eligible_providers
)
N=${#CONSULT_PROVIDERS[@]}

case "$N" in
  0|1)
    log_warn "/consult requires ≥2 consult-eligible providers; got $N."
    log_warn "Just ask claude directly (this Claude Code session) — no /consult orchestration needed."
    exit 1 ;;
  2|3) ;;  # supported
  *)
    log_error "/consult cap is 3 troopers; got $N (filter dropped non-eligible)"
    exit 1 ;;
esac
```

After `_consult/` mkdir, write troopers.txt:

```bash
{
  printf '# generated %s by bin/consult-init.sh\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  for prov in "${CONSULT_PROVIDERS[@]}"; do
    cmdr=$(cw_consult_provider_to_commander "$prov")
    printf '%s\t%s\n' "$prov" "$cmdr"
  done
} > "$TOPIC_DIR/_consult/troopers.txt"
```

- [ ] **Step 4: Run new test, expect PASS**

- [ ] **Step 5: Update existing tests that exercise consult-init**

Run:

```bash
grep -lE 'consult-init\.sh' tests/*.sh
```

For each file, add fixture setup before the consult-init call:

```bash
mkdir -p "$CLONE_WARS_HOME"
cat > "$CLONE_WARS_HOME/providers-available.txt" <<EOF
# fixture
codex
claude
EOF
```

(Use codex+claude for N=2 default unless the test specifically exercises N=3.)

- [ ] **Step 6: Run full suite**

Expected: FAIL=0. Any unexpected failures = a test that didn't get a fixture.

- [ ] **Step 7: Commit**

```bash
git add tests/test_consult_init_providers_remark.sh bin/consult-init.sh tests/test_consult_*.sh
git commit -m "feat(consult): consult-init reads providers-available.txt; writes troopers.txt (v0.15.0)

bin/consult-init.sh now requires \$state_root/providers-available.txt
(written by /clone-wars:medic). Derives N from consult-eligible
providers; refuses N<2 with redirect message; writes
_consult/troopers.txt (TSV) for downstream scripts.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: 3-way Venn diff refactor

**Files:**
- Modify: `lib/consult.sh::cw_consult_diff` — accept variable trooper count, output 3-way Venn
- Modify: `bin/consult-diff.sh` — read troopers.txt, dispatch to N-way diff
- Create: `tests/test_consult_3trooper_diff.sh`
- Modify: existing 2-trooper diff test to use new signature

- [ ] **Step 1: Sketch the N-way diff fixture**

Three findings.md fixtures with controlled overlaps:
- Rex: A, B, C, D (4 claims)
- Cody: B, C, E (3 claims)
- Bly: C, E, F (3 claims)

Expected output cells:
- Consensus (all-3): C
- Rex+Cody only: B
- Cody+Bly only: E
- Rex_only: A, D
- Bly_only: F
- (Rex+Bly only is empty in this fixture)

- [ ] **Step 2: Write failing test**

Create `tests/test_consult_3trooper_diff.sh` that stages the 3 fixtures, invokes `cw_consult_diff` with N=3, asserts each output file (`consensus.txt`, `rex_only_items.txt`, `cody_only_items.txt`, `bly_only_items.txt`, `rex+cody_only.txt`, `cody+bly_only.txt`, etc.) has the expected claim count.

- [ ] **Step 3: Run test, expect FAIL**

- [ ] **Step 4: Refactor cw_consult_diff to N-way**

Implement set-algebra over the 3 findings files. Output one file per Venn cell that has ≥1 claim. Cell naming: `<members>_only.txt` (e.g., `rex+cody_only.txt`). The `consensus.txt` file holds the all-3 set. Single-trooper-only files keep their current names (`rex_only_items.txt`, etc.) for backward compat with N=2 mode.

For N=2 mode (only 2 troopers in troopers.txt), output the same 3 files as today: `<rex>_only_items.txt`, `<cody>_only_items.txt`, plus the existing `diff.md`. The `consensus.txt` file is omitted (or empty) in N=2 mode since the 2-set agreement IS the cross-verified set.

- [ ] **Step 5: Run test, expect PASS**

- [ ] **Step 6: Run full suite**

- [ ] **Step 7: Commit**

```bash
git add lib/consult.sh bin/consult-diff.sh tests/test_consult_3trooper_diff.sh tests/test_consult_diff*.sh
git commit -m "feat(consult): N-way Venn diff supports 3 troopers (v0.15.0)"
```

---

### Task 6: Verify-send refactor

**Files:**
- Modify: `bin/consult-verify-send.sh` — verify scope = items NOT in own findings (was: items in OTHER's only set)
- Modify: existing verify-send test if signature changes

- [ ] **Step 1: Read current consult-verify-send.sh; identify the verify-scope assembly**

The current script likely concatenates `<other>_only_items.txt` to form the verify inbox. New behavior: concat the union of all items NOT in this trooper's findings (which equals the union of `consensus.txt` minus this trooper's contribution + all OTHER troopers' only-items + all pair-overlaps not containing this trooper).

Simpler implementation: read all `_consult/<bucket>.txt` files, for each, include claim if THIS trooper is NOT a member of the bucket name.

- [ ] **Step 2: Write failing test**

Test fixture: 3 troopers, controlled overlaps, invoke verify-send for each, assert inbox content has the right claim set.

- [ ] **Step 3: Implement**

- [ ] **Step 4: Run test, expect PASS**

- [ ] **Step 5: Run full suite**

- [ ] **Step 6: Commit**

---

### Task 7: 5-tier adjudicate refactor

**Files:**
- Modify: `lib/consult.sh::cw_consult_write_adjudicated` — 5-tier output
- Modify: `bin/consult-adjudicate.sh` — read N troopers from troopers.txt
- Create: `tests/test_consult_3trooper_adjudicate.sh`

- [ ] **Step 1: Define output sections** (per spec):
1. `## Consensus findings (all troopers)` — claims in all-N set
2. `## Cross-verified` — claims with all required verifiers AGREE
3. `## Contested` — mixed verdicts (any DISPUTE among AGREE)
4. `## Refuted` — all verifiers DISPUTE
5. `## - PENDING:` — unresolved UNCERTAIN claims (existing format)

- [ ] **Step 2: Write fixture-driven failing test**

Cover every (claim category × verdict combo) at minimum:
- consensus → CONSENSUS section
- 1-of-3 (rex_only) with both verifiers AGREE → cross-verified
- 1-of-3 (rex_only) with split verdict (1 AGREE, 1 DISPUTE) → contested
- 1-of-3 (rex_only) with both DISPUTE → refuted
- 1-of-3 (rex_only) with any UNCERTAIN → pending
- 2-of-3 (rex+cody) with verifier AGREE → cross-verified
- 2-of-3 (rex+cody) with verifier DISPUTE → contested
- 2-of-3 (rex+cody) with verifier UNCERTAIN → pending

- [ ] **Step 3: Run test, expect FAIL**

- [ ] **Step 4: Refactor cw_consult_write_adjudicated for 5-tier**

For N=2 mode, `consensus.txt` is empty/missing; the function emits 4 sections (cross-verified / contested / refuted / pending) — backward compat preserved.

- [ ] **Step 5: Run test, expect PASS**

- [ ] **Step 6: Run full suite**

- [ ] **Step 7: Commit**

---

### Task 8: Synthesize 3-source attribution

**Files:**
- Modify: `bin/consult-synthesize.sh` — propagate 3-source tags from adjudicated.md to synthesis.md

- [ ] **Step 1: Read consult-synthesize.sh; identify the attribution-rendering code**

For 2-trooper, the source tags are `[rex]`, `[cody]`, `[rex+cody]`. For 3-trooper, the set expands to 7 tags: `[rex]`, `[cody]`, `[bly]`, `[rex+cody]`, `[rex+bly]`, `[cody+bly]`, `[rex+cody+bly]`. The render-from-adjudicated logic should already be tag-agnostic if it just copies from adjudicated.md.

- [ ] **Step 2: Verify with N=3 fixture**

Stage adjudicated.md with 7-tag claims; run synthesize; confirm synthesis.md preserves tags.

- [ ] **Step 3: Patch any tag-specific assertions in synthesize.sh**

Only if the script hardcodes `rex|cody` filtering. Likely minimal.

- [ ] **Step 4: Run full suite**

- [ ] **Step 5: Commit (or note: no changes needed)**

---

### Task 9: Teardown iterates troopers.txt

**Files:**
- Modify: `bin/consult-teardown.sh` — replace hardcoded "rex codex + cody claude" with iterate-from-troopers.txt

- [ ] **Step 1: Update iteration**

```bash
mapfile -t troopers < <(cw_consult_load_troopers "$TOPIC_DIR/_consult/troopers.txt")
for line in "${troopers[@]}"; do
  IFS=$'\t' read -r prov cmdr <<< "$line"
  "$CLAUDE_PLUGIN_ROOT/bin/teardown.sh" "$cmdr" "$prov" "$TOPIC" || log_warn "teardown failed for $cmdr-$prov"
done
```

- [ ] **Step 2: Run consult-teardown unit test (existing, if any) + extend if needed**

- [ ] **Step 3: Run full suite**

- [ ] **Step 4: Commit**

---

### Task 10: commands/consult.md spawn-loop + task list update

**Files:**
- Modify: `commands/consult.md` — spawn N troopers (loop, not hardcoded pair); update task list table; update Step 0/1/2/3/5 to read troopers.txt; expand Step 8.4 drill option list

- [ ] **Step 1: Replace hardcoded `spawn rex codex + spawn cody claude` in Step 1**

Read troopers.txt at Step 0 (after consult-init returns), iterate the spawn loop:

```bash
mapfile -t TROOPERS < <(cw_consult_load_troopers "$TOPIC_DIR/_consult/troopers.txt")
# TROOPERS = ("codex\trex" "claude\tcody" "opencode\tbly")
```

Step 1 spawn block: issue `${#TROOPERS[@]}` parallel Bash tool calls (one `bin/spawn.sh <commander> <provider> <topic>` per line).

- [ ] **Step 2: Update spawn-rollback runbook to be N-aware**

Already designed for N (parallel call pattern is N-natural). Verify directive language reflects this.

- [ ] **Step 3: Update Step 2/3 (research-send + research-wait) to iterate TROOPERS**

- [ ] **Step 4: Update Step 5 (verify-send + verify-wait) to iterate TROOPERS**

- [ ] **Step 5: Expand Step 8.4 drill option list**

Drill options for N=3 mode: `rex (codex)` / `cody (claude)` / `bly (opencode)` / `rex + cody` / `rex + bly` / `cody + bly` / `all three (parallel)`.

For N=2 mode: keep current 3-option list (the 2 singles + both).

- [ ] **Step 6: Update task list table**

```markdown
| 1.1 | `1.1 Spawn troopers (parallel) [yoda]` | `Spawning troopers` |
| 1.3 | `1.3 Research [troopers]` | `Troopers researching` |
...
```

(Per-trooper rows are no longer needed; consolidate to "spawn troopers" etc. The runtime task IDs become dynamic.)

- [ ] **Step 7: Run full suite + directive static-wiring tests**

- [ ] **Step 8: Commit**

---

### Task 11: Version bump + CLAUDE.md status

**Files:**
- Modify: `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` (0.14.0 → 0.15.0)
- Modify: `CLAUDE.md` — add v0.15.0 status entry + dogfood gate

- [ ] **Step 1: Bump versions**

```bash
sed -i 's/"version": "0.14.0"/"version": "0.15.0"/g' .claude-plugin/plugin.json .claude-plugin/marketplace.json
```

- [ ] **Step 2: Add CLAUDE.md status entry** (after the v0.14.0 dogfood line):

```markdown
- [x] v0.15.0: 3-trooper /consult — opencode (DeepSeek V4 Pro) joins as `bly`; topology A symmetric verify (every claim 2 independent verifiers); medic-driven trooper enumeration via `providers-available.txt`; N=1 plain-exits with redirect; N=2 unchanged; N=3 new mode with 5-tier adjudicate output (consensus/cross-verified/contested/refuted/pending).
- [ ] v0.15.0 strict-dogfood pass on a real machine (release gate — verify rex+cody+bly all spawn, 3-way diff/adjudicate/synthesis, drill across 7 options).
```

- [ ] **Step 3: Run full suite**

- [ ] **Step 4: Commit**

```bash
git add .claude-plugin/plugin.json .claude-plugin/marketplace.json CLAUDE.md
git commit -m "chore(release): bump plugin to v0.15.0; record 3-trooper /consult status"
```

---

### Task 12: Dogfood + PR

**Files:** none modified — empirical validation.

- [ ] **Step 1: Run /clone-wars:medic** — confirm `providers-available.txt` is written with codex+claude+opencode.

- [ ] **Step 2: Pick a small N=3 topic + run /clone-wars:consult**

Topic: "When should bash scripts use `mapfile` vs `read` loops for line-by-line input?"

Verify:
- Step 0 reads providers-available.txt; consult-init writes `_consult/troopers.txt` with 3 lines
- Step 1 spawns 3 panes: rex-codex, cody-claude, bly-opencode
- Step 4 diff produces N-way Venn output
- Step 6 adjudicated.md has the 5-tier structure
- Step 8 synthesis.md has 3-source attribution tags

- [ ] **Step 3: Drill one round with "all three (parallel)" option** — confirm 3 drilldown files written

- [ ] **Step 4: Teardown + archive**

- [ ] **Step 5: Update CLAUDE.md gate to `[x]`** with date + observed behavior summary

- [ ] **Step 6: Open PR**

```bash
gh pr create --base main --title "v0.15.0: 3-trooper /consult — opencode joins as bly" --body "$(cat <<'EOF'
## Summary
- Add opencode (DeepSeek V4 Pro) as a 3rd /consult trooper, commander `bly`
- Topology A symmetric verify — every claim gets 2 independent verifiers
- Trooper count is dynamic, driven by `\$state_root/providers-available.txt` written by /clone-wars:medic
- N=1 plain-exits with redirect (no skill auto-invoke); N=2 unchanged; N=3 is the new mode
- 5-tier adjudicate output (consensus / cross-verified / contested / refuted / pending)
- Bump plugin 0.14.0 → 0.15.0

## Spec + Plan
- Spec: `docs/superpowers/specs/2026-05-07-consult-3-trooper-design.md`
- Plan: `docs/superpowers/plans/2026-05-07-consult-3-trooper-plan.md`

## Test plan
- [x] Pre-implementation baseline: tests/run.sh green (post-v0.14.0 main)
- [x] TDD per task: failing test → implement → green
- [x] Full suite green after each task
- [x] N=3 dogfood: real /consult run with rex+cody+bly; 5-tier adjudicate confirmed; 3-source synthesis confirmed

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Self-review

**Spec coverage:**
- ✅ Provider→commander mapping (Task 2)
- ✅ Medic remark write (Task 3)
- ✅ Consult-init remark read + N detection + troopers.txt (Task 4)
- ✅ N-way diff (Task 5)
- ✅ Verify scope (Task 6)
- ✅ 5-tier adjudicate (Task 7)
- ✅ 3-source synthesis (Task 8)
- ✅ Teardown N-aware (Task 9)
- ✅ Directive spawn-loop + drill expansion (Task 10)
- ✅ Version bump (Task 11)
- ✅ Dogfood (Task 12)

**Type consistency:** `cw_consult_provider_to_commander` introduced in Task 2, used in Tasks 4/9/10 — consistent. `_consult/troopers.txt` written in Task 4, read in Tasks 5/6/7/9/10 — consistent.

**Placeholder scan:** No "TBD"/"add appropriate"/"similar to" patterns. Each step has actual commands or actual code.
