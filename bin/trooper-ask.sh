#!/usr/bin/env bash
# bin/trooper-ask.sh — v0.50.0 trooper-callable helper.
# Appends a {"event":"question",...} JSONL line to the trooper's outbox.
#
# Usage:
#   bin/trooper-ask.sh <topic> <commander> <text>
#   bin/trooper-ask.sh <topic> <commander> <text> <kind> <value>
#
# <kind> is one of: path, git, env, cmd, test.
# When <kind>/<value> are omitted, the question event has no `claim`
# field — directive routes it straight to the user.

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck disable=SC1091
source "$PLUGIN_ROOT/lib/log.sh"
# shellcheck disable=SC1091
source "$PLUGIN_ROOT/lib/state.sh"
# shellcheck disable=SC1091
source "$PLUGIN_ROOT/lib/ipc.sh"

if [[ $# -ne 3 && $# -ne 5 ]]; then
  echo "Usage: $0 <topic> <commander> <text> [<kind> <value>]" >&2
  exit 2
fi

TOPIC="$1"
COMMANDER="$2"
TEXT="$3"
KIND="${4:-}"
VALUE="${5:-}"

if [[ -n "$KIND" ]]; then
  case "$KIND" in
    path|git|env|cmd|test) ;;
    *)
      echo "trooper-ask: invalid kind '$KIND' (need path|git|env|cmd|test)" >&2
      exit 2
      ;;
  esac
  [[ -n "$VALUE" ]] || { echo "trooper-ask: empty <value>" >&2; exit 2; }
fi

# Resolve the outbox path the same way other trooper-side scripts do.
# cw_outbox_path is provided by lib/ipc.sh and takes (commander, model, topic).
# Provider defaults to codex; deploy is codex-only, consult uses cw_outbox_path
# via its own scripts so for portability this helper also accepts a
# CW_TROOPER_PROVIDER override.
PROVIDER="${CW_TROOPER_PROVIDER:-codex}"
OUTBOX=$(cw_outbox_path "$COMMANDER" "$PROVIDER" "$TOPIC")
[[ -n "$OUTBOX" ]] || { echo "trooper-ask: failed to resolve outbox path" >&2; exit 1; }

# JSON-escape the text and value (escape backslash first, then quote).
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}
TEXT_J=$(json_escape "$TEXT")

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if [[ -n "$KIND" ]]; then
  VAL_J=$(json_escape "$VALUE")
  printf '{"event":"question","text":"%s","claim":{"kind":"%s","value":"%s"},"ts":"%s"}\n' \
    "$TEXT_J" "$KIND" "$VAL_J" "$TS" >> "$OUTBOX"
else
  printf '{"event":"question","text":"%s","ts":"%s"}\n' \
    "$TEXT_J" "$TS" >> "$OUTBOX"
fi
exit 0
