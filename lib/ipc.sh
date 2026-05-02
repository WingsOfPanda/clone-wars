# lib/ipc.sh — file-based IPC between Master Yoda and troopers.
# Sourced. Depends on lib/state.sh.
#
# State layout (per docs/DESIGN.md §State directory layout):
#   $CLONE_WARS_HOME/state/<repo-hash>/<topic>/<commander>-<model>/
#     ├── identity.md      — system prompt injected at spawn
#     ├── inbox.md         — Master Yoda writes; trooper reads on nudge
#     ├── outbox.jsonl     — trooper appends; Master Yoda tails
#     ├── status.json      — trooper's current state (Plan B+ may use)
#     └── pane.json        — {pane_id, pid, spawned_at} for orphan detection

# cw_trooper_dir <commander> <model> <topic> — print absolute state-dir path.
cw_trooper_dir() {
  printf '%s/state/%s/%s/%s-%s\n' \
    "$(cw_state_root)" "$(cw_repo_hash)" "$3" "$1" "$2"
}

cw_inbox_path()    { printf '%s/inbox.md\n'      "$(cw_trooper_dir "$1" "$2" "$3")"; }
cw_outbox_path()   { printf '%s/outbox.jsonl\n'  "$(cw_trooper_dir "$1" "$2" "$3")"; }
cw_identity_path() { printf '%s/identity.md\n'   "$(cw_trooper_dir "$1" "$2" "$3")"; }
cw_status_path()   { printf '%s/status.json\n'   "$(cw_trooper_dir "$1" "$2" "$3")"; }
cw_pane_meta_path(){ printf '%s/pane.json\n'     "$(cw_trooper_dir "$1" "$2" "$3")"; }

# cw_state_init <commander> <model> <topic>
# Create a fresh state dir for a trooper, clean any prior IPC files.
# Touches outbox.jsonl so polling can grep the empty file safely.
cw_state_init() {
  local dir; dir=$(cw_trooper_dir "$1" "$2" "$3")
  mkdir -p "$dir"
  rm -f "$dir/identity.md" "$dir/inbox.md" "$dir/outbox.jsonl" "$dir/status.json" "$dir/pane.json"
  touch "$dir/outbox.jsonl"
}

# cw_state_archive <commander> <model> <topic> [<suffix>]
# Move a trooper's state dir to archive/<repo-hash>/<topic>/<commander>-<model>-<ts>[-<suffix>]/.
# Counter loop appends -2, -3, ... if the path exists (handles same-second collisions).
cw_state_archive() {
  local commander="$1" model="$2" topic="$3" suffix="${4:-}"
  local src dst base ts n
  src=$(cw_trooper_dir "$commander" "$model" "$topic")
  [[ -d "$src" ]] || return 0
  ts=$(date -u +"%Y%m%dT%H%M%SZ")
  base="$(cw_state_root)/archive/$(cw_repo_hash)/$topic/${commander}-${model}-${ts}"
  [[ -n "$suffix" ]] && base="${base}-${suffix}"
  dst="$base"
  n=2
  while [[ -e "$dst" ]]; do
    dst="${base}-${n}"
    n=$((n + 1))
  done
  mkdir -p "$(dirname "$dst")"
  mv "$src" "$dst"
  printf '%s\n' "$dst"
}

