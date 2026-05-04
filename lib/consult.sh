# lib/consult.sh — /clone-wars:consult helpers.
# Sourced. Depends on lib/state.sh, lib/ipc.sh, lib/contracts.sh.

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

# cw_consult_build_verify_prompt <items_file> <write_to>
# Build the verify-round prompt body. Reads <items_file> (one `[cite] text` per
# line) and emits a self-contained instruction, terminated by END_OF_INSTRUCTION.
cw_consult_build_verify_prompt() {
  local items_file="$1" write_to="$2"
  local items
  items=$(nl -ba -w1 -s'. ' "$items_file")
  cw_consult_load_prompt consult/verify.md "ITEMS=$items" "WRITE_TO=$write_to"
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

# cw_consult_build_research_prompt <topic> <write_to>
# Build the research-round prompt body. Emits a self-contained instruction
# with the required Findings structure and citation rules, terminated by
# END_OF_INSTRUCTION.
cw_consult_build_research_prompt() {
  local topic="$1" write_to="$2"
  cw_consult_load_prompt consult/research.md "TOPIC=$topic" "WRITE_TO=$write_to"
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

# cw_consult_design_doc_assemble <section-dir> <output-path> <title> [<topic-text>] [<synthesis-path>]
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
cw_consult_design_doc_assemble() {
  local section_dir="$1" out="$2" title="$3"
  local topic_text="${4:-}" synthesis_path="${5:-}"
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

  {
    printf '# %s Design\n\n' "$title"
    printf '**Goal:** %s\n\n' "$goal"
    printf '**Architecture:** %s\n\n' "$arch_line"
    printf '**Tech Stack:**\n'
    if [[ -n "$tech_block" ]]; then
      printf '%s\n' "$tech_block"
    else
      printf '%s\n' '- (see Components section)'
    fi
    printf '\n---\n\n'

    local pair key heading
    for pair in 'architecture|Architecture' 'components|Components' 'data-flow|Data Flow' 'error-handling|Error Handling' 'testing|Testing'; do
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

# cw_consult_design_doc_drilldown_prompt <section> <synthesis-path> <commander> <dd-dir> <focus>
# Builds a focused inbox payload asking <commander> to drill into <section>.
# Trooper writes to <dd-dir>/_scratch/drilldown-<section-slug>-<commander>.md
# (the _scratch/ subdir keeps per-section trooper output out of the user-facing
# design-doc directory, which should contain only the final assembled spec).
# <focus> is optional pushback text from the user; default applies if empty.
cw_consult_design_doc_drilldown_prompt() {
  local section="$1" syn="$2" commander="$3" dd_dir="$4" focus="${5:-}"
  local section_slug
  section_slug=$(printf '%s' "$section" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
  local out_path="$dd_dir/_scratch/drilldown-${section_slug}-${commander}.md"
  local resolved_focus="${focus:-Provide more depth, citations, and concrete trade-offs for the $section section.}"
  cw_consult_load_prompt consult/drilldown.md \
    "SECTION=$section" \
    "SYN=$syn" \
    "FOCUS=$resolved_focus" \
    "OUT_PATH=$out_path"
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

# cw_consult_parse_design_doc_flag <args>
# Token-aware parse: removes only EXACT --design-doc tokens (not substrings).
# Emits "<flag>\t<topic>" on stdout, where <flag> ∈ {0,1}.
# Subshell-safe (does not export anything; caller parses stdout).
cw_consult_parse_design_doc_flag() {
  local raw="${1:-}"
  local flag=0
  local -a kept=()
  local tok
  # IFS-split on whitespace; -r preserves backslashes.
  read -r -a all <<< "$raw"
  for tok in "${all[@]}"; do
    if [[ "$tok" == "--design-doc" ]]; then
      flag=1
    else
      kept+=("$tok")
    fi
  done
  printf '%s\t%s\n' "$flag" "${kept[*]}"
}

# cw_consult_load_prompt <relpath> [VAR=value ...]
# Reads $CLAUDE_PLUGIN_ROOT/config/prompt-templates/<relpath> and substitutes
# every {{VAR}} placeholder using single-pass sed. Returns:
#   rc=0 — rendered prompt printed to stdout
#   rc=1 — template not found (path printed to stderr)
#   rc=2 — bad call (no CLAUDE_PLUGIN_ROOT, surviving {{VAR}}, or no relpath)
#
# Single-pass: a value containing {{...}} is NOT recursively expanded; if a
# user-supplied value reintroduces a placeholder the surviving-token guard
# fires. This is the safer behavior — recursion would amplify mistakes.
cw_consult_load_prompt() {
  local relpath="${1:-}"
  [[ -n "$relpath" ]] || { echo "cw_consult_load_prompt: relpath required" >&2; return 2; }
  shift
  local plugin_root="${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}"
  [[ -n "$plugin_root" ]] || { echo "cw_consult_load_prompt: CLAUDE_PLUGIN_ROOT not set" >&2; return 2; }
  local tmpl="$plugin_root/config/prompt-templates/$relpath"
  [[ -f "$tmpl" ]] || { echo "cw_consult_load_prompt: template not found: $tmpl" >&2; return 1; }

  # Build a sed script: one s|{{KEY}}|escaped-value|g per VAR=value pair.
  # Pipe delimiter so / in values stays literal; escape \, &, and | in value.
  local script="" pair key val esc
  for pair in "$@"; do
    key="${pair%%=*}"
    val="${pair#*=}"
    [[ "$pair" == *=* && -n "$key" ]] || { echo "cw_consult_load_prompt: bad VAR=value '$pair'" >&2; return 2; }
    esc=${val//\\/\\\\}    # \  → \\
    esc=${esc//&/\\&}      # &  → \&
    esc=${esc//|/\\|}      # |  → \|
    esc=${esc//$'\n'/\\$'\n'}   # newlines: sed `s` needs a literal newline escape
    script+="s|{{${key}}}|${esc}|g;"
  done

  local rendered
  rendered=$(sed -e "$script" "$tmpl") || return 1

  if printf '%s\n' "$rendered" | grep -qE '\{\{[A-Z_][A-Z0-9_]*\}\}'; then
    {
      echo "cw_consult_load_prompt: unresolved placeholders in $relpath:"
      printf '%s\n' "$rendered" | grep -oE '\{\{[A-Z_][A-Z0-9_]*\}\}' | sort -u | sed 's/^/  /'
    } >&2
    return 2
  fi

  printf '%s\n' "$rendered"
}

# cw_consult_detect_hub <cwd>
# Classifies <cwd> into one of three modes and prints structured stdout:
#   MODE=single-repo|hub-subrepo|super-hub
#   HUBS=<comma-list>      (only when super-hub)
#   LEAVES=<comma-list>    (always when rc=0; <hub>/<leaf> form for super-hub,
#                           <self>/<leaf> form for hub-subrepo)
# Returns 0 when hub-mode (hub-subrepo or super-hub); rc=1 for single-repo
# (preserves v0.10 caller expectation).
cw_consult_detect_hub() {
  local cwd="${1:-}"
  [[ -n "$cwd" ]] || return 1
  [[ -d "$cwd/.git" || -f "$cwd/.git" ]] || return 1

  local self_name child base child_name
  self_name="${cwd##*/}"
  local -a immediate_git=() leaves_subrepo=() hubs=() leaves_super=()
  for child in "$cwd"/*/; do
    [[ -d "$child" ]] || continue
    if [[ -d "$child/.git" || -f "$child/.git" ]]; then
      base="${child%/}"
      child_name="${base##*/}"
      if [[ ! "$child_name" =~ ^[A-Za-z0-9._-]+$ ]]; then
        log_warn "cw_consult_detect_hub: dropped '$child_name' (non-slug-safe directory name)"
        continue
      fi
      immediate_git+=("$child_name")
    fi
  done
  [[ ${#immediate_git[@]} -gt 0 ]] || return 1

  # For each immediate git child, scan its subdirectories:
  #   - any git grandchild  → child is a hub (collect each leaf)
  #   - no git grandchild but has at least one non-git subdir → child is a leaf
  #   - no subdirectories at all → drop (not a meaningful sub-project node)
  local hub leaf grandchild has_grand has_any_subdir grand_name
  for hub in "${immediate_git[@]}"; do
    has_grand=0
    has_any_subdir=0
    for grandchild in "$cwd/$hub"/*/; do
      [[ -d "$grandchild" ]] || continue
      has_any_subdir=1
      if [[ -d "$grandchild/.git" || -f "$grandchild/.git" ]]; then
        leaf="${grandchild%/}"
        grand_name="${leaf##*/}"
        if [[ ! "$grand_name" =~ ^[A-Za-z0-9._-]+$ ]]; then
          log_warn "cw_consult_detect_hub: dropped '$grand_name' (non-slug-safe directory name)"
          continue
        fi
        leaves_super+=("$hub/$grand_name")
        has_grand=1
      fi
    done
    if (( has_grand == 1 )); then
      hubs+=("$hub")
    elif (( has_any_subdir == 1 )); then
      leaves_subrepo+=("$self_name/$hub")
    else
      # bare git repo (no subdirectories) → drop per spec error-handling
      log_warn "cw_consult_detect_hub: dropped '$hub' (bare git child with no subdirectories)"
    fi
  done

  # Classification:
  # - any immediate git child is a hub (has git grandchildren) → super-hub
  # - all immediate git children are leaves → hub-subrepo
  # - mixed: super-hub mode, leaf-less hubs are dropped (per spec error-handling)
  if (( ${#hubs[@]} > 0 )); then
    [[ ${#leaves_super[@]} -gt 0 ]] || return 1
    printf 'MODE=super-hub\n'
    printf 'HUBS=%s\n' "$(IFS=,; echo "${hubs[*]}")"
    printf 'LEAVES=%s\n' "$(IFS=,; echo "${leaves_super[*]}")"
    return 0
  fi
  if (( ${#leaves_subrepo[@]} > 0 )); then
    printf 'MODE=hub-subrepo\n'
    printf 'LEAVES=%s\n' "$(IFS=,; echo "${leaves_subrepo[*]}")"
    return 0
  fi
  return 1
}

# cw_consult_hub_mode_persist <art-dir> <mode>
# Atomic-writes <art-dir>/hub-mode.txt. Mode must be one of the three
# detector outputs: single-repo | hub-subrepo | super-hub.
cw_consult_hub_mode_persist() {
  local art="${1:-}" mode="${2:-}"
  [[ -n "$art" ]]  || { echo "cw_consult_hub_mode_persist: missing art-dir" >&2; return 2; }
  [[ -n "$mode" ]] || { echo "cw_consult_hub_mode_persist: missing mode" >&2; return 2; }
  case "$mode" in
    single-repo|hub-subrepo|super-hub) ;;
    *) echo "cw_consult_hub_mode_persist: invalid mode '$mode'" >&2; return 2 ;;
  esac
  printf '%s\n' "$mode" | cw_atomic_write "$art/hub-mode.txt"
}

# cw_consult_hub_mode_load <art-dir>
# Echoes the persisted mode; defaults to single-repo when file is absent.
cw_consult_hub_mode_load() {
  local art="${1:-}"
  [[ -n "$art" ]] || { echo "cw_consult_hub_mode_load: missing art-dir" >&2; return 2; }
  if [[ -f "$art/hub-mode.txt" ]]; then
    tr -d '[:space:]' < "$art/hub-mode.txt"
    printf '\n'
  else
    printf 'single-repo\n'
  fi
}

# cw_consult_targets_persist <art-dir>
# Reads stdin (one <hub>/<leaf> line per target), validates each line
# against ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$, atomic-writes <art-dir>/targets.txt.
# Empty stdin or any invalid line → rc=1 + log_error, no file written.
cw_consult_targets_persist() {
  local art="${1:-}"
  [[ -n "$art" ]] || { echo "cw_consult_targets_persist: missing art-dir" >&2; return 2; }
  local -a lines=()
  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ ! "$line" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
      echo "cw_consult_targets_persist: invalid target '$line' (need <hub>/<leaf>)" >&2
      return 1
    fi
    lines+=("$line")
  done
  (( ${#lines[@]} > 0 )) \
    || { echo "cw_consult_targets_persist: stdin empty" >&2; return 1; }
  printf '%s\n' "${lines[@]}" | cw_atomic_write "$art/targets.txt"
}

# cw_consult_targets_load <art-dir>
# Echoes targets one per line. rc=1 if file missing or empty.
cw_consult_targets_load() {
  local art="${1:-}"
  [[ -n "$art" ]] || { echo "cw_consult_targets_load: missing art-dir" >&2; return 2; }
  [[ -s "$art/targets.txt" ]] || return 1
  cat "$art/targets.txt"
}

# cw_consult_targets_to_header_pair <art-dir>
# Reads targets.txt and emits exactly two lines suitable for design-doc
# header insertion:
#   **Target Hub(s):** <comma-separated unique hubs>
#   **Target Sub-Project(s):** <comma-separated unique leaves>
# Hubs are extracted as the prefix before '/'; leaves as the suffix after.
# rc=1 if targets.txt is missing/empty.
cw_consult_targets_to_header_pair() {
  local art="${1:-}"
  [[ -n "$art" ]] || { echo "cw_consult_targets_to_header_pair: missing art-dir" >&2; return 2; }
  [[ -s "$art/targets.txt" ]] || return 1
  local hubs leaves
  hubs=$(cut -d/ -f1 "$art/targets.txt" | awk '!seen[$0]++' | paste -sd, -)
  leaves=$(cut -d/ -f2- "$art/targets.txt" | awk '!seen[$0]++' | paste -sd, -)
  # Convert "a,b" → "a, b" for human-readable headers.
  hubs=$(echo "$hubs" | sed 's/,/, /g')
  leaves=$(echo "$leaves" | sed 's/,/, /g')
  printf '**Target Hub(s):** %s\n' "$hubs"
  printf '**Target Sub-Project(s):** %s\n' "$leaves"
}
