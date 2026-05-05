# lib/consult.sh — /clone-wars:consult helpers (residual).
# Hub-mode helpers live in lib/consult-hub.sh; format validators in
# lib/consult-validators.sh; prompt builders in lib/consult-prompts.sh.
# This file sources them transitively so existing `source lib/consult.sh`
# callers continue to work.
# Depends on lib/state.sh, lib/ipc.sh, lib/contracts.sh.
# Callers MUST source lib/state.sh and lib/log.sh BEFORE sourcing this file.
# The split files call cw_atomic_write, cw_topic_state_dir, cw_trooper_dir,
# log_warn — none of which this shim sources itself.

# Resolve siblings via BASH_SOURCE — never CLAUDE_PLUGIN_ROOT, which can point
# at a sandbox lacking the lib/ tree (test fixtures override it for templates).
# Resolve through symlinks: Claude Code plugins are typically installed via
# ~/.claude/plugins/cache/<plugin>/<version>/lib/consult.sh symlinks. Plain
# dirname "${BASH_SOURCE[0]}" returns the symlink's parent dir, not the
# real file's, breaking the sibling source lookups below.
_CONSULT_BASH_SOURCE="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
_CONSULT_LIB_DIR="$(cd "$(dirname "$_CONSULT_BASH_SOURCE")" && pwd)"
unset _CONSULT_BASH_SOURCE
source "$_CONSULT_LIB_DIR/consult-hub.sh"
source "$_CONSULT_LIB_DIR/consult-validators.sh"
source "$_CONSULT_LIB_DIR/consult-prompts.sh"
unset _CONSULT_LIB_DIR

# cw_consult_topic_dir <topic> — absolute path to the consult topic dir.
# cw_consult_art_dir   <topic> — same, plus /_consult (where artifacts live).
cw_consult_topic_dir() { cw_topic_state_dir "$1"; }
cw_consult_art_dir()   { printf '%s/_consult\n' "$(cw_topic_state_dir "$1")"; }

cw_consult_findings_path() { printf '%s/findings.md\n' "$(cw_trooper_dir "$1" "$2" "$3")"; }
cw_consult_verify_path()   { printf '%s/verify.md\n'   "$(cw_trooper_dir "$1" "$2" "$3")"; }

# cw_consult_parse_claims <findings.md>
# Print one TAB-delimited line per claim: "<citation>\t<text>".
# Source format: `N. [<citation>] <text>` lines under `## Claims`.
# Lines without [citation] are silently skipped.
cw_consult_parse_claims() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  awk '
    /^## Claims/      { in_claims = 1; next }
    /^## /            { in_claims = 0 }
    in_claims && /^[0-9]+\. \[[^]]+\] / {
      match($0, /\[[^]]+\]/)
      cite = substr($0, RSTART + 1, RLENGTH - 2)
      text = substr($0, RSTART + RLENGTH + 1)
      sub(/^[ \t]+/, "", text)
      printf "%s\t%s\n", cite, text
    }
  ' "$file"
}

