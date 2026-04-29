#!/usr/bin/env bash
# bin/consult-diff.sh — bucket findings into Agreed / Rex-only / Cody-only.
#
# Usage: bin/consult-diff.sh <consult-topic>
#
# Writes _consult/diff.md + rex_only_items.txt + cody_only_items.txt.
# Refuses if diff.md exists.

set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$PLUGIN_ROOT/lib/log.sh"
source "$PLUGIN_ROOT/lib/state.sh"
source "$PLUGIN_ROOT/lib/ipc.sh"
source "$PLUGIN_ROOT/lib/consult.sh"

[[ $# -eq 1 ]] || { echo "Usage: $0 <consult-topic>" >&2; exit 2; }
TOPIC="$1"
cw_consult_topic_validate "$TOPIC" || { log_error "invalid topic: $TOPIC"; exit 2; }

ART_DIR="$(cw_state_root)/state/$(cw_repo_hash)/$TOPIC/_consult"
[[ -d "$ART_DIR" ]] || { log_error "$ART_DIR not found"; exit 1; }
[[ ! -e "$ART_DIR/diff.md" ]] || { log_error "diff.md exists; reset to retry"; exit 1; }

REX_DIR=$(cw_trooper_dir rex codex "$TOPIC")
CODY_DIR=$(cw_trooper_dir cody claude "$TOPIC")
[[ -f "$REX_DIR/findings.md"  ]] || { log_error "rex findings.md missing"; exit 1; }
[[ -f "$CODY_DIR/findings.md" ]] || { log_error "cody findings.md missing"; exit 1; }

DIFF="$ART_DIR/diff.md"
cw_consult_diff "$REX_DIR/findings.md" "$CODY_DIR/findings.md" "$DIFF"

# Extract _only items for verify dispatch.
awk '/^## Rex-only/{f=1;next}  /^## /{f=0} f && /^- /{ sub(/^- /,""); print }'  "$DIFF" > "$ART_DIR/rex_only_items.txt"
awk '/^## Cody-only/{f=1;next} /^## /{f=0} f && /^- /{ sub(/^- /,""); print }'  "$DIFF" > "$ART_DIR/cody_only_items.txt"

log_info "[diff] wrote $DIFF + rex_only_items.txt ($(wc -l < "$ART_DIR/rex_only_items.txt") items) + cody_only_items.txt ($(wc -l < "$ART_DIR/cody_only_items.txt") items)"
