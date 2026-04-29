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
#   URL:   identical strings (after trim).
#   runtime: identical strings (after trim, includes `runtime:` prefix).
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
  # Bail out on non-numeric (defensive).
  [[ "$a1$a2$b1$b2" =~ ^[0-9]+$ ]] || return 1
  (( a1 <= b2 && b1 <= a2 ))
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
  <any free-form additions; not parsed by conductor>

Citation format options:
  - <file path>:<line>          e.g. src/auth/store.py:42
  - <file path>:<line-range>    e.g. src/auth/refresh.py:15-30
  - <URL>                       e.g. https://datatracker.ietf.org/doc/html/rfc6749
  - runtime: <command>          e.g. runtime: pytest tests/test_auth.py

Each claim must have a citation in [brackets]. Claims without citations
will be silently dropped by the conductor — and if NO claim has a
citation, your findings will be flagged as malformed in the report.

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
    printf '<!-- conductor: read each cited source for every "PENDING" line below; rewrite the prefix to CONFIRMED, REFUTED, or move to ## Contested. consult-synthesize.sh refuses to finalize while any PENDING remains. -->\n'
    [[ -f "$cody_v" ]] && cw_consult_parse_verdicts "$cody_v" \
      | awk -F'\t' '$1 != "AGREE" { printf "- PENDING: [%s] %s — CODY %s: %s\n", $2, $3, $1, ($4 != "" ? $4 : $3) }'
    [[ -f "$rex_v" ]] && cw_consult_parse_verdicts "$rex_v" \
      | awk -F'\t' '$1 != "AGREE" { printf "- PENDING: [%s] %s — REX %s: %s\n", $2, $3, $1, ($4 != "" ? $4 : $3) }'

    printf '\n## Contested\n'
    printf '<!-- conductor: move CONTESTED items here from Adjudicated. Items in this section ship in synthesis as unresolved. -->\n'

    printf '\n## Not-verified\n'
    if [[ "$rex_vs" != "ok" && "$rex_vs" != "skipped" && -s "$cody_only" ]]; then
      awk -v vs="$rex_vs" '{ printf "- %s — REX verify dispatch %s\n", $0, vs }' "$cody_only"
    fi
    if [[ "$cody_vs" != "ok" && "$cody_vs" != "skipped" && -s "$rex_only" ]]; then
      awk -v vs="$cody_vs" '{ printf "- %s — CODY verify dispatch %s\n", $0, vs }' "$rex_only"
    fi
  } > "$out"
}