# cw_consult_findings_status <findings.md>
# Print one of: ok | empty | malformed | missing.
#   missing   — file absent
#   ok        — Claims block contains ≥1 parseable item
#   empty     — Claims block exists but has no body content (whitespace only)
#   malformed — Claims block has body content but 0 parseable items
cw_consult_findings_status() {
  local file="$1"
  [[ -f "$file" ]] || { echo missing; return 0; }
  local n_parsed n_lines
  n_parsed=$(cw_consult_parse_claims "$file" | wc -l)
  if (( n_parsed > 0 )); then echo ok; return 0; fi
  # Count non-blank lines under ## Claims (excluding the ## Claims heading).
  n_lines=$(awk '
    /^## Claims/   { in_claims = 1; next }
    /^## /         { in_claims = 0 }
    in_claims && NF { count++ }
    END            { print count + 0 }
  ' "$file")
  if (( n_lines > 0 )); then echo malformed; else echo empty; fi
}

# cw_consult_citation_overlaps <a> <b>
# Return 0 if two citations agree (cite the same logical source). Match rules
# (per spec):
#   File:  same path (after `./` strip) AND line ranges overlap (treat
#          single-line as Lo=Hi=N; treat path-only as covering all lines).
#   URL:   exact string equality (no trim).
#   runtime: exact string equality (no trim, includes `runtime:` prefix).
#   File vs URL/runtime: never overlap.
cw_consult_citation_overlaps() {
  local a="$1" b="$2"
  # Strip leading ./
  a="${a#./}"; b="${b#./}"
  # URL?
  if [[ "$a" == http* || "$b" == http* ]]; then
    [[ "$a" == "$b" ]]
    return $?
  fi
  # runtime?
  if [[ "$a" == runtime:* || "$b" == runtime:* ]]; then
    [[ "$a" == "$b" ]]
    return $?
  fi
  # Both are file citations.
  local a_path b_path a_lines b_lines
  a_path="${a%%:*}"; b_path="${b%%:*}"
  [[ "$a_path" == "$b_path" ]] || return 1
  if [[ "$a" == *:* ]]; then a_lines="${a#*:}"; else a_lines=""; fi
  if [[ "$b" == *:* ]]; then b_lines="${b#*:}"; else b_lines=""; fi
  # Path-only on either side covers all lines → overlap by default.
  [[ -z "$a_lines" || -z "$b_lines" ]] && return 0
  local a1 a2 b1 b2
  if [[ "$a_lines" == *-* ]]; then a1="${a_lines%-*}"; a2="${a_lines#*-}"; else a1="$a_lines"; a2="$a_lines"; fi
  if [[ "$b_lines" == *-* ]]; then b1="${b_lines%-*}"; b2="${b_lines#*-}"; else b1="$b_lines"; b2="$b_lines"; fi
  # Each endpoint must be all-digit (defensive — empty/dash/etc. → no overlap).
  [[ "$a1" =~ ^[0-9]+$ && "$a2" =~ ^[0-9]+$ && "$b1" =~ ^[0-9]+$ && "$b2" =~ ^[0-9]+$ ]] || return 1
  # 10# prefix forces base-10 — without it, leading-zero numerals like `008`
  # trigger bash's octal interpretation and abort the arithmetic.
  (( 10#$a1 <= 10#$b2 && 10#$b1 <= 10#$a2 ))
}

# cw_consult_diff <rex-findings> <cody-findings> <out-path>
# Bucket claims via cw_consult_citation_overlaps. Output format (always 3 sections):
#   ## Agreed
#   - [<rex-cite>] <rex-text> | <cody-text>
#   ## Rex-only
#   - [<rex-cite>] <rex-text>
#   ## Cody-only
#   - [<cody-cite>] <cody-text>
cw_consult_diff() {
  local rex="$1" cody="$2" out="$3"
  local -a rex_cites=() rex_texts=() cody_cites=() cody_texts=() rex_pair=() cody_matched=()
  local cite text
  while IFS=$'\t' read -r cite text; do
    rex_cites+=("$cite");   rex_texts+=("$text");   rex_pair+=(-1)
  done < <(cw_consult_parse_claims "$rex")
  while IFS=$'\t' read -r cite text; do
    cody_cites+=("$cite");  cody_texts+=("$text");  cody_matched+=(0)
  done < <(cw_consult_parse_claims "$cody")

  local n_rex="${#rex_cites[@]}" n_cody="${#cody_cites[@]}"
  local i j
  for ((i = 0; i < n_rex; i++)); do
    for ((j = 0; j < n_cody; j++)); do
      [[ "${cody_matched[$j]}" -eq 1 ]] && continue
      if cw_consult_citation_overlaps "${rex_cites[$i]}" "${cody_cites[$j]}"; then
        rex_pair[$i]=$j
        cody_matched[$j]=1
        break
      fi
    done
  done

  {
    printf '## Agreed\n'
    for ((i = 0; i < n_rex; i++)); do
      j="${rex_pair[$i]}"
      [[ "$j" -ge 0 ]] || continue
      printf -- '- [%s] %s | %s\n' "${rex_cites[$i]}" "${rex_texts[$i]}" "${cody_texts[$j]}"
    done
    printf '\n## Rex-only\n'
    for ((i = 0; i < n_rex; i++)); do
      [[ "${rex_pair[$i]}" -lt 0 ]] || continue
      printf -- '- [%s] %s\n' "${rex_cites[$i]}" "${rex_texts[$i]}"
    done
    printf '\n## Cody-only\n'
    for ((j = 0; j < n_cody; j++)); do
      [[ "${cody_matched[$j]}" -eq 0 ]] || continue
      printf -- '- [%s] %s\n' "${cody_cites[$j]}" "${cody_texts[$j]}"
    done
  } > "$out"
}

# cw_consult_parse_verdicts <verify.md>
# Print one TAB-delimited line per verdict: "<tag>\t<citation>\t<text>\t<evidence>".
# Source format under `## Verdicts`:
#   N. <TAG> [<citation>] <text>
#      <one-line evidence>            (optional indented continuation)
# Only AGREE / DISPUTE / UNCERTAIN tags are accepted; anything else (e.g.
# hallucinated UNKNOWN, MAYBE) is silently dropped — strict-by-design.
# If no continuation line is present, evidence is empty (the 4th column
# is still emitted so downstream awk -F'\t' sees a stable shape).
cw_consult_parse_verdicts() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  awk '
    function flush() {
      if (have) { printf "%s\t%s\t%s\t%s\n", tag, cite, text, evidence; have = 0 }
    }
    /^## Verdicts/ { in_v = 1; next }
    /^## /         { flush(); in_v = 0 }
    in_v && /^[0-9]+\. (AGREE|DISPUTE|UNCERTAIN) \[[^]]+\] / {
      flush()
      line = $0
      sub(/^[0-9]+\. /, "", line)
      tag = line; sub(/ .*$/, "", tag)
      rest = line; sub(/^[A-Z]+ /, "", rest)
      match(rest, /\[[^]]+\]/)
      cite = substr(rest, RSTART + 1, RLENGTH - 2)
      text = substr(rest, RSTART + RLENGTH + 1); sub(/^[ \t]+/, "", text)
      evidence = ""
      have = 1
      next
    }
    in_v && have && /^[ \t]+/ {
      ev = $0; sub(/^[ \t]+/, "", ev)
      if (evidence == "") evidence = ev; else evidence = evidence " " ev
      next
    }
    END { flush() }
  ' "$file"
}

