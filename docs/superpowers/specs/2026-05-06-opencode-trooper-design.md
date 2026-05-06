# v0.13.0 Opencode Trooper — Design Doc

**Goal:** Add `opencode` as the 4th Clone Wars trooper provider, pinned to DeepSeek V4 Pro,
reachable via `/clone-wars:spawn` and (optionally) `/clone-wars:deploy --provider opencode`.

**Status:** Brainstorming → spec (this document) → writing-plans → implementation across 2 PRs.

**Scope amendment:** `CLAUDE.md` currently says "Closed set: claude / codex / gemini" and lists
"DeepSeek and arbitrary OpenAI-compat providers" as out-of-scope. This spec lifts that boundary
**only for** the pinned opencode→DeepSeek-V4-Pro entry. Generic OpenAI-compat providers and
DeepSeek-via-other-clients remain out-of-scope.

---

## Motivation

Clone Wars's value comes from cross-model diversity — codex (OpenAI), claude (Anthropic), and
gemini (Google) cover the three frontier-Western families. Adding opencode wired to DeepSeek
V4 Pro brings:

- **Model diversity** beyond the three Western houses. DeepSeek V4 Pro is the most advanced
  DeepSeek model available; on consult cross-verify, divergent training signal is the whole
  point.
- **An immediate dogfood path** for the user, who has opencode locally configured already.
- **Minimal blast radius** — the 4th provider slot is purely additive; no existing pairing
  changes.

The closed-set restriction in CLAUDE.md was guarding against OMC-style provider creep
(arbitrary OpenAI-compat backends, user-extensible registries). This spec preserves that
discipline by pinning **one** new provider to **one** model and explicitly leaving generic
OpenAI-compat support out of scope.

---

## Architecture

Add `opencode` as the 4th provider in clone-wars's closed set, pinned to DeepSeek V4 Pro via
`-m deepseek/deepseek-v4-pro`. The provider is reachable through `/clone-wars:spawn` and (via
a new `--provider opencode` flag) `/clone-wars:deploy`. consult and deploy's existing
auto-pairings remain unchanged.

Bypass-approval is validated by medic as a precondition, not a CLI flag clone-wars passes —
opencode's approval system is config-file driven (mirrors how we don't manage codex's auth).
Tracer-bullet validates load-bearing TUI mechanics (paste-buffer keymap, ANSI bleed in
`outbox.jsonl`, DeepSeek V4 Pro's JSONL event discipline) **before** `contracts.yaml` ships.

```
+---------------------+        spawn opencode <topic>
|   Master Yoda       | --------------------------------+
|   (Claude Code)     |                                 |
+---------------------+                                 v
                                              +-------------------------+
                                              | tmux pane (split-right) |
                                              | $ opencode -m \         |
                                              |     deepseek/v4-pro     |
                                              +-------------------------+
                                                        |
                       file IPC (identity / inbox / outbox / status)
                                                        |
                                                        v
                                            DeepSeek V4 Pro reads identity.md
                                            emits {"event":"ready"}
```

---

## Components

### 1. `tracer/tracer-bullet-opencode.sh` (PR1, new)

Adapted from `tracer/tracer-bullet.sh`. Validates the load-bearing unknowns in §"Things to
verify in the tracer" of `CLAUDE.md`, but specifically for opencode + DeepSeek V4 Pro:

1. `send-keys` vs `paste-buffer` for opencode's TUI keymap (reading `identity.md` path nudge,
   reading `inbox.md` path nudge).
2. Cold-start time on this machine (calibrates `bootstrap_sleep_s` and `ready_timeout_s` for
   PR2).
3. ANSI escape contamination of `outbox.jsonl` — DeepSeek V4 Pro must `tee` plain-text JSONL.
4. JSONL event discipline — does DeepSeek V4 Pro reliably emit `{"event":"ready"}`,
   `{"event":"ack"}`, `{"event":"done"}`, and the safe-emission patterns in `identity-template.md`?

**Pass criterion:** 3 consecutive clean end-to-end runs locally on liupan's machine.
Output goes to `/tmp/clone-wars-tracer-opencode-<ts>/`.

### 2. `bin/medic.sh` opencode preflight (PR1, new check)

When `opencode` is on PATH, medic adds a new check:

- Look for opencode's config file at one of:
  - `~/.config/opencode/opencode.json`
  - `~/.local/share/opencode/config.json`
  - (whichever the tracer-bullet identifies as canonical)
- Inspect for an auto-approve / yolo / `permission: allow_all` setting (exact key TBD via
  PR1 reconnaissance — `opencode` itself has no documented schema URL, so PR1 will grep an
  actual local config and pin the field name).
