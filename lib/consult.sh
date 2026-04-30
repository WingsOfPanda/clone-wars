# lib/consult.sh — /clone-wars:consult helpers.
# Sourced. Depends on lib/state.sh, lib/ipc.sh, lib/contracts.sh.

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
  cat <<EOF
You researched a topic in your previous turn. Below are claims the OTHER researcher raised that you did not. For EACH item, do ONE of:

  AGREE     — confirm with your own evidence (cite a file/line/source)
  DISPUTE   — explain why it's wrong, with counter-evidence
  UNCERTAIN — you cannot tell from available evidence; say so

Items to verify:
$(cat "$items_file" | nl -ba -w1 -s'. ')

Write your verdicts to $write_to in this exact format:

  # Verify
  ## Verdicts
  1. <TAG> <original [citation] and text>
     <one-line evidence>
  2. ...

Where <TAG> is one of: AGREE / DISPUTE / UNCERTAIN.

Verification methods (v0.3.2):
You may use any tool in your environment to verify these claims —
WebSearch / WebFetch are explicitly authorized when an item cites a
URL, references external standards/docs, or makes a claim that local
repo evidence cannot resolve. For URL-cited items, fetching the source
is the default verification step. For file-cited items, prefer reading
the local file but reach for web tools when the file references an
external behavior (e.g., HTTP semantics, library APIs). If a tool is
unavailable in your environment, mark the item UNCERTAIN and note the
gap rather than fabricating evidence.

Then emit {"event":"done", "summary":"verified N items", "ts":"<iso>"} to your outbox.

END_OF_INSTRUCTION
EOF
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
  cat <<EOF
Investigate the following topic and produce structured findings.

Topic: $topic

Output requirements — write to $write_to with this EXACT structure:

  # Findings: $topic

  ## Summary
  <2-3 sentence overview, free-form prose>

  ## Claims
  1. [<source citation>] <one-sentence claim>
  2. [<source citation>] <one-sentence claim>
  ...

  ## Notes
  <any free-form additions; not parsed by Master Yoda>

Citation format options:
  - <file path>:<line>          e.g. src/auth/store.py:42
  - <file path>:<line-range>    e.g. src/auth/refresh.py:15-30
  - <URL>                       e.g. https://datatracker.ietf.org/doc/html/rfc6749
  - runtime: <command>          e.g. runtime: pytest tests/test_auth.py

Each claim must have a citation in [brackets]. Claims without citations
will be silently dropped by Master Yoda — and if NO claim has a
citation, your findings will be flagged as malformed in the report.

Research methods (v0.3.2):
You may use any tool available in your environment to investigate this
topic. When local repository evidence is insufficient or the topic
references external knowledge (RFCs, standards, library docs, vendor
APIs, recent CVEs, design patterns), you SHOULD use WebSearch / WebFetch
(or the equivalent in your TUI) to find authoritative sources and cite
them as URL citations. The citation parser already handles \`https://...\`
strings — see the URL row in the citation-format list above. Prefer
primary sources (specifications, official docs, source repos) over blog
posts. If a tool is not available in your environment, fall back to
local-only investigation and note the gap as an [unverified] claim.

Then emit {"event":"done", "summary":"researched $topic", "ts":"<iso>"} to your outbox.

END_OF_INSTRUCTION
EOF
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
# Extracted from v0.1.2 bin/consult.sh Phase 5 awk; matches the same output.
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

# cw_consult_classify_topic <topic-text>  (v0.3.0)
# Echo one of: brainstorming | systematic-debugging | none.
# Brainstorming wins ties. Triggers case-insensitive, word-boundary anchored.
# "design"/"structure"/"approach" alone do NOT trigger (Codex Rev1 M-tier).
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

# cw_consult_skill_hint_append <skill-txt-path> <base-prompt>  (v0.3.0)
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
# Atomic write (tmp + mv). Multi-line TEXT is percent-encoded via %0A.
cw_consult_question_payload_write() {
  local file="$1" text="$2" options="$3" phase="$4"
  local encoded=${text//$'\n'/%0A}
  local tmp="$file.tmp.$$"
  {
    printf 'TEXT=%s\n'     "$encoded"
    [[ -n "$options" ]] && printf 'OPTIONS=%s\n' "$options"
    printf 'PHASE=%s\n'    "$phase"
    printf 'ASKED_AT=%s\n' "$(date +%s)"
  } > "$tmp"
  mv "$tmp" "$file"
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
# v0.4.0 — design-doc mode helpers
# ============================================================================

# cw_consult_design_doc_filename <topic-slug>
# Emits docs/clone-wars/specs/YYYY-MM-DD-<slug>-design.md.
# Uses ${CW_TEST_DATE:-$(date +%Y-%m-%d)} for testability.
# Rejects empty slug or slug outside [a-z0-9-] with rc=2.
cw_consult_design_doc_filename() {
  local slug="${1:-}"
  [[ -n "$slug" ]] || { echo "cw_consult_design_doc_filename: empty slug" >&2; return 2; }
  [[ "$slug" =~ ^[a-z0-9-]+$ ]] || {
    echo "cw_consult_design_doc_filename: slug '$slug' has invalid chars (need [a-z0-9-])" >&2
    return 2
  }
  local date_str="${CW_TEST_DATE:-$(date +%Y-%m-%d)}"
  printf 'docs/clone-wars/specs/%s-%s-design.md\n' "$date_str" "$slug"
}

# cw_consult_design_doc_assemble <section-dir> <output-path> <title>
# Concatenates 5 section files into a single design doc with a standard
# header. Missing sections get a _(skipped)_ placeholder body.
cw_consult_design_doc_assemble() {
  local section_dir="$1" out="$2" title="$3"
  [[ -d "$section_dir" ]] || { echo "cw_consult_design_doc_assemble: missing $section_dir" >&2; return 1; }
  [[ -n "$title" ]] || { echo "cw_consult_design_doc_assemble: empty title" >&2; return 2; }

  # Header — pull goal/arch/tech-stack from architecture.md if present.
  local goal="(see Architecture section)" arch_line="(see Architecture section)" tech_block=""
  if [[ -f "$section_dir/architecture.md" ]]; then
    goal=$(head -n1 "$section_dir/architecture.md")
    # Architecture paragraph: lines >=3, until first blank line or "## Tech Stack".
    arch_line=$(awk '
      NR<3 {next}
      /^## Tech Stack$/ {exit}
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
      printf '- (see Components section)\n'
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
