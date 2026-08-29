#!/usr/bin/env bash
# Behavior tests for the Codex rollout-log busy source (bin/fm-busy-lib.sh).
#
# Codex has no writer and nothing is armed for it, exactly like muse and
# cursor: the classifier folds codex's own durable per-session rollout log on
# demand. These tests pin that fold and its binding, so a healthy Codex worker
# can never read as "state unavailable" again while an unbindable one still
# reads unknown rather than idle.
#
# Hermetic: every fixture is a temp rollout tree. The live counterpart that
# proves the same fold against a real codex worker is
# tests/fm-codex-busy-live-e2e.test.sh.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-busy-lib.sh
# shellcheck disable=SC1091
. "$ROOT/bin/fm-busy-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-codex-harness)

# Build a bound codex workspace: a sessions tree holding one rollout whose
# session_meta names this worktree, plus the per-task sidecar fm-spawn writes.
make_codex_binding() {  # <case> <rollout-body> [<originator>] [<source>] -> echoes <state-dir>
  local case_name=$1 body=$2 originator=${3:-codex-tui} source=${4:-cli} root ws state day
  root="$TMP_ROOT/$case_name/sessions"
  ws="$TMP_ROOT/$case_name/worktree"
  state="$TMP_ROOT/$case_name/state"
  day="$root/2026/08/29"
  mkdir -p "$day" "$ws" "$state"
  {
    printf '{"timestamp":"2026-08-29T15:00:00.000Z","type":"session_meta","payload":'
    printf '{"session_id":"s-%s","cwd":"%s","originator":"%s","source":"%s","cli_version":"0.145.0"}}\n' \
      "$case_name" "$ws" "$originator" "$source"
    printf '%s' "$body"
  } > "$day/rollout-2026-08-29T15-00-00-s-$case_name.jsonl"
  printf 'sessions_root=%s\nworkspace_root=%s\n' "$root" "$ws" > "$state/task.codex-session"
  printf '%s' "$state"
}

turn_event() {  # <type>
  printf '{"timestamp":"2026-08-29T15:00:01.000Z","type":"event_msg","payload":{"type":"%s"}}\n' "$1"
}