- Warn-only line in medic output:
  ```
  WARN: opencode found but auto-approve not set; opencode spawns may block on
        in-TUI permission prompts. To bypass, edit <config-path>: <field> = <value>.
  ```
- Verdict still `OK` when other providers work. Spawn does **not** refuse — user can dismiss
  prompts manually via `tmux select-pane` for v0.13.0; promotion to spawn-refuse deferred to
  v0.13.1+ once real failure modes are observed.

### 3. `config/contracts.yaml` opencode row (PR2)

```yaml
opencode:
  binary: opencode
  modes:
    full:      [-m, deepseek/deepseek-v4-pro]
    read-only: [-m, deepseek/deepseek-v4-pro]   # opencode has no permission flag; same row
  default_mode: full
  ready_timeout_s: 60       # tracer-bullet will calibrate; 60s is conservative starting point
  bootstrap_sleep_s: 15     # DeepSeek inference latency floor; tracer-bullet will calibrate
  identity_injection: send-keys-paste
```

`ready_timeout_s` and `bootstrap_sleep_s` values are placeholders that PR2 will pin to
tracer-bullet's measured cold-start times.

### 4. `lib/contracts.sh`

**No code changes.** The parser already iterates top-level keys dynamically; the `reserved`
allowlist (`consult`) is unchanged.

### 5. `bin/spawn.sh`

**No code changes.** opencode flows through the model-agnostic launch path. The `--cwd` flag
(v0.10.0 sub-repo redirect) works without modification because spawn passes `--cwd` to
`tmux split-window -c` independent of provider.

### 6. `docs/DESIGN.md` + `CLAUDE.md` (PR2)

- `CLAUDE.md` "explicitly out of scope" list:
  ```diff
  - DeepSeek and arbitrary OpenAI-compat providers. Closed set: claude / codex / gemini.
  + Generic OpenAI-compat providers (LM Studio, ollama, vLLM, DeepSeek-via-other-clients).
  + Closed set: claude / codex / gemini / opencode (pinned to DeepSeek V4 Pro).
  ```
- `CLAUDE.md` Status section: add `[ ] v0.13.0: opencode trooper (DeepSeek V4 Pro)` and
  `[ ] v0.13.0 strict-dogfood pass on a real machine (release gate)`.
- `docs/DESIGN.md` provider table: add opencode row with the contracts.yaml fields.

### 7. `bin/deploy-init.sh` `--provider opencode` flag (PR2)

`/clone-wars:deploy` already passes a provider name through to spawn; the auto-detect helper
returns it as `auto_provider.txt`. Adding `--provider opencode` to deploy's CLI surface lets
the user override auto-detect explicitly. The flag plumbs through `cw_deploy_detect_provider`
as an early-return: if `--provider <name>` is set, use it verbatim and skip detection.

---

## Data flow

Identical to other providers. Conductor (Master Yoda) → `/clone-wars:spawn random opencode <topic>`
(or any clone-trooper commander name from `commanders.yaml`) → `spawn.sh` resolves contracts row →
`tmux split-window opencode -m deepseek/deepseek-v4-pro` → `bootstrap_sleep` (15s) →
`cw_pane_send` "Read identity.md" → DeepSeek V4 Pro reads identity → emits `{"event":"ready"}`
→ conductor proceeds.

Inbox/outbox/status.json contracts unchanged. The `--cwd` sub-repo redirect works without
modification.

```
spawn.sh                          tmux pane                       outbox.jsonl
   |                                  |                                 |
   |-- split-window -c <cwd> -------> |                                 |
   |   opencode -m deepseek/v4-pro    |                                 |
   |-- sleep 15s (bootstrap) -------> |                                 |
   |-- send-keys "Read identity.md" -> |                                 |
   |                                  |-- reads identity ------------>  |
   |                                  |-- emits {"event":"ready"} --->  |
   |<-- cw_outbox_wait returns -------|                                 |
```

---

## Error handling

- **Bootstrap timeout / error event** — inherits `_spawn_bootstrap_fail` from `bin/spawn.sh`:
  capture last 25 lines of pane, hard-kill pane, archive state with FAILED suffix. No new
  code path.
- **Medic preflight unset** — warn-only in v0.13.0; spawn proceeds. Trooper pane may pause
  for in-TUI approval prompts. User attaches via `tmux select-pane -t <pane-id>` (printed by
  spawn.sh) to dismiss. **Deferred to v0.13.1+:** promote to spawn-refuse once real failure
  modes are observed.
- **Tracer-bullet failure (PR1)** — output captured at `/tmp/clone-wars-tracer-opencode-<ts>/`.
  PR1 does not merge until 3 consecutive clean runs. If JSONL discipline is the culprit,
  identity-template.md may need a opencode-specific addendum (currently unforeseen).
