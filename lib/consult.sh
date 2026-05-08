# lib/consult.sh — /clone-wars:consult helpers (residual + shim).
# Prompt builders live in lib/consult-prompts.sh; sourced transitively so
# existing `source lib/consult.sh` callers continue to work.
# Depends on lib/state.sh, lib/ipc.sh, lib/contracts.sh.
# Callers SHOULD source lib/state.sh and lib/log.sh before this file.
# state.sh is auto-loaded as fallback (split files anchor regex against
# CW_SLUG_REGEX_BASE inside [[ =~ ]], which fails under set -u when unset);
# log.sh is NOT auto-loaded — callers needing log_warn/log_info must source it.

# Resolve siblings via BASH_SOURCE (NOT CLAUDE_PLUGIN_ROOT — test fixtures
# override it to a sandbox that lacks the lib/ tree). readlink -f resolves
# through symlinks so the plugin install path
# ~/.claude/plugins/cache/<plugin>/<version>/lib/consult.sh works correctly;
# plain `dirname "${BASH_SOURCE[0]}"` returns the symlink's parent dir.
_CONSULT_BASH_SOURCE="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
_CONSULT_LIB_DIR="$(cd "$(dirname "$_CONSULT_BASH_SOURCE")" && pwd)"
unset _CONSULT_BASH_SOURCE
# state.sh self-guards CW_SLUG_REGEX_BASE so re-sourcing is a no-op.
[[ -n "${CW_SLUG_REGEX_BASE:-}" ]] || source "$_CONSULT_LIB_DIR/state.sh"
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

