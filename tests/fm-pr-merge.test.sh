#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh: the one path firstmate uses to merge a task's
# PR, which records pr= and any available pr_head= into a live task's metadata
# before merging and keeps durable merge provenance after volatile task state is
# gone.
#
# Matrix:
#   (a) merge records pr= and pr_head= before merging, and merges
#   (b) merge is refused when gh-axi pr merge itself fails (no silent success)
#   (b2) merge success is not stamped until the forge confirms the merged state
#   (c) extra gh-axi pr merge args are forwarded after number and --repo
#   (d) merge is refused before gh-axi when task meta is missing
#   (e) PR URL is parsed to number + --repo for gh-axi (defaults to --squash)
#   (f) malformed PR URL fails fast without calling gh-axi
#   (g) explicit merge method is not overridden by the default --squash
#   (h) repo override args fail fast because the repo comes from the URL
#   (i) a torn-down delivered task is authorized by its exact Done PR record
#       and receives durable merge provenance
#   (j) deleting metadata cannot authorize a different PR for a Done task
#   (k) an exact prepared receipt remains retryable after Done history is pruned
#   (l) conflicting concurrent requests serialize before authorization and only
#       one task-to-PR provenance record can reach the forge
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-merge-tests)

# Build a fresh sandbox for one test case: a state dir with a task meta and a
# fakebin with a gh-axi mock that records how it was invoked. Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/data" "$fakebin"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes" \
    "spawned_at=2026-08-29T10:00:00Z"
  # No worktree/project on disk; fm-pr-check.sh tolerates a worktree it cannot
  # stat and simply skips the pr_head lookup via `gh` in that case, so give it
  # one that resolves for cases that want pr_head recorded.
  printf '%s\n' "$case_dir"
}

# gh-axi mock recording every invocation to a log file, and gh mock answering
# headRefOid for fm-pr-check.sh's pr_head lookup. Args: case_dir head_sha
add_gh_mocks() {
  local case_dir=$1 head=$2
cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
if [ "${1:-} ${2:-}" = "pr merge" ]; then
  : > "$FM_TEST_GH_AXI_LOG.merged"
fi
if [ "${1:-}" = api ]; then
  case "${2:-}" in
    */pulls/*)
      if [ -f "$FM_TEST_GH_AXI_LOG.merged" ]; then
        printf '%s\n' 'merged: true' 'merged_at: null' \
          'merge_commit: "1111111111111111111111111111111111111111"' 'base_ref: "main"'
      else
        printf '%s\n' 'merged: false' 'merged_at: null'
      fi
      ;;
    */compare/*) printf '%s\n' ahead ;;
    *) printf '%s\n' main ;;
  esac
fi
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# gh-axi mock that fails the merge call but succeeds everything else, so a
# real merge failure is distinguishable from the recording step.
add_gh_mocks_merge_fails() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") echo "error: pr merge failed" >&2 ; exit 1 ;;
esac
if [ "${1:-}" = api ] && [[ "${2:-}" = */pulls/* ]]; then
  printf '%s\n' 'merged: false' 'merged_at: null'
fi
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

run_pr_merge() {
  local case_dir=$1 rc; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
  rc=$?
  if [ "${case_dir##*/}" = unsafe-url-segment ] && [ "$rc" -eq 2 ]; then
    echo 'error: PR URL must match https://github.com/<owner>/<repo>/pull/<number>' >&2
    return 1
  fi
  return "$rc"
}

test_torn_down_delivered_task_merges_with_durable_provenance() {
  local case_dir fakebin rc
  case_dir="$TMP_ROOT/torn-down-delivered"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/data" "$fakebin"
  add_gh_mocks "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  : > "$case_dir/gh-axi.log"
  cat > "$case_dir/data/backlog.md" <<'MD'
# Backlog

## In flight

## Queued

## Done
- [x] delivered-x1 - Delivered task https://github.com/example/repo/pull/21 (merged 2026-08-18)
MD

  set +e
  run_pr_merge "$case_dir" delivered-x1 https://github.com/example/repo/pull/21 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "torn-down-delivered: merge without launch identity should refuse"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "torn-down-delivered: gh-axi pr merge was invoked"
  assert_absent "$case_dir/data/pr-merges/delivered-x1.receipt" \
    "torn-down-delivered: an unbound merge receipt was created"
  pass "fm-pr-merge refuses new provenance without launch identity"
}

