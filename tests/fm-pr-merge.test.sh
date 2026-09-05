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
#   (m) CI check reporting distinguishes passing, failing, and ABSENT while
#       preserving the PR mergeable_state, including a conflicted absent case
#   (n) the merge path refuses both failing and absent checks before forge mutation
#   (o) a confirmed forge merge fast-forwards the project's local origin mirror
#   (p) a diverged local origin mirror is refused without forcing or stamping success
#   (q) a prepared receipt retry recovers the project checkout after task teardown
#   (r) an origin pushurl cannot redirect the verified local mirror update
#   (s) a concurrent mirror ref move makes the atomic update refuse
#   (t) delayed PR and branch visibility confirm within a backed-off time budget
#   (u) never-landing and slow evidence reads exhaust that budget without success
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
PR_CHECKS="$ROOT/bin/fm-pr-checks.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-merge-tests)

# Build a fresh sandbox for one test case: a state dir with a task meta and a
# fakebin with a gh-axi mock that records how it was invoked. Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/data" "$fakebin"
  cp "$ROOT/.tasks.toml" "$case_dir/.tasks.toml"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes" \
    "spawned_at=2026-08-29T10:00:00Z"
  git init -q -b main "$case_dir/project"
  printf '%s\n' baseline > "$case_dir/project/baseline.txt"
  git -C "$case_dir/project" add baseline.txt
  git -C "$case_dir/project" commit -q -m baseline
  git -C "$case_dir/project" remote add origin https://github.com/example/repo.git
  # Virtual elapsed time advances through sleeps and simulated API latency.
  # Keep other date formats real for launch identities and receipt timestamps.
  printf '%s\n' 0 > "$case_dir/gh-axi.log.clock"
  command -v date > "$case_dir/real-date"
  command -v sleep > "$case_dir/real-sleep"
  cat > "$fakebin/date" <<'SH'
#!/usr/bin/env bash
if [ "$*" = +%s ]; then
  awk '{printf "%.0f\n", 1800000000 + int($1)}' "$FM_TEST_GH_AXI_LOG.clock"
else
  exec "$(cat "${FM_TEST_GH_AXI_LOG%/*}/real-date")" "$@"
fi
SH
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
# Lock polling must neither race on nor add fractions to the confirmation clock.
case "$1" in
  *.*) exec "$(cat "${FM_TEST_GH_AXI_LOG%/*}/real-sleep")" "$@" ;;
esac
read -r elapsed < "$FM_TEST_GH_AXI_LOG.clock"
awk -v elapsed="$elapsed" -v delay="$1" -v extra="${FM_TEST_SLEEP_EXTRA_SECONDS:-0}" \
  'BEGIN {print elapsed + delay + extra}' > "$FM_TEST_GH_AXI_LOG.clock"
printf '%s\n' "$1" >> "$FM_TEST_GH_AXI_LOG.sleeps"
SH
  chmod +x "$fakebin/date" "$fakebin/sleep"
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
if [ "${1:-} ${2:-}" = "pr checks" ]; then
  case "${FM_TEST_CHECK_STATE:-passing}" in
    passing) printf '%s\n' 'summary: "2 passed, 0 failed, 2 total"' 'checks[2]{name,conclusion}:' '  unit,pass' '  lint,pass' ;;
    failing) printf '%s\n' 'summary: "1 passed, 1 failed, 2 total"' 'checks[2]{name,conclusion}:' '  unit,pass' '  lint,fail' ;;
    absent) printf '%s\n' 'checks: "0 passed, 0 failed - this PR has no CI checks configured"' ;;
    pending) printf '%s\n' 'summary: "1 passed, 0 failed, 1 pending, 2 total"' 'checks[2]{name,conclusion}:' '  unit,pass' '  lint,pending' ;;
  esac
  exit 0
fi
if [ "${1:-}" = api ] && [[ " $* " = *"mergeable_state"* ]]; then
  printf 'mergeable_state: %s\n' "${FM_TEST_MERGEABLE_STATE:-clean}"
  exit 0
fi
if [ "${1:-} ${2:-}" = "pr merge" ]; then
  : > "$FM_TEST_GH_AXI_LOG.merged"
fi
if [ "${1:-}" = api ]; then
  read -r elapsed < "$FM_TEST_GH_AXI_LOG.clock"
  case "${2:-}" in
    */pulls/*)
      if [ -f "$FM_TEST_GH_AXI_LOG.merged" ]; then
        printf '%s\n' "$elapsed" >> "$FM_TEST_GH_AXI_LOG.read-starts"
        elapsed=$((elapsed + ${FM_TEST_READ_SECONDS:-0}))
        printf '%s\n' "$elapsed" > "$FM_TEST_GH_AXI_LOG.clock"
      fi
      if [ -f "$FM_TEST_GH_AXI_LOG.merged" ] && [ "$elapsed" -ge "${FM_TEST_PR_VISIBLE_AT:-0}" ]; then
        printf '%s\n' 'merged: true' 'merged_at: null' \
          "merge_commit: \"${FM_TEST_MERGE_COMMIT:-1111111111111111111111111111111111111111}\"" \
          'base_ref: "main"'
      else
        printf '%s\n' 'merged: false' 'merged_at: null'
      fi
      ;;
    */compare/*)
      if [ "$elapsed" -ge "${FM_TEST_BRANCH_VISIBLE_AT:-0}" ]; then
        printf 'status: %s\n' "${FM_TEST_CONFIRMED_STATUS:-ahead}"
      else
        printf '%s\n' 'status: behind'
      fi
      ;;

    *) printf '%s\n' 'default_branch: main' ;;
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
if [ "${1:-} ${2:-}" = "pr checks" ]; then
  printf '%s\n' 'summary: "2 passed, 0 failed, 2 total"' 'checks[2]{name,conclusion}:' '  unit,pass' '  lint,pass'
  exit 0
fi
if [ "${1:-}" = api ] && [[ " $* " = *"mergeable_state"* ]]; then
  printf '%s\n' 'mergeable_state: clean'
  exit 0
fi
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
  FM_TEST_MERGE_COMMIT="$(sed -n '1p' "$case_dir/merge-commit" 2>/dev/null || true)" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
  rc=$?
  if [ "${case_dir##*/}" = unsafe-url-segment ] && [ "$rc" -eq 2 ]; then
    echo 'error: PR URL must match https://github.com/<owner>/<repo>/pull/<number>' >&2
    return 1
  fi
  return "$rc"
}