# cw_consult_diff <art-dir> <name1>:<findings1> <name2>:<findings2> [<nameN>:<findingsN> ...]
#
# N-way Venn bucketer. Parses each trooper's findings.md, pairs claims via
# cw_consult_citation_overlaps, buckets each claim by membership set, and emits:
#
#   <art-dir>/diff.md             — human-readable summary
#   <art-dir>/<name>_only_items.txt   — one per single-only bucket (always written)
#
# For N >= 3, additionally:
#   <art-dir>/consensus.txt           — all-N intersection (always written)
#   <art-dir>/<a>+<b>_only.txt        — pair-only buckets (always written, by input order)
#
# diff.md section headers:
#   N=2  → ## Agreed / ## Rex-only / ## Cody-only          (byte-equal v0.14.0)
#   N>=3 → ## Consensus / ## <A>+<B> only (each pair) / ## <Name>-only (each single)
#
# Body line formats:
#   Multi-trooper bucket: - [<first-cite>] <text-1> | <text-2> | ...
#   Single-only:          - [<cite>] <text>
#
# Bucket file lines (no `- ` prefix; matches existing rex_only_items.txt format):
#   [<cite>] <text> | <text> ...     (or just `[<cite>] <text>` for single-only)
#
# Pairing semantics (preserved from v0.14.0): iterate troopers in order; each
# trooper's claims are first-match-wins against later troopers' unmatched
# claims, growing a membership set. This preserves the
# "path-only does not steal specific-line pairing" behavior on existing
# regression fixtures.
cw_consult_diff() {
  local art_dir="$1"; shift
  [[ -d "$art_dir" ]] || { echo "cw_consult_diff: art_dir not found: $art_dir" >&2; return 2; }
  local n=$#
  (( n >= 2 )) || { echo "cw_consult_diff: need >=2 troopers, got $n" >&2; return 2; }

  # Parse args: tagged inputs of form <name>:<path>.
  local -a names=() paths=()
  local arg name path
  for arg in "$@"; do
    [[ "$arg" == *:* ]] || { echo "cw_consult_diff: arg '$arg' not <name>:<path>" >&2; return 2; }
    name="${arg%%:*}"; path="${arg#*:}"
    [[ -n "$name" && -n "$path" ]] || { echo "cw_consult_diff: empty name or path in '$arg'" >&2; return 2; }
    names+=("$name"); paths+=("$path")
  done

  # Flat parallel arrays — one entry per claim across all troopers.
  #   _owner[i]  = trooper index that contributed the claim
  #   _cite[i]   = citation
  #   _text[i]   = description
  #   _flag[i]   = 0 (unbucketed) | 1 (bucketed)
  # _start[t]    = first index belonging to trooper t (for inner-loop scan window)
  # _end[t]      = one-past-last index belonging to trooper t
  local -a _owner=() _cite=() _text=() _flag=()
  local -a _start=() _end=()
  local cite text idx
  for (( idx = 0; idx < n; idx++ )); do
    _start+=("${#_owner[@]}")
    while IFS=$'\t' read -r cite text; do
      _owner+=("$idx"); _cite+=("$cite"); _text+=("$text"); _flag+=(0)
    done < <(cw_consult_parse_claims "${paths[$idx]}")
    _end+=("${#_owner[@]}")
  done
  local total="${#_owner[@]}"

  # Bucket map: membership-set-key (e.g. "rex,cody,bly") -> newline-joined lines.
  declare -A _cw_d_bucket_items=()

  _cw_d_bucket_add() {
    local key="$1" line="$2"
    if [[ -z "${_cw_d_bucket_items[$key]+x}" || -z "${_cw_d_bucket_items[$key]}" ]]; then
      _cw_d_bucket_items[$key]="$line"
    else
      _cw_d_bucket_items[$key]+=$'\n'"$line"
    fi
  }

  # Walk troopers in order; for each unbucketed claim of trooper i, scan
  # later troopers' unbucketed claims for the first overlap, building a
  # membership set and a combined text (pipe-separated).
  local i j k m
  for (( i = 0; i < n; i++ )); do
    for (( j = "${_start[$i]}"; j < "${_end[$i]}"; j++ )); do
      [[ "${_flag[$j]}" -eq 1 ]] && continue
      local member_keys="${names[$i]}"
      local first_cite="${_cite[$j]}"
      local combined_text="${_text[$j]}"
      _flag[$j]=1
      for (( k = i + 1; k < n; k++ )); do
        for (( m = "${_start[$k]}"; m < "${_end[$k]}"; m++ )); do
          [[ "${_flag[$m]}" -eq 1 ]] && continue
          if cw_consult_citation_overlaps "$first_cite" "${_cite[$m]}"; then
            member_keys+=",${names[$k]}"
            combined_text+=" | ${_text[$m]}"
            _flag[$m]=1
            break
          fi
        done
      done
      _cw_d_bucket_add "$member_keys" "[$first_cite] $combined_text"
    done
  done

  # Compute canonical bucket sets:
  #   all_key       = comma-join of all names in input order
  #   pair_keys     = each 2-name combination in input order (only used when n>=3)
  #   single_keys   = each single name (in input order)
  local all_key=""
  for (( i = 0; i < n; i++ )); do
    [[ -n "$all_key" ]] && all_key+=","
    all_key+="${names[$i]}"
  done

  local -a pair_keys=() single_keys=()
  for (( i = 0; i < n; i++ )); do
    single_keys+=("${names[$i]}")
    for (( j = i + 1; j < n; j++ )); do
      pair_keys+=("${names[$i]},${names[$j]}")
    done
  done

  # Helper: titlecase first letter of a name (rex -> Rex, cody -> Cody, bly -> Bly).
  _cw_d_titlecase() {
    local s="$1"
    printf '%s' "${s^}"
  }

  # Helper: print a bucket's items (items only, no header). Falls back to no-op if empty.
  _cw_d_emit_bucket() {
    local key="$1"
    [[ -n "${_cw_d_bucket_items[$key]+x}" ]] || return 0
    printf '%s\n' "${_cw_d_bucket_items[$key]}"
  }

  # Write per-bucket files.
  # For N=2: only the two single-only bucket files (matches v0.14.0 surface).
  # For N>=3: consensus.txt + each pair_only file + each single-only file.
  local key file
  if (( n == 2 )); then
    for key in "${single_keys[@]}"; do
      file="$art_dir/${key}_only_items.txt"
      : > "$file"
      _cw_d_emit_bucket "$key" >> "$file"
    done
  else
    # Consensus (all-N intersection).
    file="$art_dir/consensus.txt"
    : > "$file"
    _cw_d_emit_bucket "$all_key" >> "$file"
    # Pair-only buckets.
    for key in "${pair_keys[@]}"; do
      local a="${key%%,*}" b="${key##*,}"
      file="$art_dir/${a}+${b}_only.txt"
      : > "$file"
      _cw_d_emit_bucket "$key" >> "$file"
    done
    # Single-only buckets.
    for key in "${single_keys[@]}"; do
      file="$art_dir/${key}_only_items.txt"
      : > "$file"
      _cw_d_emit_bucket "$key" >> "$file"
    done
  fi

  # Write diff.md.
  local out="$art_dir/diff.md"
  if (( n == 2 )); then
    # Byte-equal v0.14.0 format: ## Agreed / ## Rex-only / ## Cody-only
    local n0_cap n1_cap
    n0_cap=$(_cw_d_titlecase "${names[0]}")
    n1_cap=$(_cw_d_titlecase "${names[1]}")
    {
      printf '## Agreed\n'
      if [[ -n "${_cw_d_bucket_items[$all_key]+x}" ]]; then
        printf '%s\n' "${_cw_d_bucket_items[$all_key]}" | sed 's/^/- /'
      fi
      printf '\n## %s-only\n' "$n0_cap"
      if [[ -n "${_cw_d_bucket_items[${names[0]}]+x}" ]]; then
        printf '%s\n' "${_cw_d_bucket_items[${names[0]}]}" | sed 's/^/- /'
      fi
      printf '\n## %s-only\n' "$n1_cap"
      if [[ -n "${_cw_d_bucket_items[${names[1]}]+x}" ]]; then
        printf '%s\n' "${_cw_d_bucket_items[${names[1]}]}" | sed 's/^/- /'
      fi
    } > "$out"
  else
    # N>=3: ## Consensus / pair-only sections / single-only sections.
    {
      printf '## Consensus\n'
      if [[ -n "${_cw_d_bucket_items[$all_key]+x}" ]]; then
        printf '%s\n' "${_cw_d_bucket_items[$all_key]}" | sed 's/^/- /'
      fi
      for key in "${pair_keys[@]}"; do
        local a="${key%%,*}" b="${key##*,}"
        local a_cap b_cap
        a_cap=$(_cw_d_titlecase "$a")
        b_cap=$(_cw_d_titlecase "$b")
        printf '\n## %s+%s only\n' "$a_cap" "$b_cap"
        if [[ -n "${_cw_d_bucket_items[$key]+x}" ]]; then
          printf '%s\n' "${_cw_d_bucket_items[$key]}" | sed 's/^/- /'
        fi
      done
      for key in "${single_keys[@]}"; do
        local key_cap
        key_cap=$(_cw_d_titlecase "$key")
        printf '\n## %s-only\n' "$key_cap"
        if [[ -n "${_cw_d_bucket_items[$key]+x}" ]]; then
          printf '%s\n' "${_cw_d_bucket_items[$key]}" | sed 's/^/- /'
        fi
      done
    } > "$out"
  fi

  # Cleanup function-local globals (declare -A persists in caller's scope otherwise).
  unset _cw_d_bucket_items
  unset -f _cw_d_bucket_add _cw_d_titlecase _cw_d_emit_bucket
  : "$total"  # silence unused-var lint
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
# v0.16.0: emits the canonical design-doc (rigid 6 sections + trust-label
# header) at <out>. <out> should be the path returned by
# cw_consult_design_doc_canonical_path. The legacy synthesis.md write was
# dropped — no fallback, no symlink.
#
# Section mapping (adjudicated.md → design-doc):
#   diff.md ## Agreed                  → ## Findings (head)
#   adj.md  ## Cross-verified          → ## Findings (cross-verified body)
#   adj.md  ## Adjudicated             → ## Findings (resolved body)
#   adj.md  ## Contested               → ## Tradeoffs
#   adj.md  ## Not-verified            → ## Open Questions
#   trooper artifact paths             → ## Sources
#
# Trust-label header values (env-overridable):
#   CW_SOURCE_LABEL  — defaults to 'rex+cody cross-verified'
#   CW_PATH_LABEL    — defaults to 'escalated-from-signals'
# Banners are emitted between the trust-label header and ## Summary.
cw_consult_synthesize() {
  local topic="$1" diff="$2" adj="$3" rex_dir="$4" cody_dir="$5"
  local rex_fs="$6" cody_fs="$7" rex_vs="$8" cody_vs="$9" out="${10}"

  local source_label="${CW_SOURCE_LABEL:-rex+cody cross-verified}"
  local path_label="${CW_PATH_LABEL:-escalated-from-signals}"
  local generated_at
  generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Title-case the topic for the H1.
  local title
  title=$(printf '%s' "$topic" | awk '{
    for (i=1; i<=NF; i++) $i = toupper(substr($i,1,1)) tolower(substr($i,2))
  } 1')

  # Buffer the section bodies up-front so we can emit `_(not applicable)_`
  # placeholders when a section is empty.
  local agreed_body cross_body contested_body notverified_body
  agreed_body=$(awk '/^## Agreed/{f=1;next} /^## /{f=0} f' "$diff")
  cross_body=$(awk '
    /^## Cross-verified/{f=1; next}
    /^## Adjudicated/   {f=1; next}
    /^## /              {f=0}
    f
  ' "$adj")
  contested_body=$(awk '
    /^## Contested/{f=1; next}
    /^## /         {f=0}
    f
  ' "$adj")
  notverified_body=$(awk '
    /^## Not-verified/{f=1; next}
    /^## /            {f=0}
    f
  ' "$adj")

  # Strip leading/trailing blank lines from each buffered body.
  _cw_consult_strip_blank_edges() {
    awk 'NF {seen=1} seen' <<<"$1" | awk '{lines[NR]=$0} END{
      n=NR; while (n>0 && lines[n] ~ /^[[:space:]]*$/) n--;
      for (i=1; i<=n; i++) print lines[i]
    }'
  }
  agreed_body=$(_cw_consult_strip_blank_edges "$agreed_body")
  cross_body=$(_cw_consult_strip_blank_edges "$cross_body")
  contested_body=$(_cw_consult_strip_blank_edges "$contested_body")
  notverified_body=$(_cw_consult_strip_blank_edges "$notverified_body")
  unset -f _cw_consult_strip_blank_edges

  {
    printf '# %s\n\n' "$title"

    printf '> **Source:** %s\n' "$source_label"
    printf '> **Generated:** %s\n' "$generated_at"
    printf '> **Path:** %s\n\n' "$path_label"

    # Banners (preserved from v0.15: surface non-ok/skipped statuses).
    case "$rex_fs"  in malformed|missing|empty) printf '> NOTE: REX findings.md %s — diff/synthesis ran on best-effort parse.\n\n' "$rex_fs" ;; esac
    case "$cody_fs" in malformed|missing|empty) printf '> NOTE: CODY findings.md %s — diff/synthesis ran on best-effort parse.\n\n' "$cody_fs" ;; esac
    case "$rex_vs"  in timeout|error|send-failed|missing|empty) printf '> NOTE: REX verify dispatch %s — partial cross-verification; some Cody-only items not graded.\n\n' "$rex_vs" ;; esac
    case "$cody_vs" in timeout|error|send-failed|missing|empty) printf '> NOTE: CODY verify dispatch %s — partial cross-verification; some Rex-only items not graded.\n\n' "$cody_vs" ;; esac

    printf '## Summary\n'
    printf '_(not applicable — Master Yoda fills this in during the /spec walk; the trooper-path captures only cross-verified findings.)_\n\n'

    printf '## Findings\n'
    if [[ -n "$agreed_body" || -n "$cross_body" ]]; then
      if [[ -n "$agreed_body" ]]; then
        printf '### Agreed (both raised independently)\n'
        printf '%s\n\n' "$agreed_body"
      fi
      if [[ -n "$cross_body" ]]; then
        printf '### Cross-verified\n'
        printf '%s\n\n' "$cross_body"
      fi
    else
      printf '_(not applicable)_\n\n'
    fi

    printf '## Tradeoffs\n'
    if [[ -n "$contested_body" ]]; then
      printf '%s\n\n' "$contested_body"
    else
      printf '_(not applicable)_\n\n'
    fi

    printf '## Recommendation\n'
    printf '_(not applicable — Master Yoda fills this in during the /spec walk based on the cross-verified findings above.)_\n\n'

    printf '## Open Questions\n'
    if [[ -n "$notverified_body" ]]; then
      printf '%s\n\n' "$notverified_body"
    else
      printf '_(not applicable)_\n\n'
    fi

    printf '## Sources\n'
    printf -- '- `%s/findings.md` — REX research output\n' "$rex_dir"
    printf -- '- `%s/verify.md` — REX cross-verification verdicts\n'  "$rex_dir"
    printf -- '- `%s/findings.md` — CODY research output\n' "$cody_dir"
    printf -- '- `%s/verify.md` — CODY cross-verification verdicts\n' "$cody_dir"
  } > "$out"
}