test_rollout_fold_brackets_a_turn() {
  local state out
  # Open turn: task_started with no close after it.
  state=$(make_codex_binding open "$(turn_event task_started)")
  out=$(fm_busy_classify tmux none codex task "$state")
  [ "$out" = "busy codex-rollout" ] || fail "an open turn must be busy, got '$out'"

  # Closed turn.
  state=$(make_codex_binding closed "$(turn_event task_started)
$(turn_event task_complete)")
  out=$(fm_busy_classify tmux none codex task "$state")
  [ "$out" = "idle codex-rollout" ] || fail "a closed turn must be idle, got '$out'"

  # An INTERRUPTED close is still a close. This is the case Claude's Stop hook
  # misses, and it is why this source is preferred over a rendered footer.
  state=$(make_codex_binding aborted "$(turn_event task_started)
$(turn_event turn_aborted)")
  out=$(fm_busy_classify tmux none codex task "$state")
  [ "$out" = "idle codex-rollout" ] || fail "an interrupted close must be idle, got '$out'"

  # A NEW turn opened after a close reopens it.
  state=$(make_codex_binding reopened "$(turn_event task_started)
$(turn_event task_complete)
$(turn_event task_started)")
  out=$(fm_busy_classify tmux none codex task "$state")
  [ "$out" = "busy codex-rollout" ] || fail "a turn reopened after a close must be busy, got '$out'"
  pass "codex rollout fold: task_started opens a turn, task_complete and turn_aborted close it"
}

test_rollout_fold_ignores_lifecycle_tokens_in_message_text() {
  local state out
  state=$(make_codex_binding quoted-lifecycle "$(turn_event task_started)
{\"timestamp\":\"2026-08-29T15:00:02.000Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"text\":\"literal task_complete and {\\\"type\\\":\\\"task_complete\\\"}\"}}")
  out=$(fm_busy_classify tmux none codex task "$state")
  [ "$out" = "busy codex-rollout" ] \
    || fail "lifecycle-shaped message text must not close an active turn, got '$out'"

  # A lifecycle name nested under the wrong envelope type is not a turn event.
  state=$(make_codex_binding wrong-envelope "$(turn_event task_started)
{\"timestamp\":\"2026-08-29T15:00:02.000Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"task_complete\"}}")
  out=$(fm_busy_classify tmux none codex task "$state")
  [ "$out" = "busy codex-rollout" ] \
    || fail "a task_complete outside an event_msg envelope must not close a turn, got '$out'"
  pass "codex rollout fold: only event_msg turn records move the fold"
}

test_unbindable_codex_is_unknown_never_idle() {
  local state out
  # No sidecar at all.
  state="$TMP_ROOT/no-sidecar/state"
  mkdir -p "$state"
  out=$(fm_busy_classify tmux none codex task "$state")
  [ "$out" = "unknown codex-rollout" ] \
    || fail "a codex task with no binding must be unknown, got '$out'"

  # A sidecar whose sessions tree holds no matching rollout.
  state="$TMP_ROOT/no-match/state"
  mkdir -p "$state" "$TMP_ROOT/no-match/sessions" "$TMP_ROOT/no-match/worktree"
  printf 'sessions_root=%s\nworkspace_root=%s\n' \
    "$TMP_ROOT/no-match/sessions" "$TMP_ROOT/no-match/worktree" > "$state/task.codex-session"
  out=$(fm_busy_classify tmux none codex task "$state")
  [ "$out" = "unknown codex-rollout" ] \
    || fail "a codex task whose rollout cannot be resolved must be unknown, got '$out'"

  # A resolvable rollout with no turn record at all proves nothing either way.
  state=$(make_codex_binding no-turns '')
  out=$(fm_busy_classify tmux none codex task "$state")
  [ "$out" = "unknown codex-rollout" ] \
    || fail "a rollout with no turn record must be unknown, got '$out'"
  pass "an unresolvable or turn-free codex rollout classifies unknown, never idle"
}

test_prior_sessions_are_excluded() {
  local state out root ws day
  state=$(make_codex_binding relaunch "$(turn_event task_started)
$(turn_event task_complete)")
  root="$TMP_ROOT/relaunch/sessions"
  ws="$TMP_ROOT/relaunch/worktree"
  day="$root/2026/08/29"
  # The pane that ran before this one left a settled rollout behind. Recording
  # it as prior keeps this pane from folding its predecessor's turn.
  printf 'prior_session=%s\n' "$day/rollout-2026-08-29T15-00-00-s-relaunch.jsonl" \
    >> "$state/task.codex-session"
  {
    printf '{"timestamp":"2026-08-29T16:00:00.000Z","type":"session_meta","payload":'
    printf '{"session_id":"s-new","cwd":"%s","originator":"codex-tui","source":"cli","cli_version":"0.145.0"}}\n' "$ws"
    turn_event task_started
  } > "$day/rollout-2026-08-29T16-00-00-s-new.jsonl"
  out=$(fm_busy_classify tmux none codex task "$state")
  [ "$out" = "busy codex-rollout" ] \
    || fail "a relaunched pane must fold its own rollout, not its predecessor's, got '$out'"

  # Two unclaimed rollouts cannot be told apart, so neither is trusted.
  {
    printf '{"timestamp":"2026-08-29T17:00:00.000Z","type":"session_meta","payload":'
    printf '{"session_id":"s-third","cwd":"%s","originator":"codex-tui","source":"cli","cli_version":"0.145.0"}}\n' "$ws"
    turn_event task_complete
  } > "$day/rollout-2026-08-29T17-00-00-s-third.jsonl"
  out=$(fm_busy_classify tmux none codex task "$state")
  [ "$out" = "unknown codex-rollout" ] \
    || fail "an ambiguous codex binding must be unknown, got '$out'"
  pass "the codex binding excludes prior sessions and refuses an ambiguous match"
}

# The classifier runs on every redraw for every codex task, so it scans only
# codex's own YYYY/MM/DD directories at or after the day the pane launched.
# A rollout older than that cannot be this pane's, and a sidecar written before
# that bound existed must still scan the whole tree.
test_day_bound_excludes_rollouts_older_than_the_pane() {
  local state out root ws day older
  state=$(make_codex_binding day-bound "$(turn_event task_started)
$(turn_event task_complete)")
  root="$TMP_ROOT/day-bound/sessions"
  ws="$TMP_ROOT/day-bound/worktree"
  older="$root/2026/07/04"
  mkdir -p "$older"
  # A settled rollout for the same worktree from long before this pane. Without
  # a bound it is a second unclaimed match and the binding goes ambiguous.
  {
    printf '{"timestamp":"2026-07-04T10:00:00.000Z","type":"session_meta","payload":'
    printf '{"session_id":"s-old","cwd":"%s","originator":"codex-tui","source":"cli","cli_version":"0.145.0"}}\n' "$ws"
    turn_event task_started
  } > "$older/rollout-2026-07-04T10-00-00-s-old.jsonl"
  out=$(fm_busy_classify tmux none codex task "$state")
  [ "$out" = "unknown codex-rollout" ] \
    || fail "with no recorded bound an older rollout must still be seen and make this ambiguous, got '$out'"

  printf 'sessions_from=2026/08/28\n' >> "$state/task.codex-session"
  out=$(fm_busy_classify tmux none codex task "$state")
  [ "$out" = "idle codex-rollout" ] \
    || fail "a rollout older than the recorded bound must be skipped, got '$out'"

  # The bound never hides a LATER day: a pane that runs past midnight keeps
  # folding its own turns.
  day="$root/2026/08/30"
  mkdir -p "$day"
  {
    printf '{"timestamp":"2026-08-30T10:00:00.000Z","type":"session_meta","payload":'
    printf '{"session_id":"s-next","cwd":"%s","originator":"codex-tui","source":"cli","cli_version":"0.145.0"}}\n' "$ws"
    turn_event task_started
  } > "$day/rollout-2026-08-30T10-00-00-s-next.jsonl"
  out=$(fm_busy_classify tmux none codex task "$state")
  [ "$out" = "unknown codex-rollout" ] \
    || fail "a later day must stay in scope, so two unclaimed rollouts must read ambiguous, got '$out'"
  pass "the rollout scan is bounded to the pane's own launch day onward, and never hides a later day"
}

test_codex_binding_is_scoped_to_its_own_worktree() {
  local state out root day other
  state=$(make_codex_binding scoped "$(turn_event task_started)")
  root="$TMP_ROOT/scoped/sessions"
  day="$root/2026/08/29"
  other="$TMP_ROOT/scoped/other-worktree"
  mkdir -p "$other"
  # A busy session in a DIFFERENT directory must not reach this task's verdict.
  {
    printf '{"timestamp":"2026-08-29T16:00:00.000Z","type":"session_meta","payload":'
    printf '{"session_id":"s-other","cwd":"%s","originator":"codex-tui","source":"cli","cli_version":"0.145.0"}}\n' "$other"
    turn_event task_started
  } > "$day/rollout-2026-08-29T16-00-00-s-other.jsonl"
  out=$(fm_busy_classify tmux none codex task "$state")
  [ "$out" = "busy codex-rollout" ] \
    || fail "another worktree's rollout must not disturb this binding, got '$out'"

  # And the reverse: this task's own settled turn is not overridden by it.
  state=$(make_codex_binding scoped-idle "$(turn_event task_started)
$(turn_event task_complete)")
  root="$TMP_ROOT/scoped-idle/sessions"
  day="$root/2026/08/29"
  other="$TMP_ROOT/scoped-idle/other-worktree"
  mkdir -p "$other"
  {
    printf '{"timestamp":"2026-08-29T16:00:00.000Z","type":"session_meta","payload":'
    printf '{"session_id":"s-other","cwd":"%s","originator":"codex-tui","source":"cli","cli_version":"0.145.0"}}\n' "$other"
    turn_event task_started
  } > "$day/rollout-2026-08-29T16-00-00-s-other.jsonl"
  out=$(fm_busy_classify tmux none codex task "$state")
  [ "$out" = "idle codex-rollout" ] \
    || fail "another worktree's open turn must not make this task busy, got '$out'"
  pass "the codex fold is scoped to the rollout whose recorded cwd is this task's worktree"
}

test_rollout_session_requires_both_interactive_identity_fields() {
  local state out
  state=$(make_codex_binding wrong-source "$(turn_event task_started)" codex-tui exec)
  out=$(fm_busy_classify tmux none codex task "$state")
  [ "$out" = "unknown codex-rollout" ] \
    || fail "originator=codex-tui without source=cli must not identify the pane session, got '$out'"

  state=$(make_codex_binding wrong-originator "$(turn_event task_started)" codex-exec cli)
  out=$(fm_busy_classify tmux none codex task "$state")
  [ "$out" = "unknown codex-rollout" ] \
    || fail "source=cli without originator=codex-tui must not identify the pane session, got '$out'"
  pass "a codex rollout matches only when both interactive identity fields agree"
}

test_codex_never_classifies_from_rendered_text_or_native_state() {
  local state out
  state=$(make_codex_binding rendered "$(turn_event task_started)
$(turn_event task_complete)")
  out=$(fm_busy_classify tmux w1 codex task "$state" '• Working (6s • esc to interrupt)
Ctrl+c:cancel')
  [ "$out" = "idle codex-rollout" ] \
    || fail "codex must not classify from rendered footer text, got '$out'"
  [ -z "$(fm_busy_sources_for_harness codex)" ] \
    || fail "codex must trust no stored record source; its fold has no writer"
  pass "codex classifies only from its rollout fold, never rendered text or a stored record"
}

test_rollout_fold_needs_jq_and_fails_closed_without_it() {
  local state out no_jq_bin
  state=$(make_codex_binding needs-jq "$(turn_event task_started)")
  no_jq_bin="$TMP_ROOT/no-jq-bin"
  mkdir -p "$no_jq_bin"
  for tool in awk sed grep cat head find sort; do
    if command -v "$tool" >/dev/null 2>&1; then
      ln -sf "$(command -v "$tool")" "$no_jq_bin/$tool"
    fi
  done
  out=$(PATH="$no_jq_bin" fm_busy_classify tmux none codex task "$state")
  [ "$out" = "unknown codex-rollout" ] \
    || fail "without jq the codex fold must report unknown, not a guess, got '$out'"
  pass "the codex fold reports unknown rather than guessing when jq is unavailable"
}

test_rollout_fold_brackets_a_turn
test_rollout_fold_ignores_lifecycle_tokens_in_message_text
test_unbindable_codex_is_unknown_never_idle
test_prior_sessions_are_excluded
test_day_bound_excludes_rollouts_older_than_the_pane
test_codex_binding_is_scoped_to_its_own_worktree
test_rollout_session_requires_both_interactive_identity_fields
test_codex_never_classifies_from_rendered_text_or_native_state
test_rollout_fold_needs_jq_and_fails_closed_without_it
