# lib/deploy-questions.sh — v0.50.0 deploy-side question payload extractor.
# Mirrors lib/consult.sh::cw_consult_question_extract_to_payload but writes
# the deploy payload shape with the new claim discriminator fields.

# cw_deploy_question_extract_to_payload <json-line> <payload-path>
# Validates the line via cw_trooper_question_validate_line (must be sourced
# before calling this function). Extracts text + claim.kind + claim.value
# and writes the deploy payload file:
#   TEXT=<percent-encoded text — %0A for newline>
#   CLAIM_KIND=<path|git|env|cmd|test|>  (empty when claim absent)
#   CLAIM_VALUE=<verbatim>                (empty when claim absent)
#   ROUTE=<verify|escalate>
#   ASKED_AT=<unix epoch seconds>
# rc=0 on success, rc=1 on validation failure (no payload written).
cw_deploy_question_extract_to_payload() {
  local line="$1" path="$2"
  cw_trooper_question_validate_line "$line" || return 1
  local text kind value route
  text=$(printf '%s' "$line" | sed -n 's/.*"text":"\([^"]*\)".*/\1/p')
  [[ -n "$text" ]] || return 1
  # Percent-encode newline → %0A (consult's encoding scheme).
  local encoded=${text//$'\n'/%0A}
  if printf '%s' "$line" | grep -q '"claim":{'; then
    kind=$(printf '%s' "$line" | sed -n 's/.*"claim":{[^}]*"kind":"\([a-z]*\)".*/\1/p')
    value=$(printf '%s' "$line" | sed -n 's/.*"claim":{[^}]*"value":"\([^"]*\)".*/\1/p')
    route="verify"
  else
    kind=""
    value=""
    route="escalate"
  fi
  {
    printf 'TEXT=%s\n'        "$encoded"
    printf 'CLAIM_KIND=%s\n'  "$kind"
    printf 'CLAIM_VALUE=%s\n' "$value"
    printf 'ROUTE=%s\n'       "$route"
    printf 'ASKED_AT=%s\n'    "$(date +%s)"
  } | cw_atomic_write "$path"
}