# cw_consult_topic_validate <topic>
# Return 0 if the topic is a safe consult topic name; 1 otherwise.
# Rules:
#   - Must start with `consult-`
#   - Allowed chars: ${CW_SLUG_REGEX_BASE}
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

# cw_consult_write_adjudicated <art_dir> <out>
#
# Compose the adjudicated-draft.md content from the artifacts in <art_dir>.
# Discovers N (number of troopers) + commander list from <art_dir>/troopers.txt
# and dispatches:
#
#   N=2 → 4-tier output (byte-equal v0.14.0):
#         ## Cross-verified
#         ## Adjudicated (PENDING list)
#         ## Contested
#         ## Not-verified
#
#   N>=3 → 5-tier output (v0.15.0):
#         ## Consensus findings (all troopers)
#         ## Cross-verified
#         ## Contested
#         ## Refuted
#         ## - PENDING:
#
# Required inputs in <art_dir>:
#   troopers.txt                — TSV: <provider>\t<commander>
#   <commander>_only_items.txt  — one per single-only bucket (always written by consult-diff)
#   For N>=3 only:
#     consensus.txt             — all-N intersection
#     <a>+<b>_only.txt          — one per pair-only bucket
#   verify-<commander>.txt      — per-commander VS state (used for Not-verified in N=2)
# Plus per-trooper verify.md at <topic_dir>/<commander>-<provider>/verify.md
# (where topic_dir = $(dirname "$art_dir")).
cw_consult_write_adjudicated() {
  local art_dir="$1" out="$2"
  [[ -d "$art_dir" ]] || { echo "cw_consult_write_adjudicated: art_dir not found: $art_dir" >&2; return 2; }
  local troopers_file="$art_dir/troopers.txt"
  [[ -f "$troopers_file" ]] || { echo "cw_consult_write_adjudicated: troopers.txt missing in $art_dir" >&2; return 2; }

  local topic_dir
  topic_dir=$(dirname "$art_dir")

  # Parse troopers.txt → parallel arrays.
  local -a _adj_providers=() _adj_commanders=()
  local prov cmdr
  while IFS=$'\t' read -r prov cmdr; do
    [[ -n "$cmdr" ]] || continue
    _adj_providers+=("$prov")
    _adj_commanders+=("$cmdr")
  done < <(cw_consult_load_troopers "$troopers_file")

  local n="${#_adj_commanders[@]}"
  (( n >= 2 )) || { echo "cw_consult_write_adjudicated: need >=2 troopers, got $n" >&2; return 2; }

  if (( n == 2 )); then
    _cw_consult_write_adjudicated_n2 "$art_dir" "$topic_dir" "$out" \
      "${_adj_providers[0]}" "${_adj_commanders[0]}" \
      "${_adj_providers[1]}" "${_adj_commanders[1]}"
  else
    _cw_consult_write_adjudicated_nge3 "$art_dir" "$topic_dir" "$out" \
      _adj_providers _adj_commanders
  fi

  unset _adj_providers _adj_commanders
}

