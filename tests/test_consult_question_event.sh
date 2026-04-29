#!/usr/bin/env bash
# tests/test_consult_question_event.sh — Task 5 (v0.3.0).
# Payload helpers + validator + extractor.
set -euo pipefail
cd "$(dirname "$0")"
source lib/assert.sh
source ../lib/consult.sh

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# 1. Write + read payload round-trip (free-form question, no options).
cw_consult_question_payload_write "$TMP/q.txt" \
  "Should we use Postgres or DynamoDB for the metadata store?" "" "research"

[[ -f "$TMP/q.txt" ]] || { echo "FAIL: payload file not written" >&2; exit 1; }
grep -q '^TEXT='     "$TMP/q.txt" || { echo "FAIL: TEXT= line missing"     >&2; exit 1; }
grep -q '^PHASE='    "$TMP/q.txt" || { echo "FAIL: PHASE= line missing"    >&2; exit 1; }
grep -q '^ASKED_AT=' "$TMP/q.txt" || { echo "FAIL: ASKED_AT= line missing" >&2; exit 1; }
pass "payload write produces TEXT/PHASE/ASKED_AT lines"

read_text=$(cw_consult_question_payload_read "$TMP/q.txt" TEXT)
[[ "$read_text" == "Should we use Postgres or DynamoDB for the metadata store?" ]] \
  || { echo "FAIL: read text mismatch: '$read_text'" >&2; exit 1; }
pass "payload read TEXT round-trips"

read_phase=$(cw_consult_question_payload_read "$TMP/q.txt" PHASE)
assert_eq "$read_phase" "research" "PHASE round-trip"
pass "payload read PHASE round-trips"

# 2. Multi-line text gets percent-encoded then decoded back.
cw_consult_question_payload_write "$TMP/q2.txt" \
  $'Line one\nLine two\nLine three' "A|B" "verify"
read_text2=$(cw_consult_question_payload_read "$TMP/q2.txt" TEXT)
[[ "$read_text2" == $'Line one\nLine two\nLine three' ]] \
  || { echo "FAIL: multi-line round-trip broken: $(printf '%q' "$read_text2")" >&2; exit 1; }
pass "multi-line text round-trips via %0A encoding"

# 2a. All four percent-encodings decode in TEXT.
cat > "$TMP/q2a.txt" <<'PAY'
TEXT=He said %22hi%22%0Athen left a path C:%5Cusers%09tab
PHASE=research
ASKED_AT=0
PAY
read_text2a=$(cw_consult_question_payload_read "$TMP/q2a.txt" TEXT)
expected=$'He said "hi"\nthen left a path C:\\users\ttab'
[[ "$read_text2a" == "$expected" ]] \
  || { echo "FAIL: 4-encoding decoder broken — got: $(printf '%q' "$read_text2a")" >&2; exit 1; }
pass "decoder: %0A %09 %22 %5C all decode correctly in TEXT"

# 2b. Same encodings decode in OPTIONS too.
cat > "$TMP/q2b.txt" <<'PAY'
TEXT=x
OPTIONS=op%22A%22|op%22B%22
PHASE=research
ASKED_AT=0
PAY
read_opts2b=$(cw_consult_question_payload_read "$TMP/q2b.txt" OPTIONS)
[[ "$read_opts2b" == 'op"A"|op"B"' ]] \
  || { echo "FAIL: OPTIONS decoder broken — got: $read_opts2b" >&2; exit 1; }
pass "decoder: OPTIONS field also decodes %22 (and other encodings)"

# 2c. Literal-percent: %2522 → %22 (literal), not '"'.
cat > "$TMP/q2c.txt" <<'PAY'
TEXT=trooper meant the literal string %2522 here
PHASE=research
ASKED_AT=0
PAY
read_text2c=$(cw_consult_question_payload_read "$TMP/q2c.txt" TEXT)
[[ "$read_text2c" == "trooper meant the literal string %22 here" ]] \
  || { echo "FAIL: %2522 → %22 broken — got: $read_text2c" >&2; exit 1; }
pass "literal-percent: %2522 decodes to %22 (literal), not '\"'"

# 2d. Single literal percent: %25 → %.
cat > "$TMP/q2d.txt" <<'PAY'
TEXT=100%25 done
PHASE=research
ASKED_AT=0
PAY
read_text2d=$(cw_consult_question_payload_read "$TMP/q2d.txt" TEXT)
[[ "$read_text2d" == "100% done" ]] \
  || { echo "FAIL: %25 → % broken — got: $read_text2d" >&2; exit 1; }
pass "literal-percent: %25 decodes to literal %"

