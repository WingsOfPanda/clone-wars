#!/usr/bin/env bash
# bin/inbox-ack.sh — v0.50.0 trooper-callable helper.
# Reads inbox.md, computes sha256 + extracts last non-blank line,
# appends {"event":"ack","inbox_sha256":...,"inbox_tail":...,"ts":...}
# to the trooper's outbox.
#
# Usage: bin/inbox-ack.sh <topic> <commander> <inbox-path>
#
# rc=0 on success, rc=1 if inbox missing/unreadable.

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck disable=SC1091
source "$PLUGIN_ROOT/lib/log.sh"
# shellcheck disable=SC1091
source "$PLUGIN_ROOT/lib/state.sh"
# shellcheck disable=SC1091
source "$PLUGIN_ROOT/lib/ipc.sh"

[[ $# -eq 3 ]] || { echo "Usage: $0 <topic> <commander> <inbox-path>" >&2; exit 2; }
TOPIC="$1"
COMMANDER="$2"
INBOX="$3"

[[ -f "$INBOX" && -r "$INBOX" ]] || { echo "inbox-ack: $INBOX missing or unreadable" >&2; exit 1; }

PROVIDER="${CW_TROOPER_PROVIDER:-codex}"
OUTBOX=$(cw_outbox_path "$COMMANDER" "$PROVIDER" "$TOPIC")
[[ -n "$OUTBOX" ]] || { echo "inbox-ack: failed to resolve outbox path" >&2; exit 1; }

SHA=$(sha256sum < "$INBOX" | cut -d' ' -f1)
TAIL=$(grep -v '^[[:space:]]*$' "$INBOX" | tail -n1)
# JSON-escape backslash then quote.
TAIL_J="${TAIL//\\/\\\\}"
TAIL_J="${TAIL_J//\"/\\\"}"

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '{"event":"ack","inbox_sha256":"%s","inbox_tail":"%s","ts":"%s"}\n' \
  "$SHA" "$TAIL_J" "$TS" >> "$OUTBOX"
exit 0
