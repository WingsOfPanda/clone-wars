#!/usr/bin/env bash
# bin/medic.sh — health check for Clone Wars.
# Invoked by /clone-wars:medic (commands/medic.md directs Claude to run this script).
# Prints a status table and exits 0 (OK) or 1 (FAIL).
set -uo pipefail

# Resolve the plugin root. When invoked by Claude Code, $CLAUDE_PLUGIN_ROOT points
# at the installed plugin. When run directly as bin/medic.sh, $BASH_SOURCE[0] is set,
# so we walk one level up from bin/.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/deps.sh"
source "$PLUGIN_ROOT/lib/contracts.sh"

state_root=$(cw_state_root)
fail=0
warn=0
providers_ok=0
providers_total=0

echo
echo "Clone Wars — medic"
echo "  state root: $state_root"
echo

# 1. tmux presence + version
if cw_have_cmd tmux; then
  if cw_tmux_version_ok; then
    log_ok "tmux: $(cw_tmux_version_string)"
  else
    log_error "tmux: $(cw_tmux_version_string) — clone-wars requires >= 3.0"
    fail=1
  fi
else
  log_error "tmux: not on PATH (install: https://github.com/tmux/tmux)"
  fail=1
fi

# 2. inside a tmux session?
if cw_in_tmux_session; then
  log_ok "tmux session: \$TMUX is set"
else
  log_warn "tmux session: \$TMUX not set — \`tmux new -s clone-wars\` before spawning"
  warn=1
fi

# 2b. pane-border-format reads @cw_label so trooper labels show on pane borders.
# Cosmetic-only (runtime works without it; spawn just sets @cw_label and moves on),
# so this is always WARN — never FAIL.
if cw_in_tmux_session && tmux info >/dev/null 2>&1; then
  pbf=$(tmux show-options -g pane-border-format 2>/dev/null)
  if [[ "$pbf" == *@cw_label* ]]; then
    log_ok "pane-border-format: @cw_label-aware (trooper names visible on pane borders)"
  else
    log_warn "pane-border-format doesn't read @cw_label; trooper names won't show on pane borders"
    log_warn "  fix: add to ~/.tmux.conf:"
    log_warn "    set -g pane-border-status top"
    log_warn "    set -g pane-border-format ' #{?@cw_label,#{@cw_label},#{pane_title}} '"
    warn=1
  fi
fi

# 3. state dir resolves and is writable
if cw_state_ensure 2>/dev/null && [[ -w "$state_root" ]]; then
  log_ok "state dir: $state_root (writable)"
else
  log_error "state dir: $state_root cannot be created or is not writable"
  fail=1
fi

# 4. config files present in state root (copy shipped defaults if missing)
for f in contracts.yaml commanders.yaml identity-template.md; do
  if [[ -f "$state_root/$f" ]]; then
    log_ok "config: $f"
  else
    if [[ -f "$PLUGIN_ROOT/config/$f" ]]; then
      if cp "$PLUGIN_ROOT/config/$f" "$state_root/$f" 2>/dev/null; then
        log_ok "config: $f (copied default into state dir)"
      else
        log_error "config: $f missing; copy from plugin defaults failed"
        fail=1
      fi
    else
      log_error "config: $f not in state dir and not shipped at $PLUGIN_ROOT/config/$f"
      fail=1
    fi
  fi
done

# 5. providers in contracts.yaml — WARN on missing, FAIL only when zero are healthy
echo
echo "Providers:"
if cw_contracts_exists; then
  while IFS= read -r prov; do
    [[ -z "$prov" ]] && continue
    providers_total=$((providers_total + 1))
    bin=$(cw_contract_binary "$prov" 2>/dev/null) || bin=""
    if [[ -z "$bin" ]]; then
      log_warn "  $prov: binary field missing in contracts.yaml"
      warn=1
      continue
    fi
    if cw_have_cmd "$bin"; then
      ver=$("$bin" --version 2>/dev/null | head -n1 || true)
      log_ok "  $prov ($bin): ${ver:-installed}"
      providers_ok=$((providers_ok + 1))
    else
      log_warn "  $prov ($bin): not on PATH — skip if you don't use this provider"
      warn=1
    fi
  done < <(cw_contracts_providers)
else
  log_error "contracts.yaml not found at $state_root/contracts.yaml"
  fail=1
fi

echo

# Verdict
if [[ "$fail" -ne 0 || "$providers_ok" -eq 0 ]]; then
  if [[ "$providers_ok" -eq 0 && "$providers_total" -gt 0 ]]; then
    log_error "no providers available; install at least one of: $(cw_contracts_providers | tr '\n' ' ')"
  fi
  echo "Verdict: FAIL — fix items above before spawning"
  exit 1
else
  echo "Verdict: OK — ready to spawn ($providers_ok/$providers_total providers available; $warn warnings)"
  exit 0
fi
