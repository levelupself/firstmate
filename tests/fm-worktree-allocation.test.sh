#!/usr/bin/env bash
# Behavioral coverage for bin/fm-worktree-allocation.sh's read-only `holder`
# query: it prints the task the ledger records as the current holder of a
# worktree (the last acquire not followed by that task's release, in event
# order), prints nothing when no task holds it, never writes the ledger, and
# fails on an unreadable or malformed ledger rather than reading it as free.
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

# holder_is <case-dir> <project> <worktree> <expected> <label>: the query must
# exit 0 and print exactly <expected> (empty for no holder).
holder_is() {
  local case_dir=$1 proj=$2 wt=$3 expected=$4 label=$5 out rc=0
  out=$(alloc "$case_dir" holder "$proj" "$wt") || rc=$?
  expect_code 0 "$rc" "$label: the holder query failed"
  [ "$out" = "$expected" ] || fail "$label: expected holder '$expected', got '$out'"
}

test_holder_follows_the_ledger_events() {
  local case_dir proj wt before after
  case_dir=$(make_case events)
  proj="$case_dir/project"
  wt="$case_dir/wt"

  holder_is "$case_dir" "$proj" "$wt" "" "missing ledger"
  [ ! -e "$case_dir/data/worktree-allocations" ] \
    || fail "holder: the query created the ledger directory"

  alloc "$case_dir" initialize "$proj" 2026-09-17T18:00:00Z complete || fail "initialize failed"
  holder_is "$case_dir" "$proj" "$wt" "" "no events"

  alloc "$case_dir" acquire task-a "$proj" "$wt" 2026-09-17T19:00:00Z reused >/dev/null || fail "acquire failed"
  holder_is "$case_dir" "$proj" "$wt" task-a "acquire only"

  alloc "$case_dir" release task-a "$proj" "$wt" 2026-09-17T20:00:00Z || fail "release failed"
  before=$(cat "$(ledger_path "$case_dir")")
  holder_is "$case_dir" "$proj" "$wt" "" "acquire then release"
  after=$(cat "$(ledger_path "$case_dir")")
  [ "$before" = "$after" ] || fail "holder: the query changed the ledger"
  [ ! -e "$case_dir/state/.worktree-allocation.lock" ] \
    || fail "holder: the query left the allocation lock behind"

  alloc "$case_dir" acquire task-b "$proj" "$wt" 2026-09-18T01:00:00Z reused >/dev/null || fail "second acquire failed"
  holder_is "$case_dir" "$proj" "$wt" task-b "two tasks in sequence"
  holder_is "$case_dir" "$proj" "$case_dir/other-wt" "" "another worktree"

  # Timestamps do not matter: a release recorded with an older event time
  # still frees the copy because it follows the acquire in event order.
  alloc "$case_dir" release task-b "$proj" "$wt" 2026-09-17T12:00:00Z || fail "second release failed"
  holder_is "$case_dir" "$proj" "$wt" "" "release with an older timestamp"

  # Two tasks acquiring without a release in between: the later acquire wins.
  alloc "$case_dir" acquire task-c "$proj" "$wt" 2026-09-18T03:00:00Z reused >/dev/null || fail "third acquire failed"
  alloc "$case_dir" acquire task-d "$proj" "$wt" 2026-09-18T04:00:00Z reused >/dev/null || fail "fourth acquire failed"
  holder_is "$case_dir" "$proj" "$wt" task-d "back-to-back acquires"
  pass "holder answers from the last unreleased acquire of the worktree without writing the ledger"
}

test_holder_ignores_a_release_by_a_task_that_no_longer_holds_the_copy() {
  local case_dir proj wt
  case_dir=$(make_case stale-release)
  proj="$case_dir/project"
  wt="$case_dir/wt"
  alloc "$case_dir" initialize "$proj" 2026-09-17T18:00:00Z complete || fail "initialize failed"
  alloc "$case_dir" acquire task-a "$proj" "$wt" 2026-09-17T19:00:00Z reused >/dev/null || fail "first acquire failed"
  alloc "$case_dir" acquire task-b "$proj" "$wt" 2026-09-18T01:00:00Z reused >/dev/null || fail "second acquire failed"
  # task-a's late release (its copy was taken over without a release of its
  # own) must not free the copy from under task-b.
  alloc "$case_dir" release task-a "$proj" "$wt" 2026-09-18T02:00:00Z || fail "late release failed"
  holder_is "$case_dir" "$proj" "$wt" task-b "late release by the earlier task"
  alloc "$case_dir" release task-b "$proj" "$wt" 2026-09-18T03:00:00Z || fail "holder release failed"
  holder_is "$case_dir" "$proj" "$wt" "" "release by the holder"
  pass "holder ignores a release by a task that no longer holds the copy"
}

test_holder_fails_closed_on_bad_arguments_and_ledgers() {
  local case_dir rc proj wt ledger
  case_dir=$(make_case malformed)
  proj="$case_dir/project"
  wt="$case_dir/wt"
  alloc "$case_dir" initialize "$proj" 2026-09-17T18:00:00Z complete || fail "initialize failed"
  alloc "$case_dir" acquire task-a "$proj" "$wt" 2026-09-17T19:00:00Z reused >/dev/null || fail "acquire failed"
  ledger=$(ledger_path "$case_dir")

  rc=0; alloc "$case_dir" holder "$proj" >/dev/null || rc=$?
  expect_code 2 "$rc" "holder: a missing worktree argument must be a usage error"
  rc=0; alloc "$case_dir" holder "" "$wt" >/dev/null || rc=$?
  expect_code 2 "$rc" "holder: an empty project must be a usage error"

  holder_is "$case_dir" "$case_dir/other-project" "$wt" "" "another project's ledger is absent"

  printf '%s\n' 'not json' >> "$ledger"
  rc=0; alloc "$case_dir" holder "$proj" "$wt" >/dev/null || rc=$?
  expect_code 1 "$rc" "holder: a malformed ledger must fail rather than read as free"

  printf '%s\n' '{"schema":"fm-worktree-allocations.v1"}' > "$ledger"
  rc=0; alloc "$case_dir" holder "$proj" "$wt" >/dev/null || rc=$?
  expect_code 1 "$rc" "holder: a ledger with a broken header must fail"

  rm -f "$ledger"
  ln -s /nonexistent "$ledger"
  rc=0; alloc "$case_dir" holder "$proj" "$wt" >/dev/null || rc=$?
  expect_code 1 "$rc" "holder: a symlinked ledger must fail"

  rm -f "$ledger"
  mkdir "$ledger"
  rc=0; alloc "$case_dir" holder "$proj" "$wt" >/dev/null || rc=$?
  expect_code 1 "$rc" "holder: a directory in the ledger's place must fail"
  pass "holder fails closed on missing arguments and unreadable or malformed ledgers"
}

test_holder_follows_the_ledger_events
test_holder_ignores_a_release_by_a_task_that_no_longer_holds_the_copy
test_holder_fails_closed_on_bad_arguments_and_ledgers
