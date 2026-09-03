#!/usr/bin/env bash
# Behavioral regressions for backlog lifecycle guards and startup repair.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INTEGRITY="$ROOT/bin/fm-backlog-integrity.sh"
TMP_ROOT=$(fm_test_tmproot fm-backlog-integrity)

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }
REAL_TASKS_AXI=$(command -v tasks-axi)

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  printf '%s\n' "$home"
}

run_integrity() {
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$INTEGRITY" "$@"
}

test_finished_row_cannot_be_resurrected() {
  local home rc state
  home=$(make_home finished-start)
  (cd "$home" && tasks-axi add finished-task "Finished task" >/dev/null && tasks-axi done finished-task >/dev/null)
  set +e
  run_integrity "$home" start finished-task > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "guard restarted a completed row"
  assert_grep 'refusing to start completed task finished-task' "$home/err" \
    "completed-row regression did not exercise the lifecycle guard"
  state=$(cd "$home" && tasks-axi show finished-task | sed -n 's/^  state: //p')
  [ "$state" = done ] || fail "completed row was resurrected as $state"
  pass "completed row remains done when dispatch start is retried"
}

test_three_orphans_are_repaired_without_blinding() {
  local home id json
  home=$(make_home three-orphans)
  for id in custody-reconcile-pr56-strict-identity fleet-panel-shows-stale-and-unreadable-s-f7 115-cockpit-e2e-fails-outside-ci; do
    (cd "$home" && tasks-axi add "$id" "$id" --start >/dev/null)
  done
  json=$(FM_HOME="$home" "$ROOT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary)
  printf '%s' "$json" | jq -e '.state == "unknown" and .invalidity.kind == "orphan_in_flight" and (.invalidity.ids | length) == 3' >/dev/null \
    || fail "real three-orphan blinding condition was not reproduced: $json"
  run_integrity "$home" reconcile > "$home/reconcile"
  json=$(FM_HOME="$home" "$ROOT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary)
  printf '%s' "$json" | jq -e '.invalidity.kind != "orphan_in_flight"' >/dev/null \
    || fail "three orphan rows still blind the home: $json"
  for id in custody-reconcile-pr56-strict-identity fleet-panel-shows-stale-and-unreadable-s-f7 115-cockpit-e2e-fails-outside-ci; do
    [ "$(cd "$home" && tasks-axi show "$id" | sed -n 's/^  state: //p')" = queued ] \
      || fail "unlanded orphan $id was closed rather than reopened"
  done
  pass "three vanished unlanded workers reopen and no longer blind the home"
}

test_resolved_blocker_edge_is_removed() {
  local home
  home=$(make_home stale-edge)
  (cd "$home" && tasks-axi add 076-retarget-firstmate-prs-to-fork "obsolete blocker" >/dev/null \
    && tasks-axi add 081-backfill-linear-pr-links "blocked work" >/dev/null \
    && tasks-axi block 081-backfill-linear-pr-links --by 076-retarget-firstmate-prs-to-fork >/dev/null \
    && tasks-axi done 076-retarget-firstmate-prs-to-fork >/dev/null)
  (cd "$home" && tasks-axi show 081-backfill-linear-pr-links | grep -F 'deps: "blocked-by:076-retarget-firstmate-prs-to-fork"' >/dev/null) \
    || fail "081 -> 076 stale edge was not reproduced"
  run_integrity "$home" reconcile >/dev/null
  (cd "$home" && tasks-axi show 081-backfill-linear-pr-links | grep -F 'deps: none' >/dev/null) \
    || fail "resolved 076 blocker edge still remains on 081"
  pass "resolved blocker edges are removed on reconciliation"
}

test_failed_outcome_is_never_closed_as_done() {
  local home
  home=$(make_home failed-outcome)
  (cd "$home" && tasks-axi add failed-task "Failed task" --start >/dev/null)
  run_integrity "$home" failed failed-task
  [ "$(cd "$home" && tasks-axi show failed-task | sed -n 's/^  state: //p')" = queued ] \
    || fail "failed task was recorded as completed"
  pass "failed work is reopened instead of being falsely recorded done"
}

test_partial_scout_report_does_not_close_orphan() {
  local home id=partial-scout
  home=$(make_home partial-scout)
  (cd "$home" && tasks-axi add "$id" "$id" --kind scout --start >/dev/null)
  mkdir -p "$home/data/$id"
  printf 'Investigation started.\n' > "$home/data/$id/report.md"
  printf 'working: collecting evidence\n' > "$home/state/$id.status"
  run_integrity "$home" reconcile >/dev/null
  [ "$(cd "$home" && tasks-axi show "$id" | sed -n 's/^  state: //p')" = queued ] \
    || fail "partial scout report closed abandoned work"
  pass "partial scout reports cannot close abandoned work"
}

test_unreadable_blocker_is_not_cleared() {
  local home fakebin rc
  home=$(make_home unreadable-blocker)
  (cd "$home" && tasks-axi add blocker-live "blocker" >/dev/null \
    && tasks-axi add dependent "dependent" >/dev/null \
    && tasks-axi block dependent --by blocker-live >/dev/null)
  fakebin="$home/fakebin"
  mkdir -p "$fakebin"
  printf '%s\n' '#!/usr/bin/env bash' \
    'if [ "${1:-}" = show ] && [ "${2:-}" = blocker-live ]; then echo transient read failure >&2; exit 1; fi' \
    'exec "$REAL_TASKS_AXI" "$@"' > "$fakebin/tasks-axi"
  chmod +x "$fakebin/tasks-axi"
  set +e
  REAL_TASKS_AXI="$REAL_TASKS_AXI" PATH="$fakebin:$PATH" run_integrity "$home" reconcile >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "unreadable blocker did not fail reconciliation"
  (cd "$home" && tasks-axi show dependent | grep -F 'blocked-by:blocker-live' >/dev/null) \
    || fail "unreadable blocker was cleared as resolved"
  pass "unreadable blocker records fail closed without clearing edges"
}

test_invalid_landing_receipts_do_not_close_orphans() {
  local home id
  home=$(make_home invalid-receipts)
  id=invalid-pr
  (cd "$home" && tasks-axi add "$id" "$id" --start >/dev/null)
  mkdir -p "$home/data/pr-merges"
  printf '%s\n' 'schema=fm-pr-merge.v2' "task_id=$id" 'pr=https://github.com/example/repo/pull/1' \
    'spawned_at=2026-09-02T12:00:00Z' 'phase=merged' 'authorization=live-meta' \
    'prepared_epoch=1' 'merged_at=2026-09-02T12:01:00Z' 'phase=merged' \
    > "$home/data/pr-merges/$id.receipt"
  id=invalid-local
  (cd "$home" && tasks-axi add "$id" "$id" --start >/dev/null)
  mkdir -p "$home/data/local-landings"
  printf '%s\n' 'schema=fm-local-landing.v1' 'task_id=another-launch' \
    'spawned_at=2026-09-02T12:00:00Z' 'project=/project' 'branch=topic' \
    'default_branch=main' 'before_sha=1111111111111111111111111111111111111111' \
    'landed_sha=2222222222222222222222222222222222222222' 'phase=landed' \
    'event_at=2026-09-02T12:01:00Z' > "$home/data/local-landings/$id.receipt"
  run_integrity "$home" reconcile >/dev/null
  for id in invalid-pr invalid-local; do
    [ "$(cd "$home" && tasks-axi show "$id" | sed -n 's/^  state: //p')" = queued ] \
      || fail "invalid receipt closed orphan $id"
  done
  pass "invalid and launch-mismatched receipts cannot close orphan work"
}

test_landing_receipt_must_match_durable_launch() {
  local home id=valid-pr result
  home=$(make_home valid-launch)
  (cd "$home" && tasks-axi add "$id" "$id" --start >/dev/null)
  printf '%s\n' 'schema=fm-task-launch.v1' "task_id=$id" \
    'spawned_at=2026-09-02T12:00:00Z' > "$home/state/$id.launch-receipt"
  mkdir -p "$home/data/pr-merges"
  printf '%s\n' 'schema=fm-pr-merge.v2' "task_id=$id" 'pr=https://github.com/example/repo/pull/1' \
    'spawned_at=2026-09-02T12:00:00Z' 'phase=merged' 'authorization=live-meta' \
    'prepared_epoch=1' 'merged_at=2026-09-02T12:01:00Z' \
    > "$home/data/pr-merges/$id.receipt"
  result=$(run_integrity "$home" reconcile)
  [ "$(cd "$home" && tasks-axi show "$id" | sed -n 's/^  state: //p')" = done ] \
    || fail "valid launch-bound merged receipt did not close orphan $id: $result"
  pass "valid merged receipt closes only its bound launch"
}

test_failed_start_does_not_poison_retry_binding() {
  local home id=retry-start fakebin rc
  home=$(make_home failed-start-retry)
  fakebin="$home/fakebin"
  mkdir -p "$fakebin"
  printf '%s\n' '#!/usr/bin/env bash' \
    'if [ "${1:-}" = start ] && [ -f "$FM_FAIL_START_ONCE" ]; then' \
    '  rm -f "$FM_FAIL_START_ONCE"' \
    '  exit 1' \
    'fi' \
    'exec "$REAL_TASKS_AXI" "$@"' > "$fakebin/tasks-axi"
  chmod +x "$fakebin/tasks-axi"
  (cd "$home" && tasks-axi add "$id" "$id" >/dev/null)
  printf 'spawned_at=2026-09-02T12:00:00Z\n' > "$home/state/$id.meta"
  : > "$home/fail-start-once"
  set +e
  REAL_TASKS_AXI="$REAL_TASKS_AXI" FM_FAIL_START_ONCE="$home/fail-start-once" \
    PATH="$fakebin:$PATH" run_integrity "$home" start "$id" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "simulated backlog start failure unexpectedly succeeded"
  [ ! -e "$home/state/$id.launch-receipt" ] || fail "failed start left a poisoned launch binding"
  printf 'spawned_at=2026-09-02T12:05:00Z\n' > "$home/state/$id.meta"
  run_integrity "$home" start "$id"
  [ "$(cd "$home" && tasks-axi show "$id" | sed -n 's/^  state: //p')" = in_flight ] \
    || fail "fresh dispatch could not retry after start failure"
  grep -Fx 'spawned_at=2026-09-02T12:05:00Z' "$home/state/$id.launch-receipt" >/dev/null \
    || fail "retry did not publish the fresh launch identity"
  pass "failed backlog start leaves no binding that poisons retry"
}

test_finished_row_cannot_be_resurrected
test_three_orphans_are_repaired_without_blinding
test_resolved_blocker_edge_is_removed
test_failed_outcome_is_never_closed_as_done
test_partial_scout_report_does_not_close_orphan
test_unreadable_blocker_is_not_cleared
test_invalid_landing_receipts_do_not_close_orphans
test_landing_receipt_must_match_durable_launch
test_failed_start_does_not_poison_retry_binding
echo '# all fm-backlog-integrity tests passed'
