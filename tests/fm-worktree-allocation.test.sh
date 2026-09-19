#!/usr/bin/env bash
# Behavioral coverage for bin/fm-worktree-allocation.sh's read-only `released`
# query: it answers 0 only when the ledger holds a release for exactly that
# task and worktree after its latest acquire (and at or after the optional
# since bound), never writes the ledger, and never reads a missing, malformed,
# or foreign ledger as released.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ALLOC="$ROOT/bin/fm-worktree-allocation.sh"
TMP_ROOT=$(fm_test_tmproot fm-worktree-allocation-tests)

alloc() {  # <case-dir> <args...>
  local case_dir=$1
  shift
  FM_DATA_OVERRIDE="$case_dir/data" FM_STATE_OVERRIDE="$case_dir/state" "$ALLOC" "$@"
}

ledger_path() {  # <case-dir>
  printf '%s\n' "$1"/data/worktree-allocations/*.jsonl
}

make_case() {  # <name>
  local case_dir="$TMP_ROOT/$1"
  mkdir -p "$case_dir/data" "$case_dir/state" "$case_dir/project" "$case_dir/wt"
  printf '%s\n' "$case_dir"
}

test_released_follows_the_ledger_events() {
  local case_dir rc proj wt before after
  case_dir=$(make_case events)
  proj="$case_dir/project"
  wt="$case_dir/wt"

  rc=0; alloc "$case_dir" released task-a "$proj" "$wt" || rc=$?
  expect_code 1 "$rc" "released: a missing ledger must not read as released"
  [ ! -e "$case_dir/data/worktree-allocations" ] \
    || fail "released: the query created the ledger directory"

  alloc "$case_dir" initialize "$proj" 2026-09-17T18:00:00Z complete || fail "initialize failed"
  rc=0; alloc "$case_dir" released task-a "$proj" "$wt" || rc=$?
  expect_code 1 "$rc" "released: a task with no events must not read as released"

  alloc "$case_dir" acquire task-a "$proj" "$wt" 2026-09-17T19:00:00Z reused >/dev/null || fail "acquire failed"
  rc=0; alloc "$case_dir" released task-a "$proj" "$wt" || rc=$?
  expect_code 1 "$rc" "released: an unreleased hold must not read as released"

  alloc "$case_dir" release task-a "$proj" "$wt" 2026-09-17T20:00:00Z || fail "release failed"
  before=$(cat "$(ledger_path "$case_dir")")
  rc=0; alloc "$case_dir" released task-a "$proj" "$wt" || rc=$?
  expect_code 0 "$rc" "released: a recorded release after the acquire must read as released"
  after=$(cat "$(ledger_path "$case_dir")")
  [ "$before" = "$after" ] || fail "released: the query changed the ledger"
  [ ! -e "$case_dir/state/.worktree-allocation.lock" ] \
    || fail "released: the query left the allocation lock behind"

  rc=0; alloc "$case_dir" released task-b "$proj" "$wt" || rc=$?
  expect_code 1 "$rc" "released: another task's release must not count for this task"
  rc=0; alloc "$case_dir" released task-a "$proj" "$case_dir/other-wt" || rc=$?
  expect_code 1 "$rc" "released: a release of another worktree must not count"
  rc=0; alloc "$case_dir" released task-a "$case_dir/other-project" "$wt" || rc=$?
  expect_code 1 "$rc" "released: another project's ledger must not answer for this one"

  alloc "$case_dir" acquire task-a "$proj" "$wt" 2026-09-17T21:00:00Z reused >/dev/null || fail "reacquire failed"
  rc=0; alloc "$case_dir" released task-a "$proj" "$wt" || rc=$?
  expect_code 1 "$rc" "released: a release before the latest acquire must not read as released"

  alloc "$case_dir" release task-a "$proj" "$wt" 2026-09-17T22:00:00Z || fail "second release failed"
  rc=0; alloc "$case_dir" released task-a "$proj" "$wt" || rc=$?
  expect_code 0 "$rc" "released: a release after the reacquire must read as released"
  pass "released answers from the task's own release after its latest acquire without writing the ledger"
}

test_released_since_bound_excludes_older_releases() {
  local case_dir rc proj wt
  case_dir=$(make_case since)
  proj="$case_dir/project"
  wt="$case_dir/wt"
  alloc "$case_dir" initialize "$proj" 2026-09-17T18:00:00Z complete || fail "initialize failed"
  alloc "$case_dir" acquire task-a "$proj" "$wt" 2026-09-17T19:00:00Z reused >/dev/null || fail "acquire failed"
  alloc "$case_dir" release task-a "$proj" "$wt" 2026-09-17T20:00:00Z || fail "release failed"

  rc=0; alloc "$case_dir" released task-a "$proj" "$wt" 2026-09-17T19:30:00Z || rc=$?
  expect_code 0 "$rc" "released: a release after since must read as released"
  rc=0; alloc "$case_dir" released task-a "$proj" "$wt" 2026-09-17T20:00:00Z || rc=$?
  expect_code 0 "$rc" "released: a release exactly at since must read as released"
  rc=0; alloc "$case_dir" released task-a "$proj" "$wt" 2026-09-17T20:00:01Z || rc=$?
  expect_code 1 "$rc" "released: a release older than since must not read as released"
  rc=0; alloc "$case_dir" released task-a "$proj" "$wt" 2026-09-18T01:00:00Z || rc=$?
  expect_code 1 "$rc" "released: a release from before a later incarnation must not read as released"
  rc=0; alloc "$case_dir" released task-a "$proj" "$wt" "not a timestamp" || rc=$?
  expect_code 2 "$rc" "released: a malformed since must be a usage error"
  rc=0; alloc "$case_dir" released task-a "$proj" "$wt" 2026-09-17T20:00:00 || rc=$?
  expect_code 2 "$rc" "released: a non-canonical since must be a usage error"
  pass "released honors the since bound so only releases at or after it count"
}

test_released_refuses_malformed_and_missing_arguments() {
  local case_dir rc proj wt ledger
  case_dir=$(make_case malformed)
  proj="$case_dir/project"
  wt="$case_dir/wt"
  alloc "$case_dir" initialize "$proj" 2026-09-17T18:00:00Z complete || fail "initialize failed"
  alloc "$case_dir" acquire task-a "$proj" "$wt" 2026-09-17T19:00:00Z reused >/dev/null || fail "acquire failed"
  alloc "$case_dir" release task-a "$proj" "$wt" 2026-09-17T20:00:00Z || fail "release failed"
  ledger=$(ledger_path "$case_dir")

  rc=0; alloc "$case_dir" released task-a "$proj" || rc=$?
  expect_code 2 "$rc" "released: a missing worktree argument must be a usage error"
  rc=0; alloc "$case_dir" released "" "$proj" "$wt" || rc=$?
  expect_code 2 "$rc" "released: an empty task id must be a usage error"

  printf '%s\n' 'not json' >> "$ledger"
  rc=0; alloc "$case_dir" released task-a "$proj" "$wt" || rc=$?
  expect_code 1 "$rc" "released: a malformed ledger must not read as released"

  printf '%s\n' '{"schema":"fm-worktree-allocations.v1"}' > "$ledger"
  rc=0; alloc "$case_dir" released task-a "$proj" "$wt" || rc=$?
  expect_code 1 "$rc" "released: a ledger with a broken header must not read as released"

  rm -f "$ledger"
  ln -s /nonexistent "$ledger"
  rc=0; alloc "$case_dir" released task-a "$proj" "$wt" || rc=$?
  expect_code 1 "$rc" "released: a symlinked ledger must not read as released"
  pass "released fails closed on missing arguments and unreadable or malformed ledgers"
}

test_released_follows_the_ledger_events
test_released_since_bound_excludes_older_releases
test_released_refuses_malformed_and_missing_arguments