# Internal: N=2 byte-equal v0.14.0 output.
# Args: <art_dir> <topic_dir> <out> <prov0> <cmdr0> <prov1> <cmdr1>
# Convention preserved from v0.14.0: rex == troopers[0], cody == troopers[1].
# Iteration order in the old code was CODY-verdicts-first then REX-verdicts;
# i.e. troopers[1]'s verify.md before troopers[0]'s. We preserve that.
_cw_consult_write_adjudicated_n2() {
  local art_dir="$1" topic_dir="$2" out="$3"
  local p0="$4" c0="$5" p1="$6" c1="$7"
  local rex_v="$topic_dir/$c0-$p0/verify.md"
  local cody_v="$topic_dir/$c1-$p1/verify.md"
  local rex_only="$art_dir/${c0}_only_items.txt"
  local cody_only="$art_dir/${c1}_only_items.txt"
  local C0_UC C1_UC
  C0_UC=$(printf '%s' "$c0" | tr '[:lower:]' '[:upper:]')
  C1_UC=$(printf '%s' "$c1" | tr '[:lower:]' '[:upper:]')

  # Load VS state. Defaults match consult-adjudicate.sh: skipped if absent.
  local rex_vs=skipped cody_vs=skipped
  if [[ -f "$art_dir/verify-$c0.txt" ]]; then
    rex_vs=$(awk -F= '/^VS=/{print $2}' "$art_dir/verify-$c0.txt")
    : "${rex_vs:=skipped}"
  fi
  if [[ -f "$art_dir/verify-$c1.txt" ]]; then
    cody_vs=$(awk -F= '/^VS=/{print $2}' "$art_dir/verify-$c1.txt")
    : "${cody_vs:=skipped}"
  fi

  {
    printf '## Cross-verified\n'
    [[ -f "$cody_v" ]] && cw_consult_parse_verdicts "$cody_v" \
      | awk -F'\t' -v UC="$C1_UC" '$1 == "AGREE" { printf "- [%s] %s — %s confirmed: %s\n", $2, $3, UC, ($4 != "" ? $4 : $3) }'
    [[ -f "$rex_v" ]] && cw_consult_parse_verdicts "$rex_v" \
      | awk -F'\t' -v UC="$C0_UC" '$1 == "AGREE" { printf "- [%s] %s — %s confirmed: %s\n", $2, $3, UC, ($4 != "" ? $4 : $3) }'

    printf '\n## Adjudicated\n'
    printf '<!-- Master Yoda: read each cited source for every "PENDING" line below; rewrite the prefix to CONFIRMED, REFUTED, or move to ## Contested. consult-synthesize.sh refuses to finalize while any PENDING remains. -->\n'
    [[ -f "$cody_v" ]] && cw_consult_parse_verdicts "$cody_v" \
      | awk -F'\t' -v UC="$C1_UC" '$1 != "AGREE" { printf "- PENDING: [%s] %s — %s %s: %s\n", $2, $3, UC, $1, ($4 != "" ? $4 : $3) }'
    [[ -f "$rex_v" ]] && cw_consult_parse_verdicts "$rex_v" \
      | awk -F'\t' -v UC="$C0_UC" '$1 != "AGREE" { printf "- PENDING: [%s] %s — %s %s: %s\n", $2, $3, UC, $1, ($4 != "" ? $4 : $3) }'

    printf '\n## Contested\n'
    printf '<!-- Master Yoda: move CONTESTED items here from Adjudicated. Items in this section ship in synthesis as unresolved. -->\n'

    printf '\n## Not-verified\n'
    if [[ "$rex_vs" != "ok" && "$rex_vs" != "skipped" && -s "$cody_only" ]]; then
      awk -v vs="$rex_vs" -v UC="$C0_UC" '{ printf "- %s — %s verify dispatch %s\n", $0, UC, vs }' "$cody_only"
    fi
    if [[ "$cody_vs" != "ok" && "$cody_vs" != "skipped" && -s "$rex_only" ]]; then
      awk -v vs="$cody_vs" -v UC="$C1_UC" '{ printf "- %s — %s verify dispatch %s\n", $0, UC, vs }' "$rex_only"
    fi
  } > "$out"
}

