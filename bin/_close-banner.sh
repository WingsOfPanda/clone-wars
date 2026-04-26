#!/usr/bin/env bash
# bin/_close-banner.sh — internal helper. Appends a graceful-shutdown
# banner + 8s countdown in the trooper's color so the user has time to
# register that the pane is closing intentionally.
#
# Invoked from the cleanup trap of tracer/runtime scripts via:
#   tmux respawn-pane -k -t <pane_id> \
#     "cat <snap>; <plugin_root>/bin/_close-banner.sh <label> <color>; rm <snap>"
#
# Args:
#   $1  label  — the trooper's full label, e.g. "captain-rex:codex:auth-review"
#   $2  color  — tmux color spec ("colour110") or bare number; empty = no color
#
# When this script exits, the pane closes naturally (tmux remain-on-exit=off).

LABEL="${1:-trooper}"
COLOR="${2:-}"

# Build ANSI escapes from the tmux color spec.
if [[ "$COLOR" =~ ^colour([0-9]+)$ ]]; then
  C=$'\e[38;5;'"${BASH_REMATCH[1]}"'m'
elif [[ "$COLOR" =~ ^[0-9]+$ ]]; then
  C=$'\e[38;5;'"$COLOR"'m'
else
  C=''
fi
R=$'\e[0m'   # reset
B=$'\e[1m'   # bold

printf '\n'
printf '  %s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "$C" "$R"
printf '  %s%s%s%s\n'                                       "$B" "$C" "$LABEL" "$R"
printf '  %sMISSION ACCOMPLISHED — pane closing%s\n'        "$C" "$R"
printf '  %s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "$C" "$R"
printf '\n'

for i in 8 7 6 5 4 3 2 1; do
  printf '  %sClosing in %d second%s...%s\r' "$C" "$i" "$([[ "$i" -eq 1 ]] || echo s)" "$R"
  sleep 1
done

printf '  %sClosed.                          %s\n' "$C" "$R"
sleep 0.3
