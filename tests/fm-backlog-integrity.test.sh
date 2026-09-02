#!/usr/bin/env bash
# Behavioral regressions for backlog lifecycle guards and startup repair.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INTEGRITY="$ROOT/bin/fm-backlog-integrity.sh"
TMP_ROOT=$(fm_test_tmproot fm-backlog-integrity)

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

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

test_finished_row_cannot_be_resurrected
test_three_orphans_are_repaired_without_blinding
test_resolved_blocker_edge_is_removed
test_failed_outcome_is_never_closed_as_done
echo '# all fm-backlog-integrity tests passed'