# Internal: N>=3 5-tier output.
# Args: <art_dir> <topic_dir> <out> <providers-array-name> <commanders-array-name>
# Indirection via -n nameref so we don't have to re-parse troopers.txt.
_cw_consult_write_adjudicated_nge3() {
  local art_dir="$1" topic_dir="$2" out="$3"
  local -n _providers="$4"
  local -n _commanders="$5"
  local n="${#_commanders[@]}"

  # Build verdict lookup: __cw_adj_verdict[<commander>__<cite>] = AGREE|DISPUTE|UNCERTAIN
  # Hyphens in citations don't conflict with the "__" separator.
  declare -A __cw_adj_verdict=()
  declare -A __cw_adj_evidence=()
  local i prov cmdr verify_md tag cite text evidence
  for (( i = 0; i < n; i++ )); do
    prov="${_providers[$i]}"
    cmdr="${_commanders[$i]}"
    verify_md="$topic_dir/$cmdr-$prov/verify.md"
    [[ -f "$verify_md" ]] || continue
    while IFS=$'\t' read -r tag cite text evidence; do
      [[ -n "$cite" ]] || continue
      __cw_adj_verdict["${cmdr}__${cite}"]="$tag"
      __cw_adj_evidence["${cmdr}__${cite}"]="$evidence"
    done < <(cw_consult_parse_verdicts "$verify_md")
  done

  # Section accumulators (one string per section, newline-joined).
  local sec_consensus="" sec_cross="" sec_contested="" sec_refuted="" sec_pending=""

  # _classify <agree-count> <dispute-count> <uncertain-count> <K-required-verifiers> <owner-count>
  # Echoes one of: CROSS | CONTESTED | REFUTED | PENDING.
  # Per spec table:
  #   2-of-3 + bly DISPUTE   → CONTESTED  (multi-owner outranks single REFUTE)
  #   2-of-3 + bly UNCERTAIN → PENDING    (multi-owner + lone UNCERTAIN = needs human read)
  _classify() {
    local na="$1" nd="$2" nu="$3" k="$4" owners="$5"
    # Mixed UNCERTAIN with explicit AGREE/DISPUTE → always PENDING.
    if (( nu > 0 && na + nd > 0 )); then echo PENDING; return; fi
    # All UNCERTAIN: PENDING for multi-owner claims (implicit owner AGREE +
    # lone UNCERTAIN = mixed); CONTESTED for single-owner (no signal to break tie).
    if (( nu == k )); then
      if (( owners >= 2 )); then echo PENDING; else echo CONTESTED; fi
      return
    fi
    if (( na == k )); then echo CROSS; return; fi
    if (( nd == k )); then
      # All DISPUTE: CONTESTED for multi-owner (owners' research outweighs
      # single dissent); REFUTED for single-owner (all verifiers say no).
      if (( owners >= 2 )); then echo CONTESTED; else echo REFUTED; fi
      return
    fi
    # Mixed AGREE/DISPUTE without UNCERTAIN.
    echo CONTESTED
  }

  # _emit_section <section-var-name> <line>
  _emit_section() {
    local -n acc="$1"
    local line="$2"
    if [[ -z "$acc" ]]; then acc="$line"; else acc+=$'\n'"$line"; fi
  }

  # Process consensus.txt → CONSENSUS section. No verify lookup needed.
  local owners_csv all_csv=""
  for (( i = 0; i < n; i++ )); do
    [[ -n "$all_csv" ]] && all_csv+="+"
    all_csv+="${_commanders[$i]}"
  done
  if [[ -s "$art_dir/consensus.txt" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      _emit_section sec_consensus "- $line [$all_csv]"
    done < "$art_dir/consensus.txt"
  fi

  # Process bucket files. For each owner-set, K = (n - |owners|) verifiers.
  # _process_bucket <bucket-file> <owners-csv-+>
  _process_bucket() {
    local bucket="$1" owners="$2"
    [[ -s "$bucket" ]] || return 0
    # Parse owners into an array (split on '+').
    local -a own=()
    local IFS_BAK="$IFS"; IFS='+'
    read -r -a own <<< "$owners"
    IFS="$IFS_BAK"
    local owner_count="${#own[@]}"

    # Compute verifier list: every commander not in owners, in input order.
    local -a verifiers=()
    local c o present
    for c in "${_commanders[@]}"; do
      present=0
      for o in "${own[@]}"; do
        [[ "$o" == "$c" ]] && { present=1; break; }
      done
      (( present == 0 )) && verifiers+=("$c")
    done
    local k="${#verifiers[@]}"

    local raw cite text na nd nu verifier vd v_annotations annotation_for_v key
    while IFS= read -r raw; do
      [[ -n "$raw" ]] || continue
      # Parse `[<cite>] <text>` (the bucket file format).
      cite="${raw#[}"; cite="${cite%%]*}"
      text="${raw#*] }"
      na=0; nd=0; nu=0
      v_annotations=""
      for verifier in "${verifiers[@]}"; do
        key="${verifier}__${cite}"
        if [[ -n "${__cw_adj_verdict[$key]+x}" ]]; then
          vd="${__cw_adj_verdict[$key]}"
        else
          vd=UNCERTAIN  # missing verdict treated as UNCERTAIN signal
        fi
        case "$vd" in
          AGREE)     na=$((na + 1)) ;;
          DISPUTE)   nd=$((nd + 1)) ;;
          UNCERTAIN) nu=$((nu + 1)) ;;
        esac
        annotation_for_v="${verifier}:${vd}"
        if [[ -z "$v_annotations" ]]; then
          v_annotations="$annotation_for_v"
        else
          v_annotations+=", $annotation_for_v"
        fi
      done

      # Source-set annotation.
      local srcset
      if (( owner_count == n )); then
        srcset="$owners"
      elif (( k == 0 )); then
        srcset="$owners"
      else
        srcset="$owners, $v_annotations"
      fi

      local rendered="- [$cite] $text [$srcset]"

      local verdict
      verdict=$(_classify "$na" "$nd" "$nu" "$k" "$owner_count")
      case "$verdict" in
        CROSS)     _emit_section sec_cross     "$rendered" ;;
        CONTESTED) _emit_section sec_contested "$rendered" ;;
        REFUTED)   _emit_section sec_refuted   "$rendered" ;;
        PENDING)   _emit_section sec_pending   "$rendered" ;;
      esac
    done < "$bucket"
  }

  # Pair-only buckets (N>=3 only): for each (i, j) pair in input order.
  local j a b
  for (( i = 0; i < n; i++ )); do
    for (( j = i + 1; j < n; j++ )); do
      a="${_commanders[$i]}"; b="${_commanders[$j]}"
      _process_bucket "$art_dir/${a}+${b}_only.txt" "${a}+${b}"
    done
  done

  # Single-only buckets.
  for cmdr in "${_commanders[@]}"; do
    _process_bucket "$art_dir/${cmdr}_only_items.txt" "$cmdr"
  done

  # Emit final document.
  {
    printf '## Consensus findings (all troopers)\n'
    if [[ -n "$sec_consensus" ]]; then
      printf '%s\n' "$sec_consensus"
    fi

    printf '\n## Cross-verified\n'
    if [[ -n "$sec_cross" ]]; then
      printf '%s\n' "$sec_cross"
    fi

    printf '\n## Contested\n'
    if [[ -n "$sec_contested" ]]; then
      printf '%s\n' "$sec_contested"
    fi

    printf '\n## Refuted\n'
    if [[ -n "$sec_refuted" ]]; then
      printf '%s\n' "$sec_refuted"
    fi

    printf '\n## - PENDING:\n'
    printf '<!-- Master Yoda: read each cited source for every "PENDING" line below; rewrite the prefix or move to ## Contested. consult-synthesize.sh refuses to finalize while any PENDING remains. -->\n'
    if [[ -n "$sec_pending" ]]; then
      printf '%s\n' "$sec_pending"
    fi
  } > "$out"

  unset __cw_adj_verdict __cw_adj_evidence
  unset -f _classify _emit_section _process_bucket
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
# Concatenates 5 section files into a single flat design doc with a
# standard header. Missing sections get a _(skipped)_ placeholder body.
#
# Optional 4th and 5th args override title and goal sources:
#   <topic-text>      — full user topic from _consult/topic.txt; if non-empty,
#                       Title-Cased and used as H1 in preference to <title>
#                       (which is derived from the 20-char-truncated slug).
#   <synthesis-path>  — path to _consult/synthesis.md; first non-empty line
#                       under "## Agreed findings" (then "## Cross-verified")
#                       becomes **Goal:** (200-char trunc); falls back to
#                       architecture.md head -n1.
#   <targets-dir>     — accepted for back-compat (callers like spec-assemble.sh
#                       still pass an empty 6th arg); ignored in v0.14.0.
cw_consult_design_doc_assemble() {
  local section_dir="$1" out="$2" title="$3"
  local topic_text="${4:-}" synthesis_path="${5:-}"
  : "${6:-}"  # explicit no-op on legacy targets-dir arg
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

    local -a sections=(
      'architecture|Architecture'
      'components|Components'
      'data-flow|Data Flow'
      'error-handling|Error Handling'
      'testing|Testing'
    )
    local pair key heading
    for pair in "${sections[@]}"; do
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

# v0.15.0: provider → commander mapping (locked).
# codex → rex (501st), claude → cody (212th), opencode → bly (327th).
cw_consult_provider_to_commander() {
  case "$1" in
    codex)    echo rex ;;
    claude)   echo cody ;;
    opencode) echo bly ;;
    *)        echo "cw_consult_provider_to_commander: no mapping for '$1'" >&2; return 1 ;;
  esac
}