# cw_consult_synthesize <topic> <diff.md> <adjudicated.md> \
#                       <rex-state-dir> <cody-state-dir> \
#                       <rex-findings-status> <cody-findings-status> \
#                       <rex-verify-status>   <cody-verify-status>   <out>
#
# *_findings_status ∈ {ok, empty, malformed, missing}
# *_verify_status   ∈ {ok, empty, missing, timeout, error, send-failed, skipped}
#   skipped = no work was needed (other side had no _ONLY items)
#   Banners fire on any status except ok and skipped.
#
# Emits the 6-section synthesis with banners when any status is not ok/skipped.
cw_consult_synthesize() {
  local topic="$1" diff="$2" adj="$3" rex_dir="$4" cody_dir="$5"
  local rex_fs="$6" cody_fs="$7" rex_vs="$8" cody_vs="$9" out="${10}"

  {
    printf '# Consultation: %s\n\n' "$topic"

    # Banners
    case "$rex_fs"  in malformed|missing|empty) printf '> NOTE: REX findings.md %s — diff/synthesis ran on best-effort parse.\n\n' "$rex_fs" ;; esac
    case "$cody_fs" in malformed|missing|empty) printf '> NOTE: CODY findings.md %s — diff/synthesis ran on best-effort parse.\n\n' "$cody_fs" ;; esac
    case "$rex_vs"  in timeout|error|send-failed|missing|empty) printf '> NOTE: REX verify dispatch %s — partial cross-verification; some Cody-only items not graded.\n\n' "$rex_vs" ;; esac
    case "$cody_vs" in timeout|error|send-failed|missing|empty) printf '> NOTE: CODY verify dispatch %s — partial cross-verification; some Rex-only items not graded.\n\n' "$cody_vs" ;; esac

    printf '## Agreed findings (both raised independently)\n'
    awk '/^## Agreed/{f=1;next} /^## /{f=0} f' "$diff"
    printf '\n'

    awk '
      /^## Cross-verified/{f=1; print; next}
      /^## Adjudicated/   {f=1; print; next}
      /^## Contested/     {f=1; print; next}
      /^## Not-verified/  {f=1; print; next}
      /^## /              {f=0}
      f
    ' "$adj"
    printf '\n'

    printf '## Trooper artifacts\n'
    printf -- '- REX research:  %s/findings.md\n' "$rex_dir"
    printf -- '- REX verify:    %s/verify.md\n'   "$rex_dir"
    printf -- '- CODY research: %s/findings.md\n' "$cody_dir"
    printf -- '- CODY verify:   %s/verify.md\n'   "$cody_dir"
  } > "$out"
}

