#!/usr/bin/env bash
# bin/deploy-init.sh — derive topic slug, create _deploy/, copy
# design doc, create feat/deploy-<topic> branch (unless --no-branch).
# Prints the topic slug on stdout.
#
# Usage:
#   bin/deploy-init.sh [--no-branch] [--branch <name>] [--topic <slug>] <design-path>

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
fi

NO_BRANCH=0
BRANCH_OVERRIDE=""
TOPIC_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-branch)  NO_BRANCH=1; shift ;;
    --branch)     [[ -n "${2:-}" ]] || { echo "--branch requires a value" >&2; exit 2; }
                  BRANCH_OVERRIDE="$2"; shift 2 ;;
    --topic)      [[ -n "${2:-}" ]] || { echo "--topic requires a value" >&2; exit 2; }
                  TOPIC_OVERRIDE="$2"; shift 2 ;;
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

# Export $CW_TOPIC_REPO_CWD BEFORE the ART_DIR computation so cw_deploy_art_dir
# (which calls cw_topic_state_dir → cw_topic_repo_hash) anchors paths on the
# TARGET (sub-repo) hash rather than the conductor's cwd. Every downstream bin
# script (turn-send, turn-wait, archive, spawn, teardown) inherits this env var
# from the directive (commands/deploy.md Step 0 re-exports it from
# target_cwd.txt) so all readers/writers agree on the path.
export CW_TOPIC_REPO_CWD="$TARGET_CWD"
TOPIC_DIR=$(cw_deploy_topic_dir "$TOPIC")
ART_DIR=$(cw_deploy_art_dir "$TOPIC")
[[ ! -d "$ART_DIR" ]] || { log_error "topic _deploy dir already exists: $ART_DIR (pick a different --topic or run teardown)"; exit 1; }

mkdir -p "$ART_DIR" \
  || { log_error "mkdir failed: $ART_DIR"; exit 1; }
cp "$DESIGN_PATH" "$ART_DIR/design.md" \
  || { log_error "cp failed: $DESIGN_PATH -> $ART_DIR/design.md"; exit 1; }
printf '%s' "$TOPIC" > "$ART_DIR/topic.txt" \
  || { log_error "could not write $ART_DIR/topic.txt"; exit 1; }

# Atomic-write target_cwd.txt so downstream consumers (commands/deploy.md
# Step 0 export, bin/spawn.sh --cwd, git -C calls) read the resolved target.
printf '%s\n' "$TARGET_CWD" | cw_atomic_write "$ART_DIR/target_cwd.txt" \
  || { log_error "failed to write target_cwd.txt"; exit 1; }

# Branch — runs in TARGET_CWD so the branch lands in the sub-repo (mirrors
# /executeorder66's `git -C` discipline). Subshell `cd` is fine because
# branch-create is a one-shot git operation, not a long-lived process.
if (( NO_BRANCH == 0 )); then
  if branch=$( cd "$TARGET_CWD" && cw_deploy_branch_create "$TOPIC" "$BRANCH_OVERRIDE" ); then
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
    log_error "branch creation failed; _deploy/ rolled back. Stash/commit your changes (or pass --no-branch) and retry."
    exit 1
  fi
fi

# Auto-detect trooper provider (presence of .claude-plugin/plugin.json
# at the TARGET (sub-repo) root → claude; else → codex). Used by
# commands/deploy.md Step 0 to pick the trooper for spawn. Runs after
# branch-create so a failed branch (auto-rollback above) doesn't leave an
# orphan file.
AUTO_PROVIDER=$(cw_deploy_detect_provider "$TARGET_CWD")
printf '%s\n' "$AUTO_PROVIDER" | cw_atomic_write "$ART_DIR/auto_provider.txt" \
  || { log_error "failed to write auto_provider.txt"; exit 1; }

log_info "topic:        $TOPIC"
log_info "  artifacts:  $ART_DIR"
log_info "  design.md:  $ART_DIR/design.md"
if [[ "$TARGET_CWD" != "$(pwd)" ]]; then
  log_info "  target:     $TARGET_CWD"
fi
log_info "  provider:   $AUTO_PROVIDER (auto-detected)"

printf '%s\n' "$TOPIC"