# 2e. Combined: %25 + other encodings should not interfere.
cat > "$TMP/q2e.txt" <<'PAY'
TEXT=mix %22quoted%22 with %25 percent
PHASE=research
ASKED_AT=0
PAY
read_text2e=$(cw_consult_question_payload_read "$TMP/q2e.txt" TEXT)
[[ "$read_text2e" == 'mix "quoted" with % percent' ]] \
  || { echo "FAIL: mixed-encoding broken — got: $read_text2e" >&2; exit 1; }
pass "literal-percent: mixed %22 + %25 in one string decodes correctly"

# 3. OPTIONS line round-trips.
read_opts=$(cw_consult_question_payload_read "$TMP/q2.txt" OPTIONS)
assert_eq "$read_opts" "A|B" "OPTIONS round-trip"
pass "OPTIONS pipe-list round-trips"

# 4. Missing OPTIONS produces empty string.
read_opts_empty=$(cw_consult_question_payload_read "$TMP/q.txt" OPTIONS)
[[ -z "$read_opts_empty" ]] || { echo "FAIL: missing OPTIONS should be empty: '$read_opts_empty'" >&2; exit 1; }
pass "missing OPTIONS reads as empty"

# === Validator ===
# 5. Valid question line passes validation.
cw_consult_question_validate_line '{"event":"question","text":"hi","options":["A"]}' \
  || { echo "FAIL: valid question line should pass validation" >&2; exit 1; }
pass "valid question line validates"

# 6. Missing text field fails validation.
cw_consult_question_validate_line '{"event":"question","options":["A"]}' \
  && { echo "FAIL: missing text should fail validation" >&2; exit 1; } || true
pass "missing text fails validation"

# 7. Empty text fails validation.
cw_consult_question_validate_line '{"event":"question","text":"","options":["A"]}' \
  && { echo "FAIL: empty text should fail validation" >&2; exit 1; } || true
pass "empty text fails validation"

# 8. Non-question event fails validation.
cw_consult_question_validate_line '{"event":"done"}' \
  && { echo "FAIL: non-question event should fail validation" >&2; exit 1; } || true
pass "non-question event fails validation"

# 9. extract_to_payload writes payload only on valid input.
cw_consult_question_extract_to_payload '{"event":"question","text":"ok","options":["yes","no"]}' \
  "$TMP/q3.txt" "research"
[[ -f "$TMP/q3.txt" ]] || { echo "FAIL: payload should be written on valid input" >&2; exit 1; }
assert_eq "$(cw_consult_question_payload_read "$TMP/q3.txt" TEXT)"    "ok"        "extract TEXT round-trip"
assert_eq "$(cw_consult_question_payload_read "$TMP/q3.txt" OPTIONS)" "yes|no"    "extract OPTIONS pipe-encoded"
pass "extract_to_payload writes valid payload"

# 10. extract_to_payload refuses malformed input — no file written.
rm -f "$TMP/q4.txt"
cw_consult_question_extract_to_payload '{"event":"question","options":[]}' \
  "$TMP/q4.txt" "research" && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: extract should fail on missing text" >&2; exit 1; }
[[ ! -f "$TMP/q4.txt" ]] || { echo "FAIL: payload should not be written on malformed input" >&2; exit 1; }
pass "extract_to_payload rejects missing-text input"

# 11. Empty options array → OPTIONS empty.
cw_consult_question_extract_to_payload '{"event":"question","text":"x","options":[]}' \
  "$TMP/q5.txt" "research"
[[ -z "$(cw_consult_question_payload_read "$TMP/q5.txt" OPTIONS)" ]] \
  || { echo "FAIL: empty options should produce empty OPTIONS" >&2; exit 1; }
pass "empty options array round-trips as empty OPTIONS"

# 11a. Literal comma in option text → validator REJECTS.
cw_consult_question_validate_line \
  '{"event":"question","text":"x","options":["Use Postgres, not MySQL","Use SQLite"]}' \
  && { echo "FAIL: literal comma in option must be rejected" >&2; exit 1; } || true
pass "comma-rejection: literal comma in option fails validation"

# 11b. Trooper using %2C for literal comma → accepted, decodes correctly.
cw_consult_question_extract_to_payload \
  '{"event":"question","text":"choose backend","options":["Use Postgres%2C not MySQL","Use SQLite"]}' \
  "$TMP/q5b.txt" "research"
read_opts5b=$(cw_consult_question_payload_read "$TMP/q5b.txt" OPTIONS)
[[ "$read_opts5b" == 'Use Postgres, not MySQL|Use SQLite' ]] \
  || { echo "FAIL: %2C decoding broken; got: $read_opts5b" >&2; exit 1; }
