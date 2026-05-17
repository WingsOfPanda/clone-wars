#!/usr/bin/env bash
# bin/deploy-init.sh — derive topic slug, create _deploy/, copy
# design doc, create feat/deploy-<topic> branch (unless --no-branch).
# Prints the topic slug on stdout.
#
# Usage:
#   bin/deploy-init.sh [--no-branch] [--branch <name>] [--topic <slug>] <design-path>
#
# Exit codes (v0.30.0):
#   0 — success (topic slug printed to stdout)
#   1 — generic failure (bad args, missing design doc, branch_create non-dirty
#       failure, multi-init failure, etc.)
#   2 — usage error (unknown flag, missing arg)
#   7 — branch creation refused: working tree is dirty (commands/deploy.md
#       Step 0 intercepts this rc to fire its Stash/Commit/Abort
#       AskUserQuestion before re-invoking init.sh)

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/argsfile.sh"
source "$PLUGIN_ROOT/lib/deploy.sh"

# --args-file passthrough (mirrors bin/spawn.sh / bin/send.sh).
if [[ "${1:-}" == "--args-file" ]]; then
  [[ -n "${2:-}" ]] || { echo "--args-file requires a path" >&2; exit 2; }
  args_file="$2"; shift 2
  mapfile -t _TOKENS < <(cw_args_file_load "$args_file")
  set -- "${_TOKENS[@]}" "$@"
  cw_args_file_consume "$args_file"
fi

NO_BRANCH=0
BRANCH_OVERRIDE=""
TOPIC_OVERRIDE=""
PROVIDER_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-branch)  NO_BRANCH=1; shift ;;
    --branch)     [[ -n "${2:-}" ]] || { echo "--branch requires a value" >&2; exit 2; }
                  BRANCH_OVERRIDE="$2"; shift 2 ;;
    --topic)      [[ -n "${2:-}" ]] || { echo "--topic requires a value" >&2; exit 2; }
                  TOPIC_OVERRIDE="$2"; shift 2 ;;
    --provider)   [[ -n "${2:-}" ]] || { echo "--provider requires a value" >&2; exit 2; }
                  PROVIDER_OVERRIDE="$2"; shift 2 ;;
    --) shift; break ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *)  break ;;
  esac
done

