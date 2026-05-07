# lib/spec.sh — helpers consumed only by /clone-wars:spec.
# Split out from lib/consult.sh in v0.14.0 (hub-mode removal) to make the
# /spec → /consult dependency boundary honest.

# cw_spec_resume_state <design-doc-dir>
# Lists approved section keys (one per line, basename without .md) on stdout.
# Excludes drilldown-* and zero-byte files. Missing dir → empty stdout, rc=0.
cw_spec_resume_state() {
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
