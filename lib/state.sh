# lib/state.sh — $CLONE_WARS_HOME resolution and state-dir layout helpers.
# Sourced. All paths are absolute.

# Shared slug regex base used by consult + deploy for sub-project / leaf names.
# Compose anchored variants at call sites:
#   single slug:  ^${CW_SLUG_REGEX_BASE}$
#   <hub>/<leaf>: ^${CW_SLUG_REGEX_BASE}/${CW_SLUG_REGEX_BASE}$
# Guarded so re-sourcing state.sh in the same shell doesn't trip readonly.
if [[ -z "${CW_SLUG_REGEX_BASE:-}" ]]; then
  readonly CW_SLUG_REGEX_BASE='[A-Za-z0-9._-]+'
fi

# cw_state_root — absolute path to this project's clone-wars state root.
#
# Default: $PWD/.clone-wars (project-local; the directive's Bash blocks run
# in the conductor's invocation cwd, so $PWD resolves there).
#
# Test/debug seam: if CLONE_WARS_HOME is set, return its value verbatim.
# Production flow never sets it; 96 existing tests use the env var for
# sandbox isolation (they want state under a tmpdir without cd'ing).
#
# INVARIANT: never call inside a `cd` subshell — $PWD changes there. The
# only safe caller is the conductor's invocation cwd (which inherits $PWD
# from the slash directive's environment).
cw_state_root() {
  if [[ -n "${CLONE_WARS_HOME:-}" ]]; then
    printf '%s\n' "$CLONE_WARS_HOME"
  else
    printf '%s/.clone-wars\n' "$PWD"
  fi
}

# cw_state_ensure — create state/ + archive/ subdirs and self-ignoring
# .gitignore so the entire .clone-wars/ dir stays out of the user's git
# history. Idempotent: .gitignore only written if absent (preserves user
# customizations across re-runs).
cw_state_ensure() {
  local root; root=$(cw_state_root)
  mkdir -p "$root/state" "$root/archive"
  [[ -f "$root/.gitignore" ]] || printf '*\n' > "$root/.gitignore"
}

# cw_global_state_root — per-MACHINE config root.
# Always resolves to ${CLONE_WARS_HOME:-$HOME/.clone-wars}, regardless of $PWD.
# Use for config that is per-install, not per-project: medic's
# providers-{active,available}.txt, contracts.yaml, commanders.yaml,
# the archive/ subtree.
#
# Contrast with cw_state_root (per-PROJECT state at $PWD/.clone-wars/)
# for /consult, /deploy, /deep-research, /meditate per-topic work.
#
# v0.38.0: introduced to fix the medic→consult break where v0.31.0's
# project-local default trapped per-machine config under
# <project>/.clone-wars/, but various scripts kept reading from
# ~/.clone-wars/ via literal $HOME paths. See
# docs/superpowers/specs/2026-05-16-v0.38.0-state-root-split-design.md.
cw_global_state_root() {
  printf '%s\n' "${CLONE_WARS_HOME:-$HOME/.clone-wars}"
}

# cw_global_state_ensure — like cw_state_ensure but for the global root.
# Auto-creates .gitignore = '*' on first call. ~/.clone-wars/ is not
# usually under git, but the defensive write costs nothing and covers
# the case where a user nests CLONE_WARS_HOME inside an unrelated repo.
cw_global_state_ensure() {
  local root; root=$(cw_global_state_root)
  mkdir -p "$root"
  [[ -f "$root/.gitignore" ]] || printf '*\n' > "$root/.gitignore" 2>/dev/null || true
}

# cw_repo_hash_for <cwd>
# Same hashing rule as cw_repo_hash but takes an explicit cwd. Used by
# /clone-wars:deploy when the trooper redirects into a sub-repo and the
# state path must key off the sub-repo (not the conductor's cwd).
cw_repo_hash_for() {
  local cwd="${1:-}"
  [[ -n "$cwd" ]] || { echo "cw_repo_hash_for: missing cwd arg" >&2; return 2; }
  local p
  p=$(realpath "$cwd" 2>/dev/null || readlink -f "$cwd" 2>/dev/null || printf '%s' "$cwd")
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$p" | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$p" | shasum -a 256 | awk '{print $1}'
  else
    echo "cw_repo_hash_for: no sha256 tool (sha256sum or shasum) found" >&2
    return 1
  fi
}

cw_repo_hash() {
  cw_repo_hash_for "$PWD"
}