# v0.15.0: filter input stream to consult-eligible providers (codex/claude/opencode).
# Reads provider names from stdin (one per line); writes filtered list to stdout
# in the input order. Used by consult-init to derive N from medic's remark.
cw_consult_eligible_providers() {
  grep -E '^(codex|claude|opencode)$' || true
}

# v0.15.0: load _consult/troopers.txt (TSV: <provider>\t<commander>) → stdout TSV.
# Skips lines starting with '#' (comments) and blank lines. Caller maps to arrays.
cw_consult_load_troopers() {
  local file="$1"
  [[ -f "$file" ]] || { echo "cw_consult_load_troopers: file not found: $file" >&2; return 2; }
  grep -vE '^[[:space:]]*(#|$)' "$file"
}

# v0.16.0: canonical design-doc path within an art-dir.
# Format: <art_dir>/design-doc/<YYYY-MM-DD>-<slug>-design.md
# Used by both fast-path (Yoda solo) and trooper-path (consult-synthesize)
# so /spec reads ONE pattern. Date is UTC.
cw_consult_design_doc_canonical_path() {
  local art_dir="$1" slug="$2"
  [[ -n "$art_dir" ]] || { echo "cw_consult_design_doc_canonical_path: art_dir required" >&2; return 2; }
  [[ -n "$slug" ]]    || { echo "cw_consult_design_doc_canonical_path: slug required" >&2; return 2; }
  printf '%s/design-doc/%s-%s-design.md\n' "$art_dir" "$(date -u +%Y-%m-%d)" "$slug"
}