# cw_consult_topic_validate <topic>
# Return 0 if the topic is a safe consult topic name; 1 otherwise.
# Rules:
#   - Must start with `consult-`
#   - Allowed chars: [A-Za-z0-9._-]+
#   - No leading dot or hyphen, no slash, no `..`
# Used at the top of every sub-script that takes a <topic> arg.
cw_consult_topic_validate() {
  local topic="$1"
  [[ -n "$topic" ]] || return 1
  [[ "$topic" == consult-* ]] || return 1
  [[ "$topic" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
  [[ "$topic" != .* && "$topic" != -* ]] || return 1
  [[ "$topic" != *..* ]] || return 1
  return 0
}

# cw_consult_assert_topic <topic>      — log_error + exit 2 on invalid topic.
# cw_consult_assert_commander <name>   — log_error + exit 2 on invalid commander.
# Each is the one-line standard prelude in every bin/consult-*.sh; centralising
# them keeps the regex / error wording in a single place.
cw_consult_assert_topic() {
  cw_consult_topic_validate "$1" || { log_error "invalid topic: $1"; exit 2; }
}
cw_consult_assert_commander() {
  [[ "$1" =~ ^[a-z0-9_-]+$ ]] || { log_error "invalid commander: $1"; exit 2; }
}

# cw_consult_status_load <file>
# Source a per-commander state file (KEY=VAL lines) into the calling shell.
# Missing file is a silent no-op (rc=0, no vars set). The file is written
# exclusively by sub-scripts (research-send/wait, verify-send/wait), never by
# troopers, so plain `source` is acceptable here — see spec Migration §
# "cw_consult_status_load design note" for the threat-model rationale.
cw_consult_status_load() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  # shellcheck disable=SC1090
  source "$file"
}

# cw_consult_write_adjudicated <out> <rex-verify-md> <cody-verify-md> \
#                              <rex-only-items> <cody-only-items> \
#                              <rex-vs> <cody-vs>
# Compose the adjudicated-draft.md content from the four state inputs.
# Sections: Cross-verified, Adjudicated (PENDING list), Contested, Not-verified.
cw_consult_write_adjudicated() {
  local out="$1" rex_v="$2" cody_v="$3" rex_only="$4" cody_only="$5"
  local rex_vs="$6" cody_vs="$7"
  {
    printf '## Cross-verified\n'
    [[ -f "$cody_v" ]] && cw_consult_parse_verdicts "$cody_v" \
      | awk -F'\t' '$1 == "AGREE" { printf "- [%s] %s — CODY confirmed: %s\n", $2, $3, ($4 != "" ? $4 : $3) }'
    [[ -f "$rex_v" ]] && cw_consult_parse_verdicts "$rex_v" \
      | awk -F'\t' '$1 == "AGREE" { printf "- [%s] %s — REX confirmed: %s\n", $2, $3, ($4 != "" ? $4 : $3) }'

    printf '\n## Adjudicated\n'
    printf '<!-- Master Yoda: read each cited source for every "PENDING" line below; rewrite the prefix to CONFIRMED, REFUTED, or move to ## Contested. consult-synthesize.sh refuses to finalize while any PENDING remains. -->\n'
    [[ -f "$cody_v" ]] && cw_consult_parse_verdicts "$cody_v" \
      | awk -F'\t' '$1 != "AGREE" { printf "- PENDING: [%s] %s — CODY %s: %s\n", $2, $3, $1, ($4 != "" ? $4 : $3) }'
    [[ -f "$rex_v" ]] && cw_consult_parse_verdicts "$rex_v" \
      | awk -F'\t' '$1 != "AGREE" { printf "- PENDING: [%s] %s — REX %s: %s\n", $2, $3, $1, ($4 != "" ? $4 : $3) }'

    printf '\n## Contested\n'
    printf '<!-- Master Yoda: move CONTESTED items here from Adjudicated. Items in this section ship in synthesis as unresolved. -->\n'

    printf '\n## Not-verified\n'
    if [[ "$rex_vs" != "ok" && "$rex_vs" != "skipped" && -s "$cody_only" ]]; then
      awk -v vs="$rex_vs" '{ printf "- %s — REX verify dispatch %s\n", $0, vs }' "$cody_only"
    fi
    if [[ "$cody_vs" != "ok" && "$cody_vs" != "skipped" && -s "$rex_only" ]]; then
      awk -v vs="$cody_vs" '{ printf "- %s — CODY verify dispatch %s\n", $0, vs }' "$rex_only"
    fi
  } > "$out"
}

# cw_consult_classify_topic <topic-text>
# Echo one of: brainstorming | systematic-debugging | none.
# Brainstorming wins ties. Triggers case-insensitive, word-boundary anchored.
# "design"/"structure"/"approach" alone do NOT trigger.
cw_consult_classify_topic() {
  local topic="$1"
  local lower
  lower=$(printf '%s' "$topic" | tr '[:upper:]' '[:lower:]')

  # Word-boundary fence: surround triggers with space/punctuation boundaries.
  # Bash =~ POSIX ERE has no portable \b — replace punctuation with spaces.
  local fenced=" $lower "
  fenced=${fenced//[[:punct:]]/ }
  fenced=$(printf '%s' "$fenced" | tr -s ' ')

  local brain_re='( design patterns? | how should | best way | what s the best way | what is the best way | decide between )'
  local debug_re='( why | broken | failing | regressions? | edge cases? | bugs? | doesn t work | does not work )'

  if [[ "$fenced" =~ $brain_re ]]; then
    printf 'brainstorming\n'
  elif [[ "$fenced" =~ $debug_re ]]; then
    printf 'systematic-debugging\n'
  else
    printf 'none\n'
  fi
}

# cw_consult_skill_hint_append <skill-txt-path> <base-prompt>
# Echo base-prompt followed by the skill-hint content (if any).
# Missing skill.txt or skill=none → base-prompt unchanged.
# CW_CONSULT_SKILL_OVERRIDE=none in env forces 'none' (kill-switch).
# PLUGIN_ROOT (or CLAUDE_PLUGIN_ROOT) MUST be set — fail loud, not silent.
cw_consult_skill_hint_append() {
  local skill_path="$1"
  local base="$2"
  local plugin_root="${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}"
  [[ -n "$plugin_root" ]] \
    || { echo "cw_consult_skill_hint_append: PLUGIN_ROOT/CLAUDE_PLUGIN_ROOT unset" >&2; return 2; }

  local skill="none"
  [[ -f "$skill_path" ]] && skill=$(tr -d '[:space:]' < "$skill_path")
  # Env-var kill-switch.
  [[ "${CW_CONSULT_SKILL_OVERRIDE:-}" == "none" ]] && skill="none"

  case "$skill" in
    brainstorming|systematic-debugging) : ;;
    *) printf '%s' "$base"; return 0 ;;
  esac
  local hint_file="$plugin_root/config/skill-hints/$skill.md"
  [[ -f "$hint_file" ]] || { printf '%s' "$base"; return 0; }
  printf '%s\n\n---\n\n' "$base"
  cat "$hint_file"
}

