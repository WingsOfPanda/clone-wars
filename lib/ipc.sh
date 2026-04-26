# lib/ipc.sh — file-based IPC between conductor and troopers.
# Sourced. Depends on lib/state.sh.
#
# State layout (per docs/DESIGN.md §State directory layout):
#   $CLONE_WARS_HOME/state/<repo-hash>/<topic>/<commander>-<model>/
#     ├── identity.md      — system prompt injected at spawn
#     ├── inbox.md         — conductor writes; trooper reads on nudge
#     ├── outbox.jsonl     — trooper appends; conductor tails
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
# Write identity.md by substituting {{vars}} in $CLONE_WARS_HOME/identity-template.md
# (or the shipped default if the per-machine copy isn't there yet). Appends a
# trailing "first action" instruction so the trooper emits {ready} immediately.
cw_identity_write() {
  local commander="$1" model="$2" topic="$3"
  local dir identity tmpl outbox
  dir=$(cw_trooper_dir "$commander" "$model" "$topic")
  identity="$dir/identity.md"
  outbox="$dir/outbox.jsonl"
  tmpl="$(cw_state_root)/identity-template.md"
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

Append exactly this single line to $outbox:

\`{"event":"ready","ts":"$(date -u +"%Y-%m-%dT%H:%M:%SZ")","commander":"$commander","model":"$model"}\`

Use a shell command: \`echo '{"event":"ready","ts":"...","commander":"$commander","model":"$model"}' >> $outbox\`

Then stop and wait. I will send another instruction asking you to read your inbox.
EOF
}

# cw_inbox_write <commander> <model> <topic> <task_text>
# Overwrite inbox.md with the task, terminating with the END_OF_INSTRUCTION
# sentinel so the trooper knows the message is complete.
cw_inbox_write() {
  local commander="$1" model="$2" topic="$3" task="$4"
  local inbox outbox
  inbox=$(cw_inbox_path "$commander" "$model" "$topic")
  outbox=$(cw_outbox_path "$commander" "$model" "$topic")
  cat > "$inbox" <<EOF
$task

When done, append a single JSONL line to $outbox:

\`{"event":"done","summary":"<one-line summary>","ts":"<iso-timestamp>"}\`

END_OF_INSTRUCTION
EOF
}

# cw_outbox_wait <commander> <model> <topic> <event> <timeout-seconds>
# Poll the outbox for the named event. Print the matching JSON line to stdout
# if found within timeout (return 0). Print nothing and return 1 on timeout.
cw_outbox_wait() {
  local commander="$1" model="$2" topic="$3" event="$4" timeout="$5"
  local outbox; outbox=$(cw_outbox_path "$commander" "$model" "$topic")
  local i
  for i in $(seq 1 "$timeout"); do
    if grep -q "\"event\":\"$event\"" "$outbox" 2>/dev/null; then
      grep "\"event\":\"$event\"" "$outbox" | tail -n1
      return 0
    fi
    sleep 1
  done
  return 1
}

# cw_outbox_dump <commander> <model> <topic>
# Print the whole outbox.jsonl. Used by collect/list for diagnostics.
cw_outbox_dump() {
  local outbox; outbox=$(cw_outbox_path "$1" "$2" "$3")
  [[ -f "$outbox" ]] && cat "$outbox"
}

# cw_pane_meta_write <commander> <model> <topic> <pane_id>
# Write pane.json so /clone-wars:list and orphan detection can find the pane.
cw_pane_meta_write() {
  local commander="$1" model="$2" topic="$3" pane="$4"
  local meta; meta=$(cw_pane_meta_path "$commander" "$model" "$topic")
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  printf '{"pane_id":"%s","spawned_at":"%s"}\n' "$pane" "$ts" > "$meta"
}

# cw_pane_meta_read <commander> <model> <topic>
# Print the pane_id from pane.json, or empty if missing.
cw_pane_meta_read() {
  local meta; meta=$(cw_pane_meta_path "$1" "$2" "$3")
  [[ -f "$meta" ]] || return 1
  awk -F'"' '/"pane_id"/ {print $4; exit}' "$meta"
}