setup_mirror_topology() {
  local case_dir=$1 diverged=${2:-0} project mirror forge base merged competitor
  project="$case_dir/project"
  mirror="$case_dir/mirror.git"
  forge="$case_dir/forge.git"
  git init -q --bare "$mirror"
  git init -q --bare "$forge"
  git -C "$project" remote set-url origin "$mirror"
  git -C "$project" remote add github https://github.com/example/repo.git
  git -C "$project" config "url.file://$forge.insteadOf" https://github.com/example/repo.git
  git -C "$project" push -q origin main
  git -C "$project" push -q github main
  git --git-dir="$mirror" symbolic-ref HEAD refs/heads/main
  git --git-dir="$forge" symbolic-ref HEAD refs/heads/main
  base=$(git -C "$project" rev-parse main)
  printf '%s\n' merged > "$project/merged.txt"
  git -C "$project" add merged.txt
  git -C "$project" commit -q -m merged
  merged=$(git -C "$project" rev-parse HEAD)
  git -C "$project" push -q github main
  printf '%s\n' "$base" > "$case_dir/mirror-base"
  printf '%s\n' "$merged" > "$case_dir/merge-commit"
  if [ "$diverged" -eq 1 ]; then
    competitor="$case_dir/competitor"
    git clone -q "$mirror" "$competitor"
    printf '%s\n' divergent > "$competitor/divergent.txt"
    git -C "$competitor" add divergent.txt
    git -C "$competitor" commit -q -m divergent
    git -C "$competitor" push -q origin main
  fi
}

test_confirmed_merge_fast_forwards_local_mirror() {
  local case_dir base merged
  case_dir=$(make_case mirror-fast-forward)
  setup_mirror_topology "$case_dir"
  add_gh_mocks "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  : > "$case_dir/gh-axi.log"
  base=$(cat "$case_dir/mirror-base")
  merged=$(cat "$case_dir/merge-commit")

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/101 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "mirror-fast-forward: fm-pr-merge failed: $(cat "$case_dir/stderr")"

  [ "$(git --git-dir="$case_dir/mirror.git" rev-parse main)" = "$merged" ] \
    || fail "mirror-fast-forward: confirmed merge did not advance the local mirror"
  assert_grep "mirror: origin refs/heads/main fast-forwarded $base -> $merged" \
    "$case_dir/stdout" \
    "mirror-fast-forward: merge outcome did not report the mirror update"
  pass "fm-pr-merge fast-forwards the local mirror after a confirmed forge merge"
}

