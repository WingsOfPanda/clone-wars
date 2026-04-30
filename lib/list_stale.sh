# lib/list_stale.sh — v0.5.0 stale-state classifier for bin/list.sh.
# Sourced. No external deps beyond `stat` (GNU + BSD fallback) and `date`.

# _outbox_mtime <path> — print mtime seconds-since-epoch on stdout.
# Tries GNU `stat -c %Y` first; falls back to BSD `stat -f %m`. rc=1 if both fail.
_outbox_mtime() {
  local path="$1"
  stat -c %Y "$path" 2>/dev/null && return 0
  stat -f %m "$path" 2>/dev/null && return 0
  return 1
}

# cw_list_classify_stale <state> <outbox-path> <threshold-secs>
# If <state> is `working` AND outbox mtime is more than <threshold-secs> in the
# past, prints `stale`; otherwise prints <state> unchanged. Missing outbox or
# clock-skew (negative age) → state unchanged. Non-numeric threshold → warn to
# stderr, fall back to 180.
cw_list_classify_stale() {
  local state="$1" outbox="$2" threshold="${3:-180}"
  if [[ ! "$threshold" =~ ^[0-9]+$ ]]; then
    echo "cw_list_classify_stale: invalid threshold '$threshold'; using 180" >&2
    threshold=180
  fi
  if [[ "$state" != "working" ]]; then
    printf '%s\n' "$state"
    return 0
  fi
  if [[ ! -f "$outbox" ]]; then
    printf '%s\n' "$state"
    return 0
  fi
  local mtime now age
  mtime=$(_outbox_mtime "$outbox") || { printf '%s\n' "$state"; return 0; }
  now=$(date +%s)
  age=$(( now - mtime ))
  if (( age > 0 && age > threshold )); then
    printf '%s\n'  "stale"
  else
    printf '%s\n' "$state"
  fi
}