# cw_identity_write <commander> <model> <topic>
# Write identity.md by substituting {{vars}} in the plugin's identity template.
# Appends a trailing "first action" instruction so the trooper emits {ready}
# immediately.
#
# v0.5.2: lookup chain is in-tree only — the legacy
# $CLONE_WARS_HOME/identity-template.md per-machine override is NO LONGER
# consulted. It silently shadowed plugin updates (e.g. v0.5.x foreground
# guards never reached troopers if a stale Apr-26-installed override sat
# at $CLONE_WARS_HOME). Aligns with v0.5.0's "in-tree only, no overrides"
# decision for the prompt-template registry. Power users who need to
# customize should fork or edit the plugin path directly. Stale orphan
# files at $CLONE_WARS_HOME/identity-template.md become harmless dead
# weight and can be deleted.
cw_identity_write() {
  local commander="$1" model="$2" topic="$3"
  local dir identity tmpl outbox
  dir=$(cw_trooper_dir "$commander" "$model" "$topic")
  identity="$dir/identity.md"
  outbox="$dir/outbox.jsonl"
  tmpl="$PLUGIN_ROOT/config/prompt-templates/identity.md"
  [[ -f "$tmpl" ]] || tmpl="$PLUGIN_ROOT/config/identity-template.md"

  sed \
    -e "s|{{commander}}|$commander|g" \
    -e "s|{{model}}|$model|g" \
    -e "s|{{topic}}|$topic|g" \
    -e "s|{{state_dir}}|$dir|g" \
    "$tmpl" > "$identity"

  cat >> "$identity" <<EOF

---

**First action (do this immediately, then wait):**

Append exactly ONE JSONL line to $outbox. The line MUST be:

\`{"event":"ready","ts":"<ISO-8601 UTC>","commander":"$commander","model":"$model"}\`

Generate the timestamp at the moment you emit (NOT a remembered value). Use this shell command verbatim:

\`echo "{\\"event\\":\\"ready\\",\\"ts\\":\\"\$(date -u +'%Y-%m-%dT%H:%M:%SZ')\\",\\"commander\\":\\"$commander\\",\\"model\\":\\"$model\\"}" >> $outbox\`

The \\\$(date -u ...) command runs in YOUR shell when you execute the command — it produces a fresh timestamp at the moment you emit, not a stale one from when you read this prompt.

Then stop and wait. I will send another instruction asking you to read your inbox.
EOF
}

# cw_inbox_write [--from <sender>] <commander> <model> <topic> <task_text>
# Overwrite inbox.md with the task, terminating with the END_OF_INSTRUCTION
# sentinel so the trooper knows the message is complete. Every message starts
# with a `From: <sender>` line followed by a blank line so the trooper knows
# who issued it. Sender defaults to "master-yoda" (the conductor); pass
# `--from <name>` to attribute the message to another trooper or operator.
# Sender names are restricted to `[a-zA-Z0-9_-]+` to keep the header
# parser-friendly and to prevent shell-metacharacter injection into the
# heredoc.
#
# Atomic via per-call mktemp + rename: each invocation gets its OWN tmp file
# at "${inbox}.tmp.XXXXXX" (so concurrent callers can't truncate each other's
# in-flight content), then mv -f into place. POSIX rename within the same
# directory is atomic — readers and competing writers see exactly one of the
# completed versions, never a partial one. The trap unlinks the tmp on any
# abnormal exit (e.g. shell signal mid-write) so we don't leak in the
# trooper's state dir.
cw_inbox_write() {
  local sender="master-yoda"
  if [[ "${1:-}" == "--from" ]]; then
    [[ -n "${2:-}" ]] || { echo "cw_inbox_write: --from requires a sender name" >&2; return 2; }
    sender="$2"
    shift 2
    [[ "$sender" =~ ^[a-zA-Z0-9_-]+$ ]] \
      || { echo "cw_inbox_write: invalid sender name '$sender' (allowed: [a-zA-Z0-9_-])" >&2; return 2; }
  fi
  local commander="$1" model="$2" topic="$3" task="$4"
  local inbox outbox tmp
  inbox=$(cw_inbox_path "$commander" "$model" "$topic")
  outbox=$(cw_outbox_path "$commander" "$model" "$topic")
  tmp=$(mktemp "${inbox}.tmp.XXXXXX")
  trap 'rm -f "$tmp"' EXIT
  cat > "$tmp" <<EOF
From: $sender

$task

When done, append a single JSONL line to $outbox:

\`{"event":"done","summary":"<one-line summary>","ts":"<iso-timestamp>"}\`

END_OF_INSTRUCTION
EOF
  # Check rc on mv: under `set -uo pipefail` (no -e) a silent mv failure
  # would otherwise leave the inbox stale and `cw_inbox_write` returning 0,
  # making bin/send.sh log "wrote inbox" and nudge the pane to read content
  # that never landed. Surface the failure loudly and propagate non-zero rc.
  if ! mv -f "$tmp" "$inbox"; then
    log_error "cw_inbox_write: mv tmp -> inbox failed (tmp=$tmp inbox=$inbox)"
    rm -f "$tmp"
    trap - EXIT
    return 1
  fi
  trap - EXIT
}

# cw_event_match_pattern <event_name>
# Print a `grep -E` pattern that matches a single JSONL line whose `event`
# field is EXACTLY <event_name>. Anchors at the start (^) and requires the
# next character after the event name to be `,` (more fields follow) or `}`
# (event has no payload). Closes the false-positive class where a substring
# grep would match `"event":"done"` literal text inside another event's note.
cw_event_match_pattern() {
  local event="$1"
  [[ -n "$event" ]] || { echo "cw_event_match_pattern: empty event" >&2; return 1; }
  printf '^\\{"event":"%s"[,}]' "$event"
}

# cw_outbox_wait <commander> <model> <topic> <event1> [<event2> ...] <timeout>
# Poll the outbox for ANY of the named events. Events are positional args
# between <topic> and the FINAL <timeout> arg. Print the matching JSON line
# on stdout and return 0 as soon as any listed event appears. Return 1 with
# no output if the timeout expires.
#
# Single-event call (backward compat with Phase 1):
#   cw_outbox_wait c m t ready 30
# Multi-event call (Phase 2's short-circuit on error during bootstrap):
#   cw_outbox_wait c m t ready error 30
#
# Uses cw_event_match_pattern for strict (anchored, ^\{"event":"X"[,}])
# matching so a progress note containing a quoted event name doesn't
# false-positive.
cw_outbox_wait() {
  local commander="$1" model="$2" topic="$3"
  shift 3
  # Last positional is timeout; everything between <topic> and it is events.
  (( $# >= 2 )) || { echo "cw_outbox_wait: need at least one event and a timeout" >&2; return 2; }
  local timeout="${!#}"   # ${!#} = last positional
  set -- "${@:1:$#-1}"    # drop the last positional → only events remain
  local events=("$@")
  [[ "$timeout" =~ ^[0-9]+$ ]] || { echo "cw_outbox_wait: timeout must be a non-negative integer; got '$timeout'" >&2; return 2; }
  local outbox; outbox=$(cw_outbox_path "$commander" "$model" "$topic")
  local i event pat
  for ((i = 0; i < timeout; i++)); do
    for event in "${events[@]}"; do
      pat=$(cw_event_match_pattern "$event")
      if grep -qE "$pat" "$outbox" 2>/dev/null; then
        grep -E "$pat" "$outbox" | tail -n1
        return 0
      fi
    done
    sleep 1
  done
  return 1
}

# cw_outbox_wait_since <commander> <model> <topic> <byte-offset> <event...> <timeout>
# Like cw_outbox_wait, but only considers content AFTER <byte-offset>. Capture
# `wc -c < "$outbox" | tr -d ' '` BEFORE the inbox nudge; this wait then
# matches only events the dispatched task produced.
cw_outbox_wait_since() {
  local commander="$1" model="$2" topic="$3" offset="$4"
  shift 4
  (( $# >= 2 )) || { echo "cw_outbox_wait_since: need event(s) and timeout" >&2; return 2; }
  local timeout="${!#}"
  set -- "${@:1:$#-1}"
  local events=("$@")
  [[ "$offset"  =~ ^[0-9]+$ ]] || { echo "cw_outbox_wait_since: bad offset '$offset'" >&2; return 2; }
  [[ "$timeout" =~ ^[0-9]+$ ]] || { echo "cw_outbox_wait_since: bad timeout '$timeout'" >&2; return 2; }
  local outbox; outbox=$(cw_outbox_path "$commander" "$model" "$topic")
  local i event pat tail_size tail_content
  for ((i = 0; i < timeout; i++)); do
    if [[ -f "$outbox" ]]; then
      tail_size=$(wc -c < "$outbox" | tr -d ' ')
      if (( tail_size > offset )); then
        tail_content=$(tail -c "+$((offset + 1))" "$outbox")
        for event in "${events[@]}"; do
          pat=$(cw_event_match_pattern "$event")
          if printf '%s\n' "$tail_content" | grep -qE "$pat"; then
            printf '%s\n' "$tail_content" | grep -E "$pat" | tail -n1
            return 0
          fi
        done
      fi
    fi
    sleep 1
  done
  return 1
}

# cw_outbox_wait_all <troopers-file> <event...> <timeout>
# Block until every trooper listed all match. <troopers-file> format:
# one line per trooper, colon-delimited "<commander>:<model>:<topic>:<offset>".
# Returns 0 if all matched within <timeout>; 1 if any trooper timed out;
# 2 on bad args / empty file.
cw_outbox_wait_all() {
  local file="$1"; shift
  (( $# >= 2 )) || { echo "cw_outbox_wait_all: need event(s) and timeout" >&2; return 2; }
  local timeout="${!#}"
  set -- "${@:1:$#-1}"
  local events=("$@")
  [[ -f "$file" ]]             || { echo "cw_outbox_wait_all: file not found: $file" >&2; return 2; }
  [[ "$timeout" =~ ^[0-9]+$ ]] || { echo "cw_outbox_wait_all: bad timeout '$timeout'" >&2; return 2; }

  mapfile -t lines < <(grep -v '^[[:space:]]*$' "$file")
  (( ${#lines[@]} > 0 )) || { echo "cw_outbox_wait_all: empty troopers file" >&2; return 2; }

  local deadline=$(( $(date +%s) + timeout ))
  local line commander model topic offset remaining
  for line in "${lines[@]}"; do
    IFS=':' read -r commander model topic offset <<< "$line"
    [[ -n "$commander" && -n "$model" && -n "$topic" && -n "$offset" ]] \
      || { echo "cw_outbox_wait_all: malformed line: $line" >&2; return 2; }
    remaining=$(( deadline - $(date +%s) ))
    (( remaining > 0 )) || return 1
    cw_outbox_wait_since "$commander" "$model" "$topic" "$offset" "${events[@]}" "$remaining" >/dev/null || return 1
  done
  return 0
}

# cw_outbox_dump <commander> <model> <topic>
# Print the whole outbox.jsonl. Used by collect/list for diagnostics.
cw_outbox_dump() {
  local outbox; outbox=$(cw_outbox_path "$1" "$2" "$3")
  [[ -f "$outbox" ]] && cat "$outbox"
}

# cw_pane_meta_write <commander> <model> <topic> <pane_id>
# Write pane.json. v0.0.4 adds "commander" + "model" so consumers don't
# have to parse the state dir name (which broke for hyphenated model keys
# in iteration paths where the commander wasn't otherwise known).
cw_pane_meta_write() {
  local commander="$1" model="$2" topic="$3" pane="$4"
  local meta; meta=$(cw_pane_meta_path "$commander" "$model" "$topic")
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  printf '{"pane_id":"%s","commander":"%s","model":"%s","spawned_at":"%s"}\n' \
    "$pane" "$commander" "$model" "$ts" > "$meta"
}

# cw_pane_meta_read <commander> <model> <topic>
# Print the pane_id from pane.json, or empty + return 1 if missing.
cw_pane_meta_read() {
  local meta; meta=$(cw_pane_meta_path "$1" "$2" "$3")
  [[ -f "$meta" ]] || return 1
  awk -F'"' '/"pane_id"/ {print $4; exit}' "$meta"
}

# Internal one-shot guard so the fallback warning fires at most once per
# shell invocation across all three readers (model/commander/read_for_dir),
# not once per trooper iterated. Uses a $$-keyed marker file because the
# readers are typically called via $(...) command substitution (subshells),
# so an in-memory variable wouldn't propagate back to the parent.
_CW_PANE_META_FALLBACK_WARNED=""

_cw_pane_meta_fallback_warn() {
  local tdir="${TMPDIR:-/tmp}"
  local marker="$tdir/cw-meta-fallback-warned-$$"
  if [[ -n "${_CW_PANE_META_FALLBACK_WARNED:-}" ]] || [[ -f "$marker" ]]; then
    return 0
  fi
  log_warn "pane.json predates v0.0.4 (no 'commander'/'model' fields); using dir-name parser as fallback. Hyphenated model keys may be misparsed in list/teardown until the affected troopers are torn down + respawned. This deprecation notice will be removed in a future version."
  _CW_PANE_META_FALLBACK_WARNED=1
  : > "$marker" 2>/dev/null || true
  # Best-effort cleanup of stale markers from dead PIDs to avoid
  # littering /tmp across runs. Silent on any failure.
  local f pid
  for f in "$tdir"/cw-meta-fallback-warned-*; do
    [[ -f "$f" ]] || continue
    pid="${f##*-}"
    [[ "$pid" == "$$" ]] && continue
    kill -0 "$pid" 2>/dev/null || rm -f "$f" 2>/dev/null || true
  done
}

# _cw_pane_meta_field <key> <file>
# Extract the string value of a JSON key from pane.json. Handles both the
# v0.0.4+ single-line format (`{"pane_id":"...","commander":"...","model":"...",...}`)
# and any future multi-line variants. Returns empty if key is missing.
_cw_pane_meta_field() {
  local key="$1" file="$2"
  grep -oE "\"${key}\":\"[^\"]*\"" "$file" 2>/dev/null \
    | head -n1 \
    | sed -e "s/^\"${key}\":\"//" -e 's/"$//'
}

# cw_pane_meta_model <commander> <model_hint> <topic>
# Return the model recorded in pane.json. <model_hint> is the value the
# caller derived from the state dir name (used both to locate pane.json
# and as the fallback return when pane.json predates v0.0.4).
cw_pane_meta_model() {
  local commander="$1" model_hint="$2" topic="$3"
  local meta; meta=$(cw_pane_meta_path "$commander" "$model_hint" "$topic")
  if [[ -f "$meta" ]]; then
    local val
    val=$(_cw_pane_meta_field model "$meta")
    if [[ -n "$val" ]]; then
      printf '%s\n' "$val"
      return 0
    fi
  fi
  _cw_pane_meta_fallback_warn
  printf '%s\n' "$model_hint"
}

# cw_pane_meta_commander <commander_hint> <model_hint> <topic>
# Return the commander recorded in pane.json. Hints are the values the
# caller derived from the state dir name; both arrive used to locate
# pane.json. Falls back to <commander_hint> when pane.json predates v0.0.4.
cw_pane_meta_commander() {
  local commander_hint="$1" model_hint="$2" topic="$3"
  local meta; meta=$(cw_pane_meta_path "$commander_hint" "$model_hint" "$topic")
  if [[ -f "$meta" ]]; then
    local val
    val=$(_cw_pane_meta_field commander "$meta")
    if [[ -n "$val" ]]; then
      printf '%s\n' "$val"
      return 0
    fi
  fi
  _cw_pane_meta_fallback_warn
  printf '%s\n' "$commander_hint"
}

# cw_pane_meta_read_for_dir <trooper_dir>
# Reads pane.json from the given absolute trooper-dir path and emits THREE
# lines on stdout: <commander>, <model>, <pane_id>. Use this from any
# iteration path that walks state/<repo-hash>/<topic>/* without a known
# commander — it's the ONLY safe way to recover the canonical commander
# and model when the model key contains hyphens. Falls back to dir-name
# parsing for legacy v0.0.3 pane.json files (with one-time warning).
cw_pane_meta_read_for_dir() {
  local dir="$1"
  local meta="$dir/pane.json"
  local name="${dir%/}"; name="${name##*/}"
  # Hint values: ambiguous for hyphenated models, used only when pane.json
  # lacks the canonical fields.
  local commander="${name%-*}"
  local model="${name##*-}"
  local pane=""
  if [[ -f "$meta" ]]; then
    local m_commander m_model m_pane
    m_commander=$(_cw_pane_meta_field commander "$meta")
    m_model=$(_cw_pane_meta_field model "$meta")
    m_pane=$(_cw_pane_meta_field pane_id "$meta")
    [[ -n "$m_commander" ]] && commander="$m_commander"
    [[ -n "$m_model"     ]] && model="$m_model"
    pane="$m_pane"
    if [[ -z "$m_commander" || -z "$m_model" ]]; then
      _cw_pane_meta_fallback_warn
    fi
  else
    _cw_pane_meta_fallback_warn
  fi
  printf '%s\n%s\n%s\n' "$commander" "$model" "$pane"
}