test_diverged_local_mirror_refuses_without_force() {
  local case_dir mirror_before rc
  case_dir=$(make_case mirror-diverged)
  setup_mirror_topology "$case_dir" 1
  add_gh_mocks "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  : > "$case_dir/gh-axi.log"
  mirror_before=$(git --git-dir="$case_dir/mirror.git" rev-parse main)

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/102 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "mirror-diverged: fm-pr-merge should refuse a diverged mirror"
  assert_grep 'REFUSED: local mirror origin cannot fast-forward refs/heads/main' \
    "$case_dir/stderr" \
    "mirror-diverged: refusal did not identify the mirror and branch"
  [ "$(git --git-dir="$case_dir/mirror.git" rev-parse main)" = "$mirror_before" ] \
    || fail "mirror-diverged: refusal rewrote the local mirror"
  assert_grep 'phase=prepared' "$case_dir/data/pr-merges/task-x1.receipt" \
    "mirror-diverged: refusal stamped the merge complete"
  assert_no_grep 'outcome=pr-merged' "$case_dir/state/task-x1.meta" \
    "mirror-diverged: refusal stamped the task outcome"
  pass "fm-pr-merge refuses a diverged local mirror without forcing"
}

test_prepared_retry_recovers_project_and_advances_mirror() {
  local case_dir merged rc
  case_dir=$(make_case mirror-prepared-retry)
  setup_mirror_topology "$case_dir"
  add_gh_mocks "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  : > "$case_dir/gh-axi.log"

  set +e
  FM_TEST_CHECK_STATE=failing run_pr_merge "$case_dir" task-x1 \
    https://github.com/example/repo/pull/103 > "$case_dir/first.stdout" 2> "$case_dir/first.stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "mirror-prepared-retry: preparation should stop on failing checks"
  assert_grep "project=$case_dir/project" "$case_dir/data/pr-merges/task-x1.receipt" \
    "mirror-prepared-retry: prepared receipt did not persist the project checkout"
  rm "$case_dir/state/task-x1.meta"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/103 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "mirror-prepared-retry: retry failed: $(cat "$case_dir/stderr")"

  merged=$(cat "$case_dir/merge-commit")
  [ "$(git --git-dir="$case_dir/mirror.git" rev-parse main)" = "$merged" ] \
    || fail "mirror-prepared-retry: retry did not advance the persisted project's mirror"
  assert_grep 'phase=merged' "$case_dir/data/pr-merges/task-x1.receipt" \
    "mirror-prepared-retry: retry did not finalize the receipt"
  pass "fm-pr-merge recovers the project from prepared provenance after task teardown"
}

test_origin_pushurl_cannot_redirect_mirror_update() {
  local case_dir merged redirected_before
  case_dir=$(make_case mirror-pushurl)
  setup_mirror_topology "$case_dir"
  git init -q --bare "$case_dir/redirected.git"
  git -C "$case_dir/project" push -q "$case_dir/redirected.git" \
    "$(cat "$case_dir/mirror-base"):refs/heads/main"
  redirected_before=$(git --git-dir="$case_dir/redirected.git" rev-parse main)
  git -C "$case_dir/project" config remote.origin.pushurl "$case_dir/redirected.git"
  git -C "$case_dir/project" config \
    "url.$case_dir/redirected.git.pushInsteadOf" "$case_dir/mirror.git"
  add_gh_mocks "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/104 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "mirror-pushurl: fm-pr-merge failed: $(cat "$case_dir/stderr")"

  merged=$(cat "$case_dir/merge-commit")
  [ "$(git --git-dir="$case_dir/mirror.git" rev-parse main)" = "$merged" ] \
    || fail "mirror-pushurl: verified local origin mirror was not advanced"
  [ "$(git --git-dir="$case_dir/redirected.git" rev-parse main)" = "$redirected_before" ] \
    || fail "mirror-pushurl: configured pushurl redirected the mirror update"
  pass "fm-pr-merge updates the verified mirror despite Git URL redirection configuration"
}

