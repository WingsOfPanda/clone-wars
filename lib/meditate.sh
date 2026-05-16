# lib/meditate.sh — helpers for /clone-wars:meditate.
# Sourced. Depends on lib/log.sh, lib/state.sh, lib/consult.sh.
#
# Public:
#   cw_meditate_art_dir <topic>           — print absolute _meditate/ path
#   cw_meditate_classify_topic <topic>    — print ON or OFF (keyword scan)
#   cw_meditate_lit_keywords              — print the keyword list, one per line
#   cw_meditate_assert_topic <topic>      — require 'meditate-' prefix + validate; exits 2 on invalid

# cw_meditate_art_dir <topic>
# Same shape as cw_consult_art_dir but under /_meditate.
cw_meditate_art_dir() {
  printf '%s/_meditate\n' "$(cw_topic_state_dir "$1")"
}

# cw_meditate_assert_topic <topic>
# Require explicit 'meditate-' prefix + cw_consult_topic_validate.
# Strict-monotonic tightening vs the open-coded prefix-only check at callers
# (v0.41.0). Exits 2 on invalid topic.
cw_meditate_assert_topic() {
  [[ "$1" == meditate-* ]] \
    || { log_error "topic must start with 'meditate-': $1"; exit 2; }
  cw_consult_topic_validate "$1" || { log_error "invalid topic: $1"; exit 2; }
}

# cw_meditate_lit_keywords — case-insensitive keyword list.
# Tuned over time; classification logic lives in cw_meditate_classify_topic.
cw_meditate_lit_keywords() {
  cat <<'EOF'
loss
embedding
network
model
architecture
training
optimizer
scheduler
transformer
mamba
attention
regularization
augmentation
fine-tune
sota
state-of-the-art
benchmark
paper
arxiv
algorithm
inference
quantization
distillation
pruning
EOF
}

# cw_meditate_classify_topic <topic>
# Returns ON if any keyword from cw_meditate_lit_keywords appears case-
# insensitively as a whole-word match in <topic>; OFF otherwise.
# Whole-word match avoids "network" matching "networking conference" — we
# want the literal word, not a substring.
cw_meditate_classify_topic() {
  local topic="${1:-}"
  [[ -n "$topic" ]] || { echo "OFF"; return 0; }
  local lower; lower=$(printf '%s' "$topic" | tr '[:upper:]' '[:lower:]')
  local kw
  while IFS= read -r kw; do
    [[ -n "$kw" ]] || continue
    # Whole-word match: keyword bordered by non-word characters (or start/end).
    if [[ " $lower " =~ [^a-z0-9]"$kw"[^a-z0-9] ]]; then
      echo "ON"; return 0
    fi
  done < <(cw_meditate_lit_keywords)
  echo "OFF"
}