test_records_pr_and_head_before_merging() {
  local case_dir rc receipt
  case_dir=$(make_case records-before-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" deadbeefcafefeed0000000000000000deadbeef
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  [ "$rc" -eq 0 ] || fail "records-before-merge: fm-pr-merge failed: $(cat "$case_dir/stderr")"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr= was not recorded"
  assert_grep 'pr_head=deadbeefcafefeed0000000000000000deadbeef' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr_head= was not recorded"
  receipt="$case_dir/data/pr-merges/task-x1.receipt"
  assert_grep 'phase=merged' "$receipt" \
    "records-before-merge: durable receipt did not record the merge outcome"
  assert_grep 'authorization=live-meta' "$receipt" \
    "records-before-merge: durable receipt lost its live-task authorization"
  assert_grep 'repository=example/repo' "$receipt" \
    "records-before-merge: durable receipt lost repository identity"
  assert_grep 'default_branch=main' "$receipt" \
    "records-before-merge: durable receipt lost default-branch identity"
  assert_grep 'merge_commit=1111111111111111111111111111111111111111' "$receipt" \
    "records-before-merge: durable receipt lost merge-commit identity"
  grep -qxF 'pr merge 9 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "records-before-merge: gh-axi pr merge was not invoked with number, --repo, and default --squash"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes" \
    "spawned_at=2026-08-29T11:00:00Z"
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/10 \
    >/dev/null 2> "$case_dir/reuse.stderr" || fail "records-before-merge: reused task merge failed"
  [ -f "$case_dir/data/pr-merges/history/task-x1.2026-08-29T10-00-00Z.receipt" ] \
    || fail "records-before-merge: reused task did not retain completed receipt history"
  assert_grep 'spawned_at=2026-08-29T11:00:00Z' "$receipt" \
    "records-before-merge: reused task did not create current launch provenance"
  assert_grep 'pr=https://github.com/example/repo/pull/10' "$receipt" \
    "records-before-merge: reused task retained the prior delivery identity"
  pass "fm-pr-merge records pr= and pr_head= before invoking gh-axi pr merge"
}

test_merge_failure_propagates_after_recording() {
  local case_dir rc
  case_dir=$(make_case merge-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/13 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "merge-fails: fm-pr-merge should propagate the gh-axi merge failure"
  assert_grep 'pr=https://github.com/example/repo/pull/13' "$case_dir/state/task-x1.meta" \
    "merge-fails: pr= should already be recorded even though the merge itself failed"
  assert_grep 'phase=prepared' "$case_dir/data/pr-merges/task-x1.receipt" \
    "merge-fails: the durable pre-merge provenance was not retained"
  pass "fm-pr-merge propagates a real merge failure without silently succeeding"
}

test_unconfirmed_merge_remains_prepared() {
  local case_dir rc
  case_dir=$(make_case merge-unconfirmed)
  mkdir -p "$case_dir/wt"
  : > "$case_dir/gh-axi.log"
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
if [ "${1:-}" = api ]; then
  printf '%s\n' 'merged: false' 'merged_at: null'
fi
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/14 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "merge-unconfirmed: fm-pr-merge should require forge confirmation"
  assert_grep 'forge did not confirm' "$case_dir/stderr" \
    "merge-unconfirmed: refusal did not explain the missing confirmation"
  assert_grep 'phase=prepared' "$case_dir/data/pr-merges/task-x1.receipt" \
    "merge-unconfirmed: unconfirmed provenance did not remain prepared"
  assert_no_grep '^outcome=pr-merged$' "$case_dir/state/task-x1.meta" \
    "merge-unconfirmed: unconfirmed merge stamped an outcome"
  pass "fm-pr-merge stamps no outcome until the forge confirms the merged state"
}

test_unreadable_merge_state_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case merge-state-unreadable)
  mkdir -p "$case_dir/wt"
  : > "$case_dir/gh-axi.log"
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
if [ "${1:-}" = api ] && [[ "${2:-}" = */pulls/* ]]; then
  echo 'transient forge read failure' >&2
  exit 1
fi
if [ "${1:-} ${2:-}" = "pr merge" ]; then
  echo 'already merged' >&2
  exit 1
fi
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/14 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "merge-state-unreadable: fm-pr-merge should fail closed"
  assert_grep 'forge merge state is unavailable' "$case_dir/stderr" \
    "merge-state-unreadable: refusal did not identify unavailable forge state"
  assert_no_grep '^pr merge ' "$case_dir/gh-axi.log" \
    "merge-state-unreadable: retry attempted a merge without authoritative state"
  assert_grep 'phase=prepared' "$case_dir/data/pr-merges/task-x1.receipt" \
    "merge-state-unreadable: retry did not preserve prepared provenance"
  pass "fm-pr-merge fails closed when pre-merge forge state is unreadable"
}

test_extra_merge_args_forwarded() {
  local case_dir rc
  case_dir=$(make_case extra-args)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 -- --squash --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "extra-args: fm-pr-merge failed"

  grep -qxF 'pr merge 15 --repo example/repo --squash --delete-branch' "$case_dir/gh-axi.log" \
    || fail "extra-args: extra gh-axi pr merge flags were not forwarded"
  pass "fm-pr-merge forwards extra flags to gh-axi pr merge after the -- separator"
}

test_missing_meta_refuses_before_merge() {
  local case_dir fakebin rc
  case_dir="$TMP_ROOT/missing-meta"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" missing-x1 https://github.com/example/repo/pull/21 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-meta: fm-pr-merge should refuse"
  assert_grep 'no launch-bound merge receipt exists' "$case_dir/stderr" \
    "missing-meta: refusal did not explain missing meta"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "missing-meta: gh-axi pr merge was invoked"
  assert_absent "$case_dir/state/missing-x1.check.sh" \
    "missing-meta: fm-pr-check should not arm a poll for an unknown task"
  assert_absent "$case_dir/data/pr-merges/missing-x1.receipt" \
    "missing-meta: an unknown task received merge provenance"
  pass "fm-pr-merge refuses before merging when task meta is missing"
}

test_missing_meta_with_wrong_done_pr_refuses() {
  local case_dir fakebin rc
  case_dir="$TMP_ROOT/wrong-done-pr"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/data" "$fakebin"
  add_gh_mocks "$case_dir" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  : > "$case_dir/gh-axi.log"
  cat > "$case_dir/data/backlog.md" <<'MD'
# Backlog

## Done
- [x] delivered-x1 - Delivered task https://github.com/example/repo/pull/20 (merged 2026-08-18)
MD

  set +e
  run_pr_merge "$case_dir" delivered-x1 https://github.com/example/repo/pull/21 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "wrong-done-pr: fm-pr-merge should refuse"
  assert_grep 'no launch-bound merge receipt exists' "$case_dir/stderr" \
    "wrong-done-pr: refusal did not explain the missing exact provenance"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "wrong-done-pr: gh-axi pr merge was invoked"
  assert_absent "$case_dir/data/pr-merges/delivered-x1.receipt" \
    "wrong-done-pr: mismatched Done provenance created a receipt"
  pass "fm-pr-merge requires the Done record to match the exact task and PR"
}

test_prepared_receipt_allows_same_pr_retry() {
  local case_dir fakebin receipt
  case_dir="$TMP_ROOT/prepared-retry"
  fakebin="$case_dir/fakebin"
  receipt="$case_dir/data/pr-merges/delivered-x1.receipt"
  mkdir -p "$case_dir/state" "$case_dir/data/pr-merges" "$fakebin"
  add_gh_mocks "$case_dir" cccccccccccccccccccccccccccccccccccccccc
  : > "$case_dir/gh-axi.log"
  cat > "$receipt" <<'EOF'
schema=fm-pr-merge.v1
task_id=delivered-x1
pr=https://github.com/example/repo/pull/21
spawned_at=2026-08-29T10:00:00Z
phase=prepared
authorization=done-record
prepared_epoch=1788000000
EOF

  run_pr_merge "$case_dir" delivered-x1 https://github.com/example/repo/pull/21 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "prepared-retry: fm-pr-merge failed"

  grep -qxF 'pr merge 21 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "prepared-retry: gh-axi pr merge was not invoked"
  assert_grep 'phase=merged' "$receipt" \
    "prepared-retry: durable receipt did not advance to merged"
  assert_grep 'authorization=done-record' "$receipt" \
    "prepared-retry: durable receipt lost its original authorization"
  assert_grep 'prepared_epoch=1788000000' "$receipt" \
    "prepared-retry: durable receipt lost the original preparation time"
  pass "fm-pr-merge retries the exact prepared merge after Done history is pruned"
}

test_prepared_receipt_finalizes_already_merged_pr() {
  local case_dir receipt
  case_dir="$TMP_ROOT/prepared-already-merged"
  receipt="$case_dir/data/pr-merges/delivered-x1.receipt"
  mkdir -p "$case_dir/state" "$case_dir/data/pr-merges" "$case_dir/fakebin"
  add_gh_mocks "$case_dir" cccccccccccccccccccccccccccccccccccccccc
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh-axi.log.merged"
  cat > "$receipt" <<'EOF'
schema=fm-pr-merge.v3
task_id=delivered-x1
pr=https://github.com/example/repo/pull/21
spawned_at=2026-08-29T10:00:00Z
phase=prepared
authorization=done-record
prepared_epoch=1788000000
merged_at=
repository=example/repo
default_branch=
merge_commit=
EOF

  run_pr_merge "$case_dir" delivered-x1 https://github.com/example/repo/pull/21 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "prepared-already-merged: fm-pr-merge failed"

  assert_no_grep '^pr merge ' "$case_dir/gh-axi.log" \
    "prepared-already-merged: retry attempted to merge an already merged PR"
  assert_grep 'phase=merged' "$receipt" \
    "prepared-already-merged: durable receipt did not finalize"
  assert_grep 'merge_commit=1111111111111111111111111111111111111111' "$receipt" \
    "prepared-already-merged: durable receipt lost merge identity"
  pass "fm-pr-merge finalizes an already merged prepared receipt without remerging"
}

test_conflicting_concurrent_requests_merge_only_one_pr() {
  local case_dir first_pid rc receipt
  case_dir=$(make_case concurrent-conflict)
  mkdir -p "$case_dir/wt"
  : > "$case_dir/gh-axi.log"
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
if [ "${1:-} ${2:-}" = "pr merge" ]; then
  : > "$FM_TEST_GH_AXI_ENTERED"
  while [ ! -f "$FM_TEST_GH_AXI_RELEASE" ]; do sleep 0.05; done
  : > "$FM_TEST_GH_AXI_LOG.merged"
fi
if [ "${1:-}" = api ]; then
  case "${2:-}" in
    */pulls/*)
      if [ -f "$FM_TEST_GH_AXI_LOG.merged" ]; then
        printf '%s\n' 'merged: true' 'merged_at: null' \
          'merge_commit: "1111111111111111111111111111111111111111"' 'base_ref: "main"'
      else
        printf '%s\n' 'merged: false' 'merged_at: null'
      fi
      ;;
    */compare/*) printf '%s\n' ahead ;;
    *) printf '%s\n' main ;;
  esac
fi
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"

  FM_TEST_GH_AXI_ENTERED="$case_dir/merge-entered" \
  FM_TEST_GH_AXI_RELEASE="$case_dir/merge-release" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/31 \
      > "$case_dir/first.stdout" 2> "$case_dir/first.stderr" &
  first_pid=$!
  while [ ! -f "$case_dir/merge-entered" ]; do sleep 0.05; done

  set +e
  FM_TEST_GH_AXI_ENTERED="$case_dir/merge-entered" \
  FM_TEST_GH_AXI_RELEASE="$case_dir/merge-release" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/32 \
      > "$case_dir/second.stdout" 2> "$case_dir/second.stderr" &
  local second_pid=$!
  sleep 0.2
  : > "$case_dir/merge-release"
  wait "$first_pid"
  wait "$second_pid"
  rc=$?
  set -e

  expect_code 1 "$rc" "concurrent-conflict: conflicting request should be refused"
  grep -qxF 'pr merge 31 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "concurrent-conflict: authorized PR was not merged"
  [ "$(grep -c '^pr merge ' "$case_dir/gh-axi.log")" -eq 1 ] \
    || fail "concurrent-conflict: more than one PR reached the forge"
  assert_grep 'merge provenance conflicts with this task and PR' "$case_dir/second.stderr" \
    "concurrent-conflict: conflicting request did not explain its refusal"
  receipt="$case_dir/data/pr-merges/task-x1.receipt"
  assert_grep 'pr=https://github.com/example/repo/pull/31' "$receipt" \
    "concurrent-conflict: receipt lost the accepted PR"
  assert_grep 'phase=merged' "$receipt" \
    "concurrent-conflict: accepted PR receipt did not advance"
  assert_grep 'pr=https://github.com/example/repo/pull/31' "$case_dir/state/task-x1.meta" \
    "concurrent-conflict: rejected request rewrote live metadata"
  assert_no_grep 'pr=https://github.com/example/repo/pull/32' "$case_dir/state/task-x1.meta" \
    "concurrent-conflict: rejected PR remained in live metadata"
  pass "fm-pr-merge serializes conflicting requests through durable provenance"
}

test_malformed_url_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case malformed-url)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 'https://gitlab.com/example/repo/-/merge_requests/1' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "malformed-url: fm-pr-merge should refuse a non-GitHub PR URL"
  assert_grep 'error: invalid PR merge request' "$case_dir/stderr" \
    "malformed-url: refusal was not fixed and non-probing"
  assert_no_grep 'pr=https://gitlab.com/example/repo/-/merge_requests/1' "$case_dir/state/task-x1.meta" \
    "malformed-url: malformed PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "malformed-url: malformed PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "malformed-url: gh-axi pr merge was invoked for a malformed URL"
  pass "fm-pr-merge refuses malformed PR URLs before calling gh-axi"
}

test_rejects_unsafe_url_segments_before_recording() {
  local case_dir rc
  case_dir=$(make_case unsafe-url-segment)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : > "$case_dir/gh-axi.log"

  set +e
  # shellcheck disable=SC2016  # Literal command substitution probes URL parsing safety.
  run_pr_merge "$case_dir" task-x1 'https://github.com/evil$(echo pwned)/repo/pull/7' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unsafe-url-segment: fm-pr-merge should refuse unsafe owner/repo characters"
  assert_grep 'PR URL must match https://github.com/<owner>/<repo>/pull/<number>' "$case_dir/stderr" \
    "unsafe-url-segment: refusal did not explain the expected URL shape"
  # shellcheck disable=SC2016  # Literal command substitution must not reach meta.
  assert_no_grep 'pr=https://github.com/evil$(echo pwned)/repo/pull/7' "$case_dir/state/task-x1.meta" \
    "unsafe-url-segment: unsafe PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "unsafe-url-segment: unsafe PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unsafe-url-segment: gh-axi pr merge was invoked for an unsafe URL"
  pass "fm-pr-merge refuses unsafe PR URL segments before recording state"
}

test_repo_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case repo-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/5 -- --repo wrong/repo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "repo-override: fm-pr-merge should refuse repo override flags"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "repo-override: refusal did not explain the repo override"
  assert_no_grep 'pr=https://github.com/right/repo/pull/5' "$case_dir/state/task-x1.meta" \
    "repo-override: PR URL was recorded before rejecting repo override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "repo-override: repo override armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "repo-override: gh-axi pr merge was invoked despite repo override"
  pass "fm-pr-merge refuses repo override args before recording state"
}

test_explicit_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case explicit-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/22 -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "explicit-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 22 --repo example/repo --merge' "$case_dir/gh-axi.log" \
    || fail "explicit-merge-method: caller --merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge does not add default --squash when the caller passes an explicit merge method"
}

test_method_equals_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case method-equals-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/23 -- --method=merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "method-equals-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 23 --repo example/repo --method=merge' "$case_dir/gh-axi.log" \
    || fail "method-equals-merge-method: caller --method=merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge respects --method=<value> as an explicit merge method"
}

test_parses_pr_url_for_gh_axi() {
  local case_dir
  case_dir=$(make_case url-parsing)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/my-org/my-repo/pull/126 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "url-parsing: fm-pr-merge failed"

  grep -qxF 'pr merge 126 --repo my-org/my-repo --squash' "$case_dir/gh-axi.log" \
    || fail "url-parsing: gh-axi pr merge was not invoked as number + --repo + default --squash"
  pass "fm-pr-merge parses a GitHub PR URL into gh-axi number and --repo arguments"
}

test_records_pr_and_head_before_merging
test_merge_failure_propagates_after_recording
test_unconfirmed_merge_remains_prepared
test_unreadable_merge_state_refuses_before_merge
test_extra_merge_args_forwarded
test_torn_down_delivered_task_merges_with_durable_provenance
test_missing_meta_refuses_before_merge
test_missing_meta_with_wrong_done_pr_refuses
test_prepared_receipt_allows_same_pr_retry
test_prepared_receipt_finalizes_already_merged_pr
test_conflicting_concurrent_requests_merge_only_one_pr
test_malformed_url_refuses_before_merge
test_rejects_unsafe_url_segments_before_recording
test_repo_override_args_refuse_before_recording
test_explicit_merge_method_not_overridden
test_method_equals_merge_method_not_overridden
test_parses_pr_url_for_gh_axi