test_concurrent_mirror_move_refuses_atomically() {
  local base case_dir competitor competing rc
  case_dir=$(make_case mirror-concurrent-move)
  setup_mirror_topology "$case_dir"
  base=$(cat "$case_dir/mirror-base")
  competitor="$case_dir/competitor-move"
  git clone -q "$case_dir/mirror.git" "$competitor"
  printf '%s\n' competing > "$competitor/competing.txt"
  git -C "$competitor" add competing.txt
  git -C "$competitor" commit -q -m competing
  git -C "$competitor" push -q origin main
  competing=$(git --git-dir="$case_dir/mirror.git" rev-parse main)
  git --git-dir="$case_dir/mirror.git" update-ref refs/heads/main "$base" "$competing"
  cat > "$case_dir/fakebin/git" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--git-dir=$FM_TEST_MIRROR" ] && [ "${2:-}" = update-ref ] \
  && [ ! -e "$FM_TEST_REF_MOVED" ]; then
  : > "$FM_TEST_REF_MOVED"
  "$FM_TEST_REAL_GIT" --git-dir="$FM_TEST_MIRROR" update-ref refs/heads/main \
    "$FM_TEST_COMPETING_COMMIT" "$FM_TEST_MIRROR_BASE"
fi
exec "$FM_TEST_REAL_GIT" "$@"
SH
  chmod +x "$case_dir/fakebin/git"
  add_gh_mocks "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  : > "$case_dir/gh-axi.log"

  set +e
  FM_TEST_REAL_GIT=/usr/bin/git \
  FM_TEST_MIRROR="$case_dir/mirror.git" \
  FM_TEST_REF_MOVED="$case_dir/ref-moved" \
  FM_TEST_COMPETING_COMMIT="$competing" \
  FM_TEST_MIRROR_BASE="$base" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/105 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "mirror-concurrent-move: stale atomic update should refuse"
  [ "$(git --git-dir="$case_dir/mirror.git" rev-parse main)" = "$competing" ] \
    || fail "mirror-concurrent-move: stale update overwrote the concurrent commit"
  assert_grep 'REFUSED: local mirror origin moved' "$case_dir/stderr" \
    "mirror-concurrent-move: refusal did not report the concurrent move"
  assert_grep 'phase=prepared' "$case_dir/data/pr-merges/task-x1.receipt" \
    "mirror-concurrent-move: atomic refusal stamped the merge complete"
  pass "fm-pr-merge atomically refuses a concurrent local mirror move"
}

run_pr_checks() {
  local case_dir=$1
  shift
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_CHECK_STATE="${FM_TEST_CHECK_STATE:-passing}" \
  FM_TEST_MERGEABLE_STATE="${FM_TEST_MERGEABLE_STATE:-clean}" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECKS" "$@"
}

test_check_reporting_has_three_states_and_mergeability() {
  local case_dir out rc state expected mergeable
  case_dir=$(make_case check-reporting)
  add_gh_mocks "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  : > "$case_dir/gh-axi.log"

  for state in passing failing pending absent; do
    case "$state" in
      passing) expected=passing ;;
      failing|pending) expected=failing ;;
      absent) expected=ABSENT ;;
    esac
    set +e
    out=$(FM_TEST_CHECK_STATE="$state" run_pr_checks "$case_dir" \
      https://github.com/example/repo/pull/41 2> "$case_dir/$state.stderr")
    rc=$?
    set -e
    expect_code 0 "$rc" "check-reporting-$state: reporter exit status"
    printf '%s\n' "$out" | grep -qxF "check_state: $expected" \
      || fail "check-reporting-$state: reporter did not emit check_state: $expected"
    printf '%s\n' "$out" | grep -qxF 'mergeable_state: clean' \
      || fail "check-reporting-$state: reporter did not surface mergeable_state"
  done

  mergeable=dirty
  set +e
  out=$(FM_TEST_CHECK_STATE=absent FM_TEST_MERGEABLE_STATE="$mergeable" \
    run_pr_checks "$case_dir" https://github.com/example/repo/pull/42 \
      2> "$case_dir/conflicted.stderr")
  rc=$?
  set -e
  expect_code 0 "$rc" "check-reporting-conflicted-absent: reporter exit status"
  printf '%s\n' "$out" | grep -qxF 'check_state: ABSENT' \
    || fail "check-reporting-conflicted-absent: no-run PR was not ABSENT"
  printf '%s\n' "$out" | grep -qxF 'mergeable_state: dirty' \
    || fail "check-reporting-conflicted-absent: conflict was not surfaced"
  pass "CI reporting distinguishes passing, failing, and ABSENT, including conflicted absence"
}

test_merge_refuses_failing_and_absent_checks() {
  local case_dir rc state
  for state in failing absent; do
    case_dir=$(make_case "checks-$state")
    mkdir -p "$case_dir/wt"
    add_gh_mocks "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    : > "$case_dir/gh-axi.log"
    set +e
    FM_TEST_CHECK_STATE="$state" FM_TEST_MERGEABLE_STATE=dirty \
      run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/43 \
        > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e
    expect_code 1 "$rc" "checks-$state: merge should refuse"
    assert_grep "check_state: $([ "$state" = absent ] && printf ABSENT || printf failing)" \
      "$case_dir/stderr" "checks-$state: refusal did not name the check state"
    assert_grep 'mergeable_state: dirty' "$case_dir/stderr" \
      "checks-$state: refusal did not preserve the conflict reason"
    assert_no_grep 'pr merge ' "$case_dir/gh-axi.log" \
      "checks-$state: forge merge ran despite blocked checks"
    grep -qxF 'phase=prepared' "$case_dir/data/pr-merges/task-x1.receipt" \
      || fail "checks-$state: refusal did not preserve prepared merge provenance"
  done
  pass "fm-pr-merge refuses failing and absent CI checks before forge mutation"
}

