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

cw_state_root() {
  printf '%s\n' "${CLONE_WARS_HOME:-$HOME/.clone-wars}"
}

cw_state_ensure() {
  local root; root=$(cw_state_root)
  mkdir -p "$root/state" "$root/archive"
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

# cw_topic_repo_hash
# Returns the SHA256 hash to use for topic-state paths. Honors $CW_TOPIC_REPO_CWD
# (set by /clone-wars:deploy when the design doc declares **Target Sub-Project:**),
# falling back to the conductor's $PWD when unset (single-repo mode).
# Use this everywhere `cw_repo_hash` was called for topic-state path resolution.
cw_topic_repo_hash() {
  if [[ -n "${CW_TOPIC_REPO_CWD:-}" ]]; then
    cw_repo_hash_for "$CW_TOPIC_REPO_CWD"
  else
    cw_repo_hash_for "$PWD"
  fi
}

# cw_repo_state_dir — absolute path to this repo's state root:
#   $CLONE_WARS_HOME/state/<repo-hash>
# Honors $CW_TOPIC_REPO_CWD via cw_topic_repo_hash so downstream bin scripts
# (turn-send/wait, archive, spawn, teardown) read the same paths that
# bin/deploy-init.sh wrote when the design doc declares **Target Sub-Project:**.
cw_repo_state_dir() {
  printf '%s/state/%s\n' "$(cw_state_root)" "$(cw_topic_repo_hash)"
}

# cw_topic_state_dir <topic> — absolute path to a topic's state dir:
#   $CLONE_WARS_HOME/state/<repo-hash>/<topic>
# Centralises the path construction that was inlined in 6+ callers (bin/list.sh,
# bin/teardown.sh, bin/send.sh, bin/collect.sh, bin/spawn.sh, lib/commanders.sh).
# lib/consult.sh's cw_consult_topic_dir and lib/deploy.sh's cw_deploy_topic_dir
# remain as named alternatives for clarity at call sites where the consult/deploy
# context is meaningful.
# Honors $CW_TOPIC_REPO_CWD via cw_topic_repo_hash (see cw_repo_state_dir).
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
  local sr; sr="$(cw_state_root)"
  if [[ -f "$sr/providers-active.txt" ]]; then
    printf '%s\n' "$sr/providers-active.txt"
  else
    printf '%s\n' "$sr/providers-available.txt"
  fi
}
