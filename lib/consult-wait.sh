# lib/consult-wait.sh — shared outbox-wait + event-dispatch for consult
# research and verify phases. Sourced by bin/consult-research-wait.sh
# and bin/consult-verify-wait.sh. Depends on:
#   lib/log.sh lib/state.sh lib/ipc.sh lib/contracts.sh lib/consult.sh
# (callers source these first; not re-sourced here to avoid double-load.)
#
# Public:
#   cw_consult_wait <kind> <topic> <commander> <model>
# Where <kind> is "research", "verify", "adversary", or "experiment".

cw_consult_wait() {
  local kind="$1" topic="$2" commander="$3" model="$4"
  local state_key timeout_env_var timeout_key handler_phase
  case "$kind" in
    research)
      state_key="FS"; timeout_env_var="CW_CONSULT_RESEARCH_TIMEOUT_OVERRIDE"
      timeout_key="research"; handler_phase="research"
      ;;
    verify)
      state_key="VS"; timeout_env_var="CW_CONSULT_VERIFY_TIMEOUT_OVERRIDE"
      timeout_key="verify"; handler_phase="verify"
      ;;
    adversary)
      state_key="AS"; timeout_env_var="CW_MEDITATE_ADVERSARY_TIMEOUT_OVERRIDE"
      timeout_key="adversary"; handler_phase="adversary"
      ;;
    experiment)
      state_key="EX"; timeout_env_var="CW_DEEP_RESEARCH_EXPERIMENT_TIMEOUT_OVERRIDE"
      timeout_key="experiment"; handler_phase="experiment"
      ;;
    *) log_error "cw_consult_wait: unknown kind '$kind'"; return 2 ;;
  esac

  cw_consult_assert_topic "$topic"
  cw_consult_assert_commander "$commander"

  local art_dir state_file
  art_dir="$(cw_consult_art_dir "$topic")"
  state_file="$art_dir/$kind-$commander.txt"
  [[ -f "$state_file" ]] \
    || { log_error "$state_file missing — run consult-$kind-send first"; return 1; }

  # Verify-only short-circuit: state file already has VS=skipped.
  if [[ "$kind" == "verify" ]] && grep -q '^VS=skipped' "$state_file"; then
    log_info "[$kind-wait] $commander skipped (already)"
    touch "${state_file%.txt}.done"
    return 0
  fi

  unset OFFSET
  # shellcheck disable=SC1090
  source "$state_file"
  [[ -n "${OFFSET:-}" ]] \
    || { log_error "OFFSET not set in $state_file"; return 1; }

  local timeout
  timeout="${!timeout_env_var:-$(cw_consult_timeout "$timeout_key")}"
  log_info "[$kind-wait] $commander offset=$OFFSET timeout=${timeout}s"

  # v0.27.2 BUG #6: wrap one-shot match logic in a stale-event-skipping
  # loop. When kind==experiment, skip done events whose summary lacks the
  # expected EXP_ID (phantom dones from prior empty-inbox responses) and
  # keep polling for the EXP_ID-correct done. Other kinds (research /
  # verify / adversary) break on first match — byte-equal v0.27.1.
  local outbox tail matched event new_offset
  outbox=$(cw_outbox_path "$commander" "$model" "$topic")
  local poll_deadline=$(( $(date +%s) + timeout ))

  while :; do
    local remaining=$(( poll_deadline - $(date +%s) ))
    (( remaining > 0 )) || { matched=""; new_offset="$OFFSET"; event=""; break; }

    cw_outbox_wait_since "$commander" "$model" "$topic" "$OFFSET" \
      "done" "error" "question" "$remaining" >/dev/null || true

    # Priority + race fix:
    #   1. Terminal events (done/error) WIN over in-flight question events.
    #   2. Among questions, FIRST wins (head -n1) — serialization across re-arms.
    #   3. NEW_OFFSET is the matched line's exact end-byte (NOT wc -c).
    tail=$(tail -c "+$(( OFFSET + 1 ))" "$outbox" 2>/dev/null || true)
    matched=$(printf '%s\n' "$tail" | grep -m1 -E '"event":"(done|error)"' || true)
    [[ -z "$matched" ]] \
      && matched=$(printf '%s\n' "$tail" | grep -m1 '"event":"question"' || true)
    event=$(cw_event_name_extract "$matched")

    if [[ -n "$matched" ]]; then
      new_offset=$(cw_consult_outbox_match_endbyte "$outbox" "$OFFSET" "$matched" 2>/dev/null) \
        || new_offset="$OFFSET"
    else
      new_offset="$OFFSET"
    fi

    # EXP_ID guard: skip stale done events when kind==experiment.
    # Persist advanced OFFSET so a wait-shim restart resumes past the
    # stale event. Atomic tmp+mv preserves EXP_ID line.
    if [[ "$kind" == "experiment" && "$event" == "done" ]]; then
      local exp_id_expected
      exp_id_expected=$(awk -F= '/^EXP_ID=/ { print $2 }' "$state_file" 2>/dev/null)
      if [[ -n "$exp_id_expected" && "$matched" != *"$exp_id_expected"* ]]; then
        log_warn "[$kind-wait] $commander: stale done event ignored (expected '$exp_id_expected', got: $(printf '%.80s' "$matched"))"
        OFFSET="$new_offset"
        {
          printf 'OFFSET=%s\n' "$OFFSET"
          printf 'EXP_ID=%s\n' "$exp_id_expected"
        } > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
        continue
      fi
    fi

    break
  done

  case "$event" in
    question)
      if cw_consult_question_extract_to_payload \
           "$matched" "$art_dir/question-$commander.txt" "$handler_phase"; then
        printf 'OFFSET=%s\n' "$new_offset" >> "$state_file"
        printf '%s=question\n' "$state_key" >> "$state_file"
        log_info "[$kind-wait] $commander $state_key=question (offset → $new_offset)"
      else
        printf '%s=failed\n' "$state_key" >> "$state_file"
        log_warn "[$kind-wait] $commander $state_key=failed (malformed question payload)"
      fi
      ;;
    done)
      local status
      case "$kind" in
        research)
          status=$(cw_consult_findings_status \
            "$(cw_consult_findings_path "$commander" "$model" "$topic")")
          ;;
        verify)
          local verify_file
          verify_file=$(cw_consult_verify_path "$commander" "$model" "$topic")
          if [[ -s "$verify_file" ]]; then status=ok; else status=missing; fi
          ;;
        adversary)
          local adv_file
          adv_file="$art_dir/adversary-$commander.md"
          if [[ -s "$adv_file" ]]; then status=ok; else status=missing; fi
          ;;
        experiment)
          status=ok
          ;;
      esac
      printf '%s=%s\n' "$state_key" "$status" >> "$state_file"
      log_info "[$kind-wait] $commander $state_key=$status"
      ;;
    error)
      printf '%s=failed\n' "$state_key" >> "$state_file"
      log_warn "[$kind-wait] $commander $state_key=failed (error event)"
      ;;
    '')
      printf '%s=timeout\n' "$state_key" >> "$state_file"
      log_warn "[$kind-wait] $commander $state_key=timeout"
      ;;
    *)
      printf '%s=failed\n' "$state_key" >> "$state_file"
      log_warn "[$kind-wait] $commander $state_key=failed (unknown event '$event')"
      ;;
  esac

  # background-await sentinel: lets the directive's notification handler
  # distinguish a clean exit from a notification-arrived-before-write race.
  touch "${state_file%.txt}.done"
  return 0
}