# cw_consult_question_payload_write <file> <text> <options-pipe-or-empty> <phase>
# Atomic write (tmp + mv) via cw_atomic_write. Multi-line TEXT is percent-encoded via %0A.
cw_consult_question_payload_write() {
  local file="$1" text="$2" options="$3" phase="$4"
  local encoded=${text//$'\n'/%0A}
  {
    printf 'TEXT=%s\n'     "$encoded"
    [[ -n "$options" ]] && printf 'OPTIONS=%s\n' "$options"
    printf 'PHASE=%s\n'    "$phase"
    printf 'ASKED_AT=%s\n' "$(date +%s)"
  } | cw_atomic_write "$file"
}

# cw_consult_question_payload_read <file> <key>
# Echo the value for KEY. For TEXT/OPTIONS, decodes 6 percent-encodings:
#   %0A → newline    %09 → tab    %22 → "    %5C → \    %2C → ,    %25 → %
# %25 LAST so nested encodings (%2522) round-trip correctly.
cw_consult_question_payload_read() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 1
  local raw
  raw=$(awk -F= -v k="$key" '$1==k { sub(/^[^=]*=/, ""); print; exit }' "$file")
  case "$key" in
    TEXT|OPTIONS)
      raw=${raw//%0A/$'\n'}
      raw=${raw//%09/$'\t'}
      raw=${raw//%22/\"}
      raw=${raw//%5C/\\}
      raw=${raw//%2C/,}
      raw=${raw//%25/%}     # literal-percent escape — must be LAST
      ;;
  esac
  printf '%s' "$raw"
}

# cw_consult_question_validate_line <json-line>
# rc=0 iff line is a parseable {"event":"question",...} with non-empty text,
# no JSON escapes (\", \\, \n, \t), and no non-ASCII bytes.
# Used by wait-script to gate FS=question vs FS=failed.
# Fail-closed against: missing text, escaped quotes, backslashes, non-ASCII,
# un-encoded commas in options.
cw_consult_question_validate_line() {
  local line="$1"
  [[ "$line" == *'"event":"question"'* ]] || return 1
  # Reject anything outside printable ASCII (0x20..0x7E) — NUL-free pattern.
  if LC_ALL=C printf '%s' "$line" | LC_ALL=C grep -q '[^ -~]'; then
    return 1
  fi
  # Require text field, non-empty, no escaped quote or backslash.
  printf '%s' "$line" | grep -qE '"text":"[^"\\]+"' || return 1
  # If options array exists, every option must contain no literal `,`
  # (counts of `,` must equal counts of `","` separators).
  if printf '%s' "$line" | grep -q '"options":\['; then
    local raw_opts sep_count comma_count
    raw_opts=$(printf '%s' "$line" | sed -n 's/.*"options":\[\([^]]*\)\].*/\1/p')
    sep_count=$(printf '%s' "$raw_opts" | grep -o '","' | wc -l | tr -d ' ')
    comma_count=$(printf '%s' "$raw_opts" | tr -cd ',' | wc -c | tr -d ' ')
    [[ "$sep_count" -eq "$comma_count" ]] || return 1
  fi
  return 0
}

# cw_consult_question_extract_to_payload <json-line> <payload-path> <phase>
# Validates + extracts the question event into the payload file format
# expected by cw_consult_question_payload_read. rc=0 on success, rc=1 on
# validation/parse failure (no payload written).
cw_consult_question_extract_to_payload() {
  local line="$1" path="$2" phase="$3"
  cw_consult_question_validate_line "$line" || return 1
  local text raw_opts opts
  text=$(printf '%s' "$line" | sed -n 's/.*"text":"\([^"]*\)".*/\1/p')
  [[ -n "$text" ]] || return 1
  raw_opts=$(printf '%s' "$line" | sed -n 's/.*"options":\[\([^]]*\)\].*/\1/p')
  # Split on `","` boundaries (validator forbade literal `,` and `"`).
  opts=$(printf '%s' "$raw_opts" | sed 's/^"//; s/"$//; s/","/|/g')
  cw_consult_question_payload_write "$path" "$text" "$opts" "$phase"
}

# cw_consult_outbox_match_endbyte <outbox-path> <start-offset> <matched-line>
# Returns OFFSET + bytes-up-to-and-including the matched line. Used by
# wait-script to compute the post-question byte cursor without racing
# against `wc -c` (which would skip events written between match and read).
# `local LC_ALL=C` scopes byte-mode to entire function so ${#line} is bytes.
cw_consult_outbox_match_endbyte() {
  local LC_ALL=C
  local outbox="$1" start="$2" matched="$3"
  [[ -f "$outbox" ]] || return 1
  local pos=$start
  local line
  while IFS= read -r line; do
    pos=$(( pos + ${#line} + 1 ))   # +1 for newline read -r stripped
    if [[ "$line" == "$matched" ]]; then
      printf '%s\n' "$pos"
      return 0
    fi
  done < <(tail -c "+$(( start + 1 ))" "$outbox")
  return 1
}

# ============================================================================
# Design-doc mode helpers
# ============================================================================

# cw_consult_design_doc_filename <topic-slug> [<hash6>]
# Emits docs/clone-wars/specs/YYYY-MM-DD-<slug>[-<hash6>]-design.md.
# Uses ${CW_TEST_DATE:-$(date +%Y-%m-%d)} for testability.
# Rejects empty slug or slug outside [a-z0-9-] with rc=2.
# Optional <hash6> (6 lowercase hex chars) disambiguates topics whose first
# 20 slug chars collide; reject malformed hash with rc=2.
cw_consult_design_doc_filename() {
  local slug="${1:-}" hash="${2:-}"
  [[ -n "$slug" ]] || { echo "cw_consult_design_doc_filename: empty slug" >&2; return 2; }
  [[ "$slug" =~ ^[a-z0-9-]+$ ]] || {
    echo "cw_consult_design_doc_filename: slug '$slug' has invalid chars (need [a-z0-9-])" >&2
    return 2
  }
  if [[ -n "$hash" ]]; then
    [[ "$hash" =~ ^[0-9a-f]{6}$ ]] || {
      echo "cw_consult_design_doc_filename: hash '$hash' must be exactly 6 lowercase hex chars" >&2
      return 2
    }
  fi
  local date_str="${CW_TEST_DATE:-$(date +%Y-%m-%d)}"
  if [[ -n "$hash" ]]; then
    printf 'docs/clone-wars/specs/%s-%s-%s-design.md\n' "$date_str" "$slug" "$hash"
  else
    printf 'docs/clone-wars/specs/%s-%s-design.md\n' "$date_str" "$slug"
  fi
}

# cw_consult_design_doc_assemble <section-dir> <output-path> <title> [<topic-text>] [<synthesis-path>] [<targets-dir>]
# Concatenates 5 section files into a single design doc with a standard
# header. Missing sections get a _(skipped)_ placeholder body.
#
# Optional 4th and 5th args override title and goal sources:
#   <topic-text>      — full user topic from _consult/topic.txt; if non-empty,
#                       Title-Cased and used as H1 in preference to <title>
#                       (which is derived from the 20-char-truncated slug).
#   <synthesis-path>  — path to _consult/synthesis.md; first non-empty line
#                       under "## Agreed findings" (then "## Cross-verified")
#                       becomes **Goal:** (200-char trunc); falls back to
#                       architecture.md head -n1.
#   <targets-dir>     — path to the _consult/ art-dir; when set AND
#                       <targets-dir>/targets.txt is non-empty, hub-mode
#                       output is emitted: a Target Hub(s)/Sub-Project(s)
#                       header pair after the H1, plus Acceptance Tests,
#                       Execution DAG, and Cross-Repo Dependencies sections
#                       (sourced from acceptance-tests.md, dag.md,
#                       xrepo-deps.md). Single-repo path (empty 6th arg or
#                       missing/empty targets.txt) is byte-equal to v0.10.
cw_consult_design_doc_assemble() {
  local section_dir="$1" out="$2" title="$3"
  local topic_text="${4:-}" synthesis_path="${5:-}" targets_dir="${6:-}"
  [[ -d "$section_dir" ]] || { echo "cw_consult_design_doc_assemble: missing $section_dir" >&2; return 1; }
  [[ -n "$title" ]] || { echo "cw_consult_design_doc_assemble: empty title" >&2; return 2; }

  # Prefer topic-text-derived title when provided.
  if [[ -n "$topic_text" ]]; then
    title=$(printf '%s' "$topic_text" | tr -s ' ' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))} 1')
  fi

  # Header — pull goal/arch/tech-stack from architecture.md if present.
  local goal="(see Architecture section)" arch_line="(see Architecture section)" tech_block=""

  # Prefer first non-empty line under "## Agreed findings" then
  # "## Cross-verified" in synthesis.md when caller supplied a path.
  if [[ -n "$synthesis_path" && -f "$synthesis_path" ]]; then
    local syn_goal
    syn_goal=$(awk '
      /^## Agreed findings/ {flag=1; next}
      flag && /^## / {exit}
      flag && NF>0 {sub(/^[[:space:]]*-[[:space:]]*/, ""); print; exit}
    ' "$synthesis_path")
    if [[ -z "$syn_goal" ]]; then
      syn_goal=$(awk '
        /^## Cross-verified/ {flag=1; next}
        flag && /^## / {exit}
        flag && NF>0 {sub(/^[[:space:]]*-[[:space:]]*/, ""); print; exit}
      ' "$synthesis_path")
    fi
    [[ -n "$syn_goal" ]] && goal="${syn_goal:0:200}"
  fi

  if [[ -f "$section_dir/architecture.md" ]]; then
    # Only fall back to architecture.md head if synthesis didn't set goal.
    [[ "$goal" == "(see Architecture section)" ]] && goal=$(head -n1 "$section_dir/architecture.md")
    # Architecture paragraph: lines >=3, until any H2 heading or blank line.
    # Match any H2 (not specifically "## Tech Stack") so an architecture.md
    # whose third line is the next H2 (no body paragraph) falls back cleanly.
    arch_line=$(awk '
      NR<3 {next}
      /^## / {exit}
      NF==0 {exit}
      {print}
    ' "$section_dir/architecture.md" | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')
    [[ -n "$arch_line" ]] || arch_line="(see Architecture section)"
    # Tech Stack block: lines under "## Tech Stack" until next ## heading or EOF.
    tech_block=$(awk '/^## Tech Stack$/{flag=1; next} /^## /{flag=0} flag' "$section_dir/architecture.md")
  fi

  # Hub-mode header pair (when targets.txt exists and is non-empty).
  local header_pair=""
  local hub_mode=0
  if [[ -n "$targets_dir" && -s "$targets_dir/targets.txt" ]]; then
    hub_mode=1
    header_pair=$(cw_consult_targets_to_header_pair "$targets_dir")
  fi

  {
    printf '# %s Design\n\n' "$title"
    if (( hub_mode == 1 )); then
      printf '%s\n\n' "$header_pair"
    fi
    printf '**Goal:** %s\n\n' "$goal"
    printf '**Architecture:** %s\n\n' "$arch_line"
    printf '**Tech Stack:**\n'
    if [[ -n "$tech_block" ]]; then
      printf '%s\n' "$tech_block"
    else
      printf '%s\n' '- (see Components section)'
    fi
    printf '\n---\n\n'

    # Core 4 sections — same in both modes.
    local pair key heading
    for pair in 'architecture|Architecture' 'components|Components' 'data-flow|Data Flow' 'error-handling|Error Handling'; do
      key="${pair%%|*}"
      heading="${pair##*|}"
      printf '## %s\n\n' "$heading"
      if [[ -f "$section_dir/$key.md" ]]; then
        cat "$section_dir/$key.md"
        printf '\n'
      else
        printf '_(skipped)_\n\n'
      fi
    done

    # Tail sections: hub-mode emits Acceptance Tests + Execution DAG +
    # Cross-Repo Dependencies; single-repo emits Testing.
    local -a tail_pairs
    if (( hub_mode == 1 )); then
      tail_pairs=('acceptance-tests|Acceptance Tests' 'dag|Execution DAG' 'xrepo-deps|Cross-Repo Dependencies')
    else
      tail_pairs=('testing|Testing')
    fi
    for pair in "${tail_pairs[@]}"; do
      key="${pair%%|*}"
      heading="${pair##*|}"
      printf '## %s\n\n' "$heading"
      if [[ -f "$section_dir/$key.md" ]]; then
        cat "$section_dir/$key.md"
        printf '\n'
      else
        printf '_(skipped)_\n\n'
      fi
    done
  } > "$out"
}

# cw_consult_design_doc_self_review <doc-path>
# Scans for placeholder strings (TBD/TODO/FIXME word-boundaried, bare three-dot
# ellipsis surrounded by alpha or whitespace).
# Reports each match as <path>:<lineno>: <line> to stderr.
# rc=0 if clean, rc=1 if any match, rc=2 if file missing.
cw_consult_design_doc_self_review() {
  local doc="$1"
  [[ -f "$doc" ]] || { echo "cw_consult_design_doc_self_review: $doc not found" >&2; return 2; }
  local found=0
  if grep -nE '\b(TBD|TODO|FIXME)\b' "$doc" >&2; then
    found=1
  fi
  if grep -nE '([[:alpha:]]|[[:space:]])\.\.\.([[:alpha:]]|[[:space:]]|$)' "$doc" >&2; then
    found=1
  fi
  return $found
}

# cw_consult_design_doc_resume_state <design-doc-dir>
# Lists approved section keys (one per line, basename without .md) on stdout.
# Excludes drilldown-* and zero-byte files. Missing dir → empty stdout, rc=0.
cw_consult_design_doc_resume_state() {
  local dd="$1"
  [[ -d "$dd" ]] || return 0
  local f base
  shopt -s nullglob
  for f in "$dd"/*.md; do
    [[ -s "$f" ]] || continue
    base=$(basename "$f" .md)
    [[ "$base" == drilldown-* ]] && continue
    printf '%s\n' "$base"
  done
  shopt -u nullglob
}