# cw_topic_repo_hash — SHA256 hash used as a state-path component.
#
# v0.31.0: simplified to return hash of $PWD. The CW_TOPIC_REPO_CWD branch
# (v0.10.0 sub-repo redirect for deploy multi-repo) is removed in v0.31.0
# because state is now project-local: the conductor's invocation cwd is
# the canonical anchor; sub-repo state lives in the SAME .clone-wars/
# as the rest of the deploy. The env var is no longer set by any
# production code path. The hash segment is kept in the path shape for
# v0.31.0 (cosmetic; project-local already disambiguates); v0.32.0
# cleanup sweep decides whether to drop the hash entirely.
cw_topic_repo_hash() {
  cw_repo_hash_for "$PWD"
}

# cw_repo_state_dir — absolute path to this repo's state root:
#   <state-root>/state/<repo-hash>
# v0.31.0: state-root is project-local (<invoking-cwd>/.clone-wars/).
# The <repo-hash> segment is kept (cosmetic in v0.31.0; project-local
# already disambiguates by directory); v0.32.0 cleanup may drop it.
cw_repo_state_dir() {
  printf '%s/state/%s\n' "$(cw_state_root)" "$(cw_topic_repo_hash)"
}

# cw_topic_state_dir <topic> — absolute path to a topic's state dir:
#   <state-root>/state/<repo-hash>/<topic>
# Centralises the path construction that was inlined in 6+ callers
# (bin/list.sh, bin/teardown.sh, bin/send.sh, bin/collect.sh,
# bin/spawn.sh, lib/commanders.sh). lib/consult.sh's cw_consult_topic_dir
# and lib/deploy.sh's cw_deploy_topic_dir remain as named alternatives
# for clarity at call sites where the consult/deploy context is
# meaningful.
cw_topic_state_dir() {
  printf '%s/state/%s/%s\n' "$(cw_state_root)" "$(cw_topic_repo_hash)" "$1"
}

# cw_atomic_write <dest-path> — read stdin and atomically write to <dest-path>
# via a per-call mktemp + rename. POSIX rename within the same directory is
# atomic — readers see exactly the previous file or exactly the new one,
# never a partial write. Concurrent callers don't race because each call
# gets its own tmp suffix. The trap unlinks tmp on any abnormal exit.
#
# Returns 1 (with log_error) if mktemp or mv fails. Stdin should be the
# complete file content; the function does not append.
#
# Examples:
#   printf 'hello\n' | cw_atomic_write /path/to/file
#   cw_atomic_write /tmp/foo <<EOF
#   line1
#   line2
#   EOF
cw_atomic_write() {
  local dest="$1" tmp
  [[ -n "$dest" ]] || { echo "cw_atomic_write: missing dest path" >&2; return 2; }
  tmp=$(mktemp "${dest}.tmp.XXXXXX") || {
    log_error "cw_atomic_write: mktemp failed for ${dest}.tmp.XXXXXX"
    return 1
  }
  trap 'rm -f "$tmp"' RETURN
  if ! cat > "$tmp"; then
    log_error "cw_atomic_write: write to tmp failed (tmp=$tmp dest=$dest)"
    return 1
  fi
  if ! mv -f "$tmp" "$dest"; then
    log_error "cw_atomic_write: mv tmp -> dest failed (tmp=$tmp dest=$dest)"
    return 1
  fi
  trap - RETURN
}