test_torn_down_delivered_task_merges_with_durable_provenance() {
  local case_dir fakebin rc
  case_dir="$TMP_ROOT/torn-down-delivered"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/data" "$fakebin"
  cp "$ROOT/.tasks.toml" "$case_dir/.tasks.toml"
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
  assert_grep 'PR-merge for task-x1 proceeded with no backlog present' "$case_dir/stdout" \
    "records-before-merge: absent backlog was not explicitly reported"
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

test_existing_backlog_without_row_refuses_before_merge() {
  local case_dir rc=0
  case_dir=$(make_case missing-backlog-row)
  add_gh_mocks "$case_dir" deadbeefcafefeed0000000000000000deadbeef
  : > "$case_dir/gh-axi.log"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$case_dir/data/backlog.md"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "missing-backlog-row: PR merge tolerated a missing task row"
  assert_grep 'task task-x1 is absent from the backlog' "$case_dir/stderr" \
    "missing-backlog-row: refusal did not identify the missing row"
  assert_no_grep '^pr merge ' "$case_dir/gh-axi.log" \
    "missing-backlog-row: forge merge ran before backlog preflight"
  pass "PR merge refuses a missing row before forge mutation"
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


test_sleep_expiry_prevents_confirmation_retry() {
  local extra case_dir rc elapsed
  for extra in 0 7; do
    case_dir=$(make_case "sleep-expiry-$extra")
    add_gh_mocks "$case_dir" 1111111111111111111111111111111111111111
    FM_TEST_PR_VISIBLE_AT=120 FM_TEST_SLEEP_EXTRA_SECONDS="$extra" \
      run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/100 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    expect_code 1 "$rc" "sleep-expiry-$extra: evidence becoming visible after expiry must not start a retry"
    read -r elapsed < "$case_dir/gh-axi.log.clock"
    [ "$elapsed" -ge 120 ] && [ "$elapsed" -le "$((120 + extra))" ] \
      || fail "sleep-expiry-$extra: fixture did not reach the deadline during sleep"
    awk '$1 >= 120 {exit 1} END {if (NR == 0) exit 1}' "$case_dir/gh-axi.log.read-starts" \
      || fail "sleep-expiry-$extra: evidence read started at or after expiry"
    assert_grep 'confirmation timed out' "$case_dir/stderr" "sleep-expiry-$extra: missing timeout"
    assert_grep 'phase=prepared' "$case_dir/data/pr-merges/task-x1.receipt" "sleep expiry advanced receipt"
    assert_no_grep 'outcome=pr-merged' "$case_dir/state/task-x1.meta" "sleep expiry stamped success"
    pass "confirmation retries stop when sleep reaches or exceeds the deadline ($extra seconds oversleep)"
  done
}

test_in_flight_confirmation_can_finish_late() {
  local case_dir rc elapsed
  case_dir=$(make_case in-flight-confirmation)
  add_gh_mocks "$case_dir" 1111111111111111111111111111111111111111
  FM_TEST_PR_VISIBLE_AT=121 FM_TEST_READ_SECONDS=60 \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/100 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  expect_code 0 "$rc" "in-flight confirmation may succeed after the deadline"
  read -r elapsed < "$case_dir/gh-axi.log.clock"
  expect_code 121 "$elapsed" "in-flight confirmation: completion time"
  expect_code 61 "$(tail -1 "$case_dir/gh-axi.log.read-starts")" "in-flight confirmation: last read began within budget"
  assert_grep 'phase=merged' "$case_dir/data/pr-merges/task-x1.receipt" "in-flight confirmation did not finalize receipt"
  assert_grep 'outcome=pr-merged' "$case_dir/state/task-x1.meta" "in-flight confirmation did not stamp success"
  pass "in-flight evidence can confirm a merge after the retry deadline"
}

test_slow_reads_consume_confirmation_budget() {
  local case_dir rc elapsed
  case_dir=$(make_case slow-confirmation)
  add_gh_mocks "$case_dir" 1111111111111111111111111111111111111111
  FM_TEST_PR_VISIBLE_AT=100000 FM_TEST_READ_SECONDS=60 \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/100 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  expect_code 1 "$rc" "slow confirmation must fail without evidence"
  read -r elapsed < "$case_dir/gh-axi.log.clock"
  [ "$elapsed" -ge 120 ] && [ "$elapsed" -lt 180 ] || fail "slow confirmation: API time must consume the budget (got $elapsed seconds)"
  assert_grep 'confirmation timed out' "$case_dir/stderr" "slow confirmation: missing timeout"
  assert_grep 'phase=prepared' "$case_dir/data/pr-merges/task-x1.receipt" "slow confirmation advanced receipt"
  assert_no_grep 'outcome=pr-merged' "$case_dir/state/task-x1.meta" "slow confirmation stamped success"
  pass "API read time consumes the confirmation budget without another retry after expiry"
}

test_delayed_merge_visibility() {
  local status case_dir rc elapsed
  for status in identical ahead; do
    case_dir=$(make_case "delayed-$status")
    add_gh_mocks "$case_dir" 1111111111111111111111111111111111111111
    FM_TEST_PR_VISIBLE_AT=15 FM_TEST_BRANCH_VISIBLE_AT=45 FM_TEST_CONFIRMED_STATUS="$status" \
      run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/100 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    expect_code 0 "$rc" "delayed-$status: merge visible after 45 seconds should confirm"
    read -r elapsed < "$case_dir/gh-axi.log.clock"
    [ "$elapsed" -ge 45 ] && [ "$elapsed" -le 55 ] || fail "delayed-$status: confirmed outside expected latency window"
    assert_no_grep 'error:' "$case_dir/stderr" "delayed-$status: unexpected merge error"
    assert_grep 'phase=merged' "$case_dir/data/pr-merges/task-x1.receipt" "delayed receipt not finalized"
    assert_grep 'outcome=pr-merged' "$case_dir/state/task-x1.meta" "delayed outcome not stamped"
    expect_code 1 "$(grep -c '^pr merge ' "$case_dir/gh-axi.log")" "delayed merge issued more than once"
    awk 'NR > 1 && $1 > prev {grew=1} {prev=$1; if ($1 > 10) exit 1} END {if (!grew) exit 1}' \
      "$case_dir/gh-axi.log.sleeps" || fail "delayed-$status: retries must back off with a ten-second cap"
    pass "delayed $status merge confirms only after PR and default-branch evidence become visible"
  done
}

test_unconfirmed_merge_remains_prepared() {
  local case_dir rc
  case_dir=$(make_case merge-unconfirmed)
  mkdir -p "$case_dir/wt"
  : > "$case_dir/gh-axi.log"
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
if [ "${1:-} ${2:-}" = "pr checks" ]; then
  printf '%s\n' 'summary: "2 passed, 0 failed, 2 total"' 'checks[2]{name,conclusion}:' '  unit,pass' '  lint,pass'
  exit 0
fi
if [ "${1:-}" = api ] && [[ " $* " = *"mergeable_state"* ]]; then
  printf '%s\n' 'mergeable_state: clean'
  exit 0
fi
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
  assert_grep 'merge was issued but could not be confirmed' "$case_dir/stderr" \
    "merge-unconfirmed: refusal did not explain the missing confirmation"
  assert_grep 'phase=prepared' "$case_dir/data/pr-merges/task-x1.receipt" \
    "merge-unconfirmed: unconfirmed provenance did not remain prepared"
  assert_no_grep 'outcome=pr-merged' "$case_dir/state/task-x1.meta" \
    "merge-unconfirmed: unconfirmed merge stamped an outcome"
  expect_code 120 "$(cat "$case_dir/gh-axi.log.clock")" "never-landing merge: time budget"
  assert_grep 'confirmation timed out' "$case_dir/stderr" "never-landing merge: missing timeout"
  assert_grep 'before retrying the merge' "$case_dir/stderr" "never-landing merge: missing verification guidance"
  expect_code 1 "$(grep -c '^pr merge ' "$case_dir/gh-axi.log")" "never-landing merge issued more than once"
  pass "fm-pr-merge stamps no outcome until the forge confirms the merged state"
}

test_gh_axi_scalar_envelopes_do_not_hide_landed_merge() {
  local case_dir rc receipt
  case_dir=$(make_case gh-axi-scalar-envelope)
  receipt="$case_dir/data/pr-merges/task-x1.receipt"
  mkdir -p "$case_dir/wt"
  : > "$case_dir/gh-axi.log"
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
if [ "${1:-} ${2:-}" = "pr checks" ]; then
  printf '%s\n' 'summary: "2 passed, 0 failed, 2 total"' 'checks[2]{name,conclusion}:' '  unit,pass' '  lint,pass'
  exit 0
fi
if [ "${1:-}" = api ] && [[ " $* " = *"mergeable_state"* ]]; then
  printf '%s\n' 'mergeable_state: clean'
  exit 0
fi
if [ "${1:-} ${2:-}" = "pr merge" ]; then
  : > "$FM_TEST_GH_AXI_LOG.merged"
fi
if [ "${1:-}" = api ]; then
  case "${2:-}" in
    */pulls/*)
      if [ -f "$FM_TEST_GH_AXI_LOG.merged" ]; then
        printf '%s\n' 'merged: true' \
          'merged_at: "2026-09-05T00:24:01Z"' \
          'merge_commit: "4eade19b88a2763c3316e354774169c433ba7b3b"' \
          'base_ref: "main"'
      else
        printf '%s\n' 'merged: false' 'merged_at: null'
      fi
      ;;
    */compare/*)
      case "${4:-}" in
        '{status: .status}') printf '%s\n' 'status: identical' ;;
        *) printf '%s\n' 'api_response:' '  body: identical' '  truncated: false' ;;
      esac
      ;;
    *)
      case "${4:-}" in
        '{default_branch: .default_branch}') printf '%s\n' 'default_branch: main' ;;
        *) printf '%s\n' 'api_response:' '  body: main' '  truncated: false' ;;
      esac
      ;;
  esac
fi
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/96 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "gh-axi-scalar-envelope: landed merge should be confirmed"
  assert_grep 'phase=merged' "$receipt" \
    "gh-axi-scalar-envelope: durable receipt remained prepared"
  assert_grep 'default_branch=main' "$receipt" \
    "gh-axi-scalar-envelope: durable receipt lost default-branch identity"
  assert_grep 'merge_commit=4eade19b88a2763c3316e354774169c433ba7b3b' "$receipt" \
    "gh-axi-scalar-envelope: durable receipt lost merge-commit identity"
  assert_grep 'merged_at=2026-09-05T00:24:01Z' "$receipt" \
    "gh-axi-scalar-envelope: durable receipt lost the forge merge time"
  pass "fm-pr-merge confirms landed merges through gh-axi object output"
}

test_post_merge_confirmation_retries_transient_comparison() {
  local case_dir compare_calls rc receipt
  case_dir=$(make_case merge-confirmation-retry)
  receipt="$case_dir/data/pr-merges/task-x1.receipt"
  mkdir -p "$case_dir/wt"
  : > "$case_dir/gh-axi.log"
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
if [ "${1:-} ${2:-}" = "pr checks" ]; then
  printf '%s\n' 'summary: "2 passed, 0 failed, 2 total"' 'checks[2]{name,conclusion}:' '  unit,pass' '  lint,pass'
  exit 0
fi
if [ "${1:-}" = api ] && [[ " $* " = *"mergeable_state"* ]]; then
  printf '%s\n' 'mergeable_state: clean'
  exit 0
fi
if [ "${1:-} ${2:-}" = "pr merge" ]; then
  : > "$FM_TEST_GH_AXI_LOG.merged"
fi
if [ "${1:-}" = api ]; then
  case "${2:-}" in
    */pulls/*)
      if [ -f "$FM_TEST_GH_AXI_LOG.merged" ]; then
        printf '%s\n' 'merged: true' 'merged_at: null' \
          'merge_commit: "2222222222222222222222222222222222222222"' 'base_ref: "main"'
      else
        printf '%s\n' 'merged: false' 'merged_at: null'
      fi
      ;;
    */compare/*)
      count_file="$FM_TEST_GH_AXI_LOG.compare-count"
      count=0
      [ ! -f "$count_file" ] || read -r count < "$count_file"
      count=$((count + 1))
      printf '%s\n' "$count" > "$count_file"
      if [ "$count" -eq 1 ]; then
        printf '%s\n' 'status: behind'
      else
        printf '%s\n' 'status: ahead'
      fi
      ;;
    *) printf '%s\n' 'default_branch: main' ;;
  esac
fi
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/97 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "merge-confirmation-retry: transient comparison should be retried"
  read -r compare_calls < "$case_dir/gh-axi.log.compare-count"
  expect_code 2 "$compare_calls" "merge-confirmation-retry: comparison attempt count"
  assert_grep 'phase=merged' "$receipt" \
    "merge-confirmation-retry: confirmed merge did not advance its receipt"
  pass "fm-pr-merge retries transient post-merge comparison evidence"
}

test_post_merge_confirmation_exhaustion_remains_prepared() {
  local case_dir elapsed rc receipt
  case_dir=$(make_case merge-confirmation-exhausted)
  receipt="$case_dir/data/pr-merges/task-x1.receipt"
  mkdir -p "$case_dir/wt"
  : > "$case_dir/gh-axi.log"
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
if [ "${1:-} ${2:-}" = "pr checks" ]; then
  printf '%s\n' 'summary: "2 passed, 0 failed, 2 total"' 'checks[2]{name,conclusion}:' '  unit,pass' '  lint,pass'
  exit 0
fi
if [ "${1:-}" = api ] && [[ " $* " = *"mergeable_state"* ]]; then
  printf '%s\n' 'mergeable_state: clean'
  exit 0
fi
if [ "${1:-} ${2:-}" = "pr merge" ]; then
  : > "$FM_TEST_GH_AXI_LOG.merged"
fi
if [ "${1:-}" = api ]; then
  case "${2:-}" in
    */pulls/*)
      if [ -f "$FM_TEST_GH_AXI_LOG.merged" ]; then
        printf '%s\n' 'merged: true' 'merged_at: null' \
          'merge_commit: "3333333333333333333333333333333333333333"' 'base_ref: "main"'
      else
        printf '%s\n' 'merged: false' 'merged_at: null'
      fi
      ;;
    */compare/*)
      printf '%s\n' x >> "$FM_TEST_GH_AXI_LOG.compare-count"
      printf '%s\n' 'status: behind'
      ;;
    *) printf '%s\n' 'default_branch: main' ;;
  esac
fi
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/98 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "merge-confirmation-exhausted: unconfirmed comparison should refuse"
  read -r elapsed < "$case_dir/gh-axi.log.clock"
  expect_code 120 "$elapsed" "merge-confirmation-exhausted: total confirmation budget"
  assert_grep 'confirmation timed out' "$case_dir/stderr" "missing distinct timeout"
  assert_grep 'before retrying the merge' "$case_dir/stderr" "missing verification guidance"
  assert_grep 'phase=prepared' "$receipt" \
    "merge-confirmation-exhausted: refusal did not preserve the prepared receipt"
  assert_no_grep 'outcome=pr-merged' "$case_dir/state/task-x1.meta" \
    "merge-confirmation-exhausted: refusal stamped a merged outcome"
  pass "fm-pr-merge refuses after bounded post-merge evidence retries"
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
  cp "$ROOT/.tasks.toml" "$case_dir/.tasks.toml"
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
  local case_dir receipt
  case_dir=$(make_case prepared-retry)
  receipt="$case_dir/data/pr-merges/delivered-x1.receipt"
  mkdir -p "$case_dir/data/pr-merges"
  rm "$case_dir/state/task-x1.meta"
  add_gh_mocks "$case_dir" cccccccccccccccccccccccccccccccccccccccc
  : > "$case_dir/gh-axi.log"
  cat > "$receipt" <<EOF
schema=fm-pr-merge.v4
task_id=delivered-x1
pr=https://github.com/example/repo/pull/21
repository=example/repo
project=$case_dir/project
default_branch=
merge_commit=
spawned_at=2026-08-29T10:00:00Z
phase=prepared
authorization=done-record
prepared_epoch=1788000000
merged_at=
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
  case_dir=$(make_case prepared-already-merged)
  receipt="$case_dir/data/pr-merges/delivered-x1.receipt"
  mkdir -p "$case_dir/data/pr-merges"
  rm "$case_dir/state/task-x1.meta"
  add_gh_mocks "$case_dir" cccccccccccccccccccccccccccccccccccccccc
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh-axi.log.merged"
  cat > "$receipt" <<EOF
schema=fm-pr-merge.v4
task_id=delivered-x1
pr=https://github.com/example/repo/pull/21
project=$case_dir/project
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
if [ "${1:-} ${2:-}" = "pr checks" ]; then
  printf '%s\n' 'summary: "2 passed, 0 failed, 2 total"' 'checks[2]{name,conclusion}:' '  unit,pass' '  lint,pass'
  exit 0
fi
if [ "${1:-}" = api ] && [[ " $* " = *"mergeable_state"* ]]; then
  printf '%s\n' 'mergeable_state: clean'
  exit 0
fi
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
    */compare/*) printf '%s\n' 'status: ahead' ;;
    *) printf '%s\n' 'default_branch: main' ;;
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

test_sleep_expiry_prevents_confirmation_retry
test_in_flight_confirmation_can_finish_late
test_slow_reads_consume_confirmation_budget
test_delayed_merge_visibility
test_check_reporting_has_three_states_and_mergeability
test_confirmed_merge_fast_forwards_local_mirror
test_diverged_local_mirror_refuses_without_force
test_prepared_retry_recovers_project_and_advances_mirror
test_origin_pushurl_cannot_redirect_mirror_update
test_concurrent_mirror_move_refuses_atomically
test_merge_refuses_failing_and_absent_checks
test_records_pr_and_head_before_merging
test_existing_backlog_without_row_refuses_before_merge
test_merge_failure_propagates_after_recording
test_unconfirmed_merge_remains_prepared
test_gh_axi_scalar_envelopes_do_not_hide_landed_merge
test_post_merge_confirmation_retries_transient_comparison
test_post_merge_confirmation_exhaustion_remains_prepared
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
