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
# Print one TAB-delimited line per verdict: "<tag>\t<citation>\t<text>".
# Source format: `N. <TAG> [<citation>] <text>` lines under `## Verdicts`.
# Only AGREE / DISPUTE / UNCERTAIN tags are accepted; anything else (e.g.
# hallucinated UNKNOWN, MAYBE) is silently dropped — strict-by-design.
cw_consult_parse_verdicts() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  awk '
    /^## Verdicts/                                            { in_v = 1; next }
    /^## /                                                    { in_v = 0 }
    in_v && /^[0-9]+\. (AGREE|DISPUTE|UNCERTAIN) \[[^]]+\] / {
      sub(/^[0-9]+\. /, "")
      tag = $1
      sub(/^[A-Z]+ /, "")
      match($0, /\[[^]]+\]/)
      cite = substr($0, RSTART + 1, RLENGTH - 2)
      text = substr($0, RSTART + RLENGTH + 1)
      sub(/^[ \t]+/, "", text)
      printf "%s\t%s\t%s\n", tag, cite, text
    }
  ' "$file"
}