- **opencode binary missing** — existing `cw_have_cmd "$BINARY"` check in spawn.sh catches
  this and exits with the standard `model 'opencode' has no entry...` message. No new code.

---

## Testing

### PR1
- **Tracer-bullet** (`tracer/tracer-bullet-opencode.sh`): 3 consecutive clean end-to-end runs
  locally on liupan's machine. Manual gate, not CI.
- **`tests/test_medic_opencode_preflight.sh`** (new): fakes `opencode` binary on PATH (via a
  shim that responds to `--version`), fakes config in 3 states (missing, auto-approve unset,
  auto-approve set); asserts medic's warn-line + verdict in each.

### PR2
- **`tests/test_contracts_opencode.sh`** (new): asserts:
  - `cw_contract_binary opencode == opencode`
  - `cw_contract_default_mode opencode == full`
  - `cw_contract_mode_args opencode full` returns `-m\ndeepseek/deepseek-v4-pro` (one per
    line)
  - `cw_contract_ready_timeout opencode == 60` (or whatever PR2 pins from tracer)
  - `cw_contract_bootstrap_sleep opencode == 15` (or whatever PR2 pins from tracer)
- **`tests/test_deploy_provider_flag.sh`** (new): asserts `--provider opencode` overrides
  `cw_deploy_detect_provider`'s default.
- **CLAUDE.md grep gate** (manual or `tests/test_claude_md_scope.sh`): assert
  `"Closed set: claude / codex / gemini / opencode"` substring is present and
  `"Closed set: claude / codex / gemini\b"` (no opencode) is absent.
- **Dogfood gate** (release): `/clone-wars:spawn random opencode dogfood-test` in this repo
  (any commander from `commanders.yaml`; `yoda` is reserved for the conductor), send a
  research prompt about clone-wars itself, verify `findings.md` is written and `ack`/`done`
  events emit with correct JSONL.

---

## Out of scope (explicit)

- **3-way consult** (rex+cody+yoda-opencode). Cross-verify machinery stays 2-way; refactor
  deferred indefinitely.
- **consult auto-pairing changes.** consult still spawns codex+claude.
- **deploy auto-detect of opencode.** Reachable only via explicit `--provider opencode` flag.
- **opencode model selection beyond DeepSeek V4 Pro.** Contract pins one model. Adding
  alternate DeepSeek models (v4-flash, deepseek-reasoner) deferred to a future spec.
- **Generic OpenAI-compat providers** (LM Studio, ollama, vLLM, DeepSeek-via-other-clients).
  Closed set stays 4.
- **medic spawn-refuse on missing auto-approve config.** Warn-only in v0.13.0; promotion
  deferred to v0.13.1+.
- **Commander pool changes.** opencode shares the existing clone-trooper commander pool;
  no opencode-specific personas.

---

## PR plan

### PR1: tracer-bullet + medic preflight
**Branch:** `feat/v0.13.0-opencode-tracer`
**Scope:**
- `tracer/tracer-bullet-opencode.sh`
- `bin/medic.sh` opencode preflight check
- `tests/test_medic_opencode_preflight.sh`
**Merge gate:** 3 consecutive clean tracer runs + medic test green.

### PR2: contracts.yaml row + docs + dogfood
**Branch:** `feat/v0.13.0-opencode-contracts`
**Scope:**
- `config/contracts.yaml` opencode row (with PR1-calibrated timeouts)
- `lib/deploy.sh` + `bin/deploy-init.sh` `--provider opencode` flag
- `tests/test_contracts_opencode.sh`
- `tests/test_deploy_provider_flag.sh`
- `docs/DESIGN.md` + `CLAUDE.md` scope amendment + Status update
- `tests/test_claude_md_scope.sh` (or grep gate)
- `.claude-plugin/{plugin,marketplace}.json` version bump 0.12.2 → 0.13.0
**Merge gate:** all tests green + dogfood pass.

---

## Open questions for PR1 reconnaissance

These are deliberately not answered in this spec — PR1's tracer-bullet will pin them:

1. Exact path to opencode's config file (`~/.config/opencode/opencode.json` vs
   `~/.local/share/opencode/config.json` vs other).
2. Exact field name for auto-approve / yolo setting in opencode's config.
3. Cold-start time on this machine (drives `bootstrap_sleep_s` and `ready_timeout_s` final
   values).
4. Whether opencode's TUI accepts `tmux paste-buffer` cleanly or requires `send-keys -l` for
   the identity/inbox path nudges.
5. Whether DeepSeek V4 Pro consistently obeys identity-template.md's safe-JSONL-emission
   patterns (Pattern A/B/C). If not, identity-template.md may need an addendum.

PR2 fills in concrete values from PR1's measurements.