[[ $# -eq 1 ]] || { echo "Usage: $0 [--no-branch] [--branch <n>] [--topic <slug>] <design-path>" >&2; exit 2; }
DESIGN_PATH="$1"
[[ -f "$DESIGN_PATH" && -r "$DESIGN_PATH" ]] || { log_error "design doc unreadable: $DESIGN_PATH"; exit 1; }

# Derive topic
if [[ -n "$TOPIC_OVERRIDE" ]]; then
  TOPIC="$TOPIC_OVERRIDE"
else
  TOPIC=$(cw_deploy_derive_topic "$DESIGN_PATH")
  [[ -n "$TOPIC" ]] || { log_error "could not derive topic from filename; pass --topic <slug>"; exit 1; }
fi
cw_deploy_assert_topic "$TOPIC"

# v0.10: resolve target cwd before computing ART_DIR (sub-repo redirect).
# When the design doc has a `**Target Sub-Project:** <slug>` header, redirect
# state + branch + provider-detect into <conductor-cwd>/<slug>. Otherwise
# returns the conductor's cwd (backward-compat: single-repo case unchanged).
TARGET_CWD=$(cw_deploy_resolve_target "$DESIGN_PATH" "$(cw_repo_root)") || {
  log_error "could not resolve target cwd"; exit 1;
}

# v0.31.0: $CW_TOPIC_REPO_CWD export removed. State is project-local now;
# the conductor's invocation cwd is the canonical state-root anchor.
# Downstream bin scripts (turn-send, turn-wait, archive, spawn, teardown)
# read $ART_DIR/target_cwd.txt directly when they need the sub-repo path.
TOPIC_DIR=$(cw_deploy_topic_dir "$TOPIC")
ART_DIR=$(cw_deploy_art_dir "$TOPIC")
[[ ! -d "$ART_DIR" ]] || { log_error "topic _deploy dir already exists: $ART_DIR (pick a different --topic or run teardown)"; exit 1; }

mkdir -p "$ART_DIR" \
  || { log_error "mkdir failed: $ART_DIR"; exit 1; }
cp "$DESIGN_PATH" "$ART_DIR/design.md" \
  || { log_error "cp failed: $DESIGN_PATH -> $ART_DIR/design.md"; exit 1; }
printf '%s' "$TOPIC" > "$ART_DIR/topic.txt" \
  || { log_error "could not write $ART_DIR/topic.txt"; exit 1; }

# v0.20.0: auto-detect routing from design-doc header form.
# - **Target Sub-Project(s):** plural + ## Execution DAG → multi-repo
# - else → single-repo (byte-equal v0.19.0)
if grep -qE '^\*\*Target Sub-Project\(s\):\*\*' "$DESIGN_PATH" \
   && grep -qE '^## Execution DAG\b' "$DESIGN_PATH"; then
  ROUTING="multi-repo"
else
  ROUTING="single-repo"
fi
printf '%s\n' "$ROUTING" > "$ART_DIR/routing.txt" \
  || { log_error "could not write $ART_DIR/routing.txt"; exit 1; }
log_info "routing: $ROUTING"

# v0.20.1: when routing=multi-repo, parse the DAG + assign commanders +
# capture per-cmdr branch bases. commands/deploy.md Step 3a's defensive
# checks (dag-waves.txt, dag-edges.txt, troopers.txt) require these
# files to exist before the directive begins.
if [[ "$ROUTING" == "multi-repo" ]]; then
  "$PLUGIN_ROOT/bin/deploy-dag-parse.sh" "$ART_DIR/design.md" "$ART_DIR" \
    || { log_error "deploy-dag-parse.sh failed"; exit 1; }
  "$PLUGIN_ROOT/bin/deploy-multi-init.sh" "$TOPIC" "$TARGET_CWD" \
    || { log_error "deploy-multi-init.sh failed"; exit 1; }
fi

# Atomic-write target_cwd.txt so downstream consumers (commands/deploy.md
# Step 0 export, bin/spawn.sh --cwd, git -C calls) read the resolved target.
printf '%s\n' "$TARGET_CWD" | cw_atomic_write "$ART_DIR/target_cwd.txt" \
  || { log_error "failed to write target_cwd.txt"; exit 1; }

# Branch — runs in TARGET_CWD so the branch lands in the sub-repo. Subshell
# `cd` is fine because branch-create is a one-shot git operation, not a
# long-lived process; the conductor never inherits the cd.
#
# v0.42.0: default is "stay on current branch" — the auto-branch path only
# fires when --branch is explicitly passed (BRANCH_OVERRIDE non-empty). The
# --no-branch flag remains a no-op back-compat surface.
if (( NO_BRANCH == 0 )) && [[ -n "$BRANCH_OVERRIDE" ]]; then
  branch=$( cd "$TARGET_CWD" && cw_deploy_branch_create "$TOPIC" "$BRANCH_OVERRIDE" )
  branch_rc=$?
  if (( branch_rc == 0 )); then
    if [[ "$TARGET_CWD" != "$(pwd)" ]]; then
      log_info "branch: $branch (in $TARGET_CWD)"
    else
      log_info "branch: $branch"
    fi
  else
    # Auto-rollback: branch failed, remove the _deploy dir we just made.
    # Paranoia check: $ART_DIR must be under $CLONE_WARS_HOME/state.
    case "$ART_DIR" in
      "$(cw_state_root)/state/"*) rm -rf "$ART_DIR" ;;
      *) log_warn "auto-rollback skipped: $ART_DIR not under state root" ;;
    esac
    # v0.30.0: propagate rc=7 verbatim so commands/deploy.md Step 0 can
    # intercept dirty-tree as Stash/Commit/Abort AskUserQuestion. All other
    # branch_create failures (rc=1) keep their existing exit semantics.
    if (( branch_rc == 7 )); then
      log_error "branch creation refused: working tree is dirty; _deploy/ rolled back."
      exit 7
    else
      log_error "branch creation failed (rc=$branch_rc); _deploy/ rolled back. Pass --no-branch to skip."
      exit 1
    fi
  fi
fi

# Auto-detect trooper provider (presence of .claude-plugin/plugin.json
# at the TARGET (sub-repo) root → claude; else → codex). Used by
# commands/deploy.md Step 0 to pick the trooper for spawn. Runs after
# branch-create so a failed branch (auto-rollback above) doesn't leave an
# orphan file. When --provider <name> is passed, it short-circuits the
# auto-detect via cw_deploy_detect_provider's 2nd-arg override.
AUTO_PROVIDER=$(cw_deploy_detect_provider "$TARGET_CWD" "$PROVIDER_OVERRIDE")
printf '%s\n' "$AUTO_PROVIDER" | cw_atomic_write "$ART_DIR/auto_provider.txt" \
  || { log_error "failed to write auto_provider.txt"; exit 1; }

log_info "topic:        $TOPIC"
log_info "  artifacts:  $ART_DIR"
log_info "  design.md:  $ART_DIR/design.md"
if [[ "$TARGET_CWD" != "$(pwd)" ]]; then
  log_info "  target:     $TARGET_CWD"
fi
if [[ -n "$PROVIDER_OVERRIDE" ]]; then
  log_info "  provider:   $AUTO_PROVIDER (override via --provider)"
else
  log_info "  provider:   $AUTO_PROVIDER (auto-detected)"
fi

printf '%s\n' "$TOPIC"