pass "%2C decoding: option with %2C round-trips with literal comma"

# 11c. Two options no commas → standard split.
cw_consult_question_extract_to_payload \
  '{"event":"question","text":"x","options":["A","B"]}' \
  "$TMP/q5c.txt" "research"
read_opts5c=$(cw_consult_question_payload_read "$TMP/q5c.txt" OPTIONS)
[[ "$read_opts5c" == 'A|B' ]] \
  || { echo "FAIL: basic 2-option split broken; got: $read_opts5c" >&2; exit 1; }
pass "baseline: basic 2-option split still works"

# 11d. extract_to_payload refuses comma-bearing options — no payload.
rm -f "$TMP/q5d.txt"
cw_consult_question_extract_to_payload \
  '{"event":"question","text":"x","options":["Use Postgres, not MySQL"]}' \
  "$TMP/q5d.txt" "research" && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: extract should fail on un-encoded comma" >&2; exit 1; }
[[ ! -f "$TMP/q5d.txt" ]] || { echo "FAIL: payload should not be written" >&2; exit 1; }
pass "extract refuses to write payload with comma-bearing options"

# === Escaped-quote fail-closed (Codex Rev2 M5) ===
# 12. Escaped quotes in text → validator REJECTS.
cw_consult_question_validate_line '{"event":"question","text":"He said \"hi\"","options":[]}' \
  && { echo "FAIL: escaped-quote text should fail validation" >&2; exit 1; } || true
pass "escaped-quote fail-closed: payload with \\\" rejected"

# 13. Backslash in text → also rejected.
cw_consult_question_validate_line '{"event":"question","text":"line1\nline2","options":[]}' \
  && { echo "FAIL: backslash text should fail validation" >&2; exit 1; } || true
pass "backslash fail-closed: payload with \\n rejected"

# 14. extract_to_payload rejects escaped-quote input — no payload written.
rm -f "$TMP/q6.txt"
cw_consult_question_extract_to_payload \
  '{"event":"question","text":"He said \"hi\"","options":[]}' "$TMP/q6.txt" "research" \
  && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: extract should fail on escaped-quote input" >&2; exit 1; }
[[ ! -f "$TMP/q6.txt" ]] || { echo "FAIL: payload should not be written for escaped-quote" >&2; exit 1; }
pass "escaped-quote: extract refuses to write payload"

# === ASCII-only enforcement (Codex Rev3 H2) ===
# 15. Non-ASCII (UTF-8 emoji) in text → validator REJECTS.
cw_consult_question_validate_line $'{"event":"question","text":"emoji \xf0\x9f\x98\x80","options":[]}' \
  && { echo "FAIL: non-ASCII text should fail validation" >&2; exit 1; } || true
pass "ASCII-only: emoji text rejected"

# 16. ASCII-only text passes (regression).
cw_consult_question_validate_line '{"event":"question","text":"plain ascii","options":[]}' \
  || { echo "FAIL: plain ASCII should still pass" >&2; exit 1; }
pass "ASCII-only: plain text still accepted"

# 17. extract_to_payload rejects non-ASCII — no payload written.
rm -f "$TMP/q7.txt"
cw_consult_question_extract_to_payload \
  $'{"event":"question","text":"emoji \xf0\x9f\x98\x80","options":[]}' "$TMP/q7.txt" "research" \
  && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "FAIL: extract should fail on emoji input" >&2; exit 1; }
[[ ! -f "$TMP/q7.txt" ]] || { echo "FAIL: emoji payload should not be written" >&2; exit 1; }
pass "ASCII-only: extract refuses emoji payload"

# 18. cw_consult_outbox_match_endbyte byte-mode arithmetic (defensive).
TMP_BOX=$(mktemp); trap "rm -rf $TMP $TMP_BOX" EXIT
echo '{"event":"ack"}' > "$TMP_BOX"
START=$(wc -c < "$TMP_BOX" | tr -d ' ')
EMOJI_LINE=$'{"event":"done","note":"\xf0\x9f\x98\x80 emoji included"}'
echo "$EMOJI_LINE" >> "$TMP_BOX"
EXPECTED_END=$(wc -c < "$TMP_BOX" | tr -d ' ')
ACTUAL_END=$(cw_consult_outbox_match_endbyte "$TMP_BOX" "$START" "$EMOJI_LINE")
[[ "$ACTUAL_END" == "$EXPECTED_END" ]] \
  || { echo "FAIL: outbox_match_endbyte byte-mode broken; got $ACTUAL_END expected $EXPECTED_END" >&2; exit 1; }
pass "byte-mode: cw_consult_outbox_match_endbyte advances by bytes (LC_ALL=C)"