# cw_run_dir <command>
# Resolve a per-invocation directive scratch dir under $state_root/_run/.
# - Sweeps any sibling _run/<*>/ subdirs whose mtime is >24h old (idempotent;
#   crash-safe; concurrent live invocations untouched since they have fresh
#   mtime). Sweep window overridable via CW_RUN_SWEEP_S.
# - Creates _run/.gitignore = '*' on first call (mirrors $state_root/.gitignore
#   from v0.31.0).
# - Returns absolute path of a fresh mktemp -d _run/<command>.XXXXXX/ via stdout.
# - Writeback the same path to _run/.last (atomic) so subsequent Bash blocks
#   within the same directive can read it without needing /tmp.
#
# Closes the v0.36.0 cross-session pointer race: parallel /clone-wars:*
# invocations in different repos now use distinct _run/ paths (since
# $state_root is project-local per v0.31.0). See
# docs/superpowers/specs/2026-05-16-v0.36.0-run-dir-pointers-design.md.
cw_run_dir() {
  local command="${1:-}" root run_root run_dir
  [[ -n "$command" ]] || { echo "cw_run_dir: missing <command> arg" >&2; return 2; }
  root=$(cw_state_root)
  cw_state_ensure
  run_root="$root/_run"
  mkdir -p "$run_root"
  [[ -f "$run_root/.gitignore" ]] || printf '*\n' > "$run_root/.gitignore"

  # Sweep stale subdirs.
  local sweep_s="${CW_RUN_SWEEP_S:-86400}"
  local now d mtime
  now=$(date +%s)
  for d in "$run_root"/*/; do
    [[ -d "$d" ]] || continue
    mtime=$(stat -c '%Y' "$d" 2>/dev/null \
            || stat -f '%m' "$d" 2>/dev/null \
            || echo 0)
    if (( mtime > 0 )) && (( now - mtime > sweep_s )); then
      rm -rf "$d"
    fi
  done

  run_dir=$(mktemp -d -p "$run_root" "$command.XXXXXX") \
    || { echo "cw_run_dir: mktemp failed under $run_root" >&2; return 1; }
  printf '%s' "$run_dir" | cw_atomic_write "$run_root/.last" \
    || { echo "cw_run_dir: .last writeback failed" >&2; return 1; }
  printf '%s\n' "$run_dir"
}

# cw_run_dir_last
# Read the most-recently-mktemp'd run dir for THIS project's $state_root.
# Used by directive Bash blocks 2..N to discover the run dir without /tmp.
# Errors if .last is missing (would mean the directive's first Bash block
# didn't call cw_run_dir).
cw_run_dir_last() {
  local root run_root last
  root=$(cw_state_root)
  run_root="$root/_run"
  last="$run_root/.last"
  [[ -f "$last" ]] \
    || { echo "cw_run_dir_last: $last missing — first Bash block must call cw_run_dir" >&2; return 1; }
  cat "$last"
}

# cw_state_archive_dir <art-dir> <archive-base> <slug>
#
# Move <art-dir> into <archive-base>/<slug>-<ts>/, with same-second collision
# suffixing (-2, -3, ... up to -99). Creates <archive-base> if missing.
# Prints the destination path to stdout on success.
#
# Returns:
#   0 — moved successfully (stdout = dest path)
#   1 — source missing OR mkdir failed OR collision counter > 99 OR mv failed
#
# Used by bin/consult-archive.sh + bin/deploy-archive.sh.
cw_state_archive_dir() {
  local art_dir="$1" archive_base="$2" slug="$3"
  [[ -d "$art_dir" ]] || { log_error "$art_dir missing — already archived?"; return 1; }
  mkdir -p "$archive_base" || { log_error "mkdir failed: $archive_base"; return 1; }
  local ts dest n=2
  ts=$(date -u +'%Y%m%dT%H%M%SZ')
  dest="$archive_base/${slug}-$ts"
  while [[ -e "$dest" ]]; do
    dest="$archive_base/${slug}-$ts-$n"
    n=$((n + 1))
    (( n > 99 )) && { log_error "too many same-second archive collisions; aborting"; return 1; }
  done
  mv "$art_dir" "$dest" || { log_error "mv failed: $art_dir -> $dest"; return 1; }
  printf '%s\n' "$dest"
}

# cw_repo_root — resolve trooper's working directory.
# Uses git toplevel when inside a repo (so the trooper sees the whole project,
# not just the subdir the conductor happens to be in). Falls back to $PWD for
# non-git dirs. Used by lib/tmux.sh for the -c flag of tmux split-window.
cw_repo_root() {
  local root
  root=$(git rev-parse --show-toplevel 2>/dev/null) && { printf '%s\n' "$root"; return 0; }
  printf '%s\n' "$PWD"
}

# cw_active_providers_path — canonical path the consult roster reads.
# Prefers providers-active.txt (user-selected via /clone-wars:medic) over
# providers-available.txt (medic-detected). Pure path resolution; does
# not validate contents — callers grep -vE '#' / blank as today.
#
# Used by bin/consult-init.sh and any future consumer that needs to know
# "which providers should /consult use right now".
cw_active_providers_path() {
  local sr; sr="$(cw_global_state_root)"
  if [[ -f "$sr/providers-active.txt" ]]; then
    printf '%s\n' "$sr/providers-active.txt"
  else
    printf '%s\n' "$sr/providers-available.txt"
  fi
}
