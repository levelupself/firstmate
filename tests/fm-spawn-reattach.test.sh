#!/usr/bin/env bash
# fm-spawn.sh --reattach-worktree: recover a task whose endpoint is gone but
# whose retained pooled copy still holds the work.
#
# A fresh spawn always allocates another copy and refreshes it to origin's
# default branch, and --relaunch only adopts the endpoint already named in the
# current record, so neither can rebind a task to a copy its record no longer
# names. These tests pin the recovery path that can, hermetically (stubbed
# session provider and pool inventory, no real agent):
#   1. Every unproved fact refuses BEFORE any endpoint or record changes.
#   2. A success republishes the binding and leaves the retained copy's
#      committed and uncommitted content byte-for-byte intact.
#   3. A failure after the replacement endpoint exists restores the prior
#      record and removes that endpoint, so the operation is all-or-nothing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-reattach)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
TASK_TMPS=()

reattach_cleanup() {
  local d
  for d in "${TASK_TMPS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  rm -rf "$TMP_ROOT"
}
trap reattach_cleanup EXIT

# A tmux stub that models the one thing this path depends on: whether the
# recorded window exists, and where a newly created window's pane sits.
make_tmux_stub() {  # <case-dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
printf '%s\n' "$*" >> "$D/tmux.log"
case "${1:-}" in
  has-session|new-session|set-window-option) exit 0 ;;
  list-windows)
    [ ! -f "$D/windows" ] || cat "$D/windows"
    exit 0
    ;;
  new-window)
    [ -z "${FM_FAKE_NEW_WINDOW_FAIL:-}" ] || exit 1
    cwd=
    while [ $# -gt 0 ]; do
      case "$1" in
        -c) cwd=${2:-}; shift 2 ;;
        -n) printf '%s\n' "${2:-}" >> "$D/windows"; shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s' "$cwd" > "$D/cwd"
    printf '@41\n'
    exit 0
    ;;
  kill-window)
    : > "$D/windows"
    exit 0
    ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *pane_current_path*)
          [ ! -f "$D/cwd" ] || cat "$D/cwd"
          printf '\n'
          exit 0
          ;;
        *pane_current_command*) printf 'bash\n'; exit 0 ;;
        *pane_pid*)
          [ -z "${FM_FAKE_NO_PANE_PID:-}" ] || exit 1
          printf '%s\n' "${FM_FAKE_PANE_PID:-2147483646}"
          exit 0
          ;;
      esac
    done
    printf 'firstmate\n'
    exit 0
    ;;
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s\n' "${1:-}" >> "$D/literal"
      [ -z "${FM_FAKE_LAUNCH_FAIL:-}" ] || case "${1:-}" in *claude*) exit 1 ;; esac
    else
      printf '%s\n' "${1:-}" >> "$D/keys"
      [ -z "${FM_FAKE_ENTER_FAIL:-}" ] || [ "${1:-}" != Enter ] || exit 1
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
}

# A treehouse stub that answers only `status --json`, from a file the case
# owns. A second file, when present, is served from the second call onward, so
# a case can drive the pre-creation and post-creation reads apart.
make_treehouse_stub() {  # <case-dir>
  cat > "$1/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
printf '%s\n' "$*" >> "$D/treehouse.log"
[ "${1:-}" = status ] || exit 1
calls=0
[ ! -f "$D/status-calls" ] || calls=$(cat "$D/status-calls")
calls=$((calls + 1))
printf '%s\n' "$calls" > "$D/status-calls"
[ -z "${FM_FAKE_STATUS_FAIL:-}" ] || exit 1
if [ "$calls" -ge 2 ] && [ -f "$D/status-2.json" ]; then
  cat "$D/status-2.json"
else
  cat "$D/status.json"
fi
exit 0
SH
  chmod +x "$1/fakebin/treehouse"
}

# pool_status_json <retained-path> [processes-json]
pool_status_json() {
  local path=$1 processes=${2:-[]}
  printf '[{"name":"7","path":"%s","status":"available","lease_id":"","lease_holder":"","leased_at":null,"processes":%s}]\n' \
    "$path" "$processes"
}

# new_case <name> <id> -> echoes the case dir.
#
# Models the incident: the task's record names a copy that was already handed
# back, while the copy holding the work still sits in the pool on fm/<id>.
new_case() {  # <name> <id>
  local name=$1 id=$2 dir home proj retained returned
  dir="$TMP_ROOT/$name-$RANDOM"
  home="$dir/home"
  proj="$dir/proj"
  retained="$dir/pool/7/proj"
  returned="$dir/pool/3/proj"
  mkdir -p "$home/state" "$home/data/$id" "$dir/fake"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  : > "$dir/fake/tmux.log"
  : > "$dir/fake/treehouse.log"
  : > "$dir/fake/windows"
  make_tmux_stub "$dir"
  make_treehouse_stub "$dir"

  fm_git_worktree "$proj" "$retained" "fm/$id"
  git -C "$proj" worktree add --quiet --detach "$returned"
  printf 'landed work\n' > "$retained/committed.txt"
  git -C "$retained" add committed.txt
  git -C "$retained" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'task work'

  printf '# brief for %s\n\nDelivery contract: mode=no-mistakes\n' "$id" > "$home/data/$id/brief.md"
  fm_test_backlog_ensure_queue "$home" "$id"
  {
    echo "window=oldses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$returned"
    echo "project=$proj"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-$id"
    echo "model=default"
    echo "effort=default"
    echo "spawned_at=2026-08-13T00:00:00Z"
  } > "$home/state/$id.meta"
  pool_status_json "$retained" > "$dir/fake/status.json"
  TASK_TMPS+=("/tmp/fm-$id")
  printf '%s\n' "$dir"
}

run_reattach() {  # <case-dir> <args...>
  local dir=$1; shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_SPAWN_NO_GUARD=1 \
    FM_FAKE_LAUNCH_FAIL="${FM_FAKE_LAUNCH_FAIL:-}" \
    FM_FAKE_ENTER_FAIL="${FM_FAKE_ENTER_FAIL:-}" \
    FM_FAKE_NEW_WINDOW_FAIL="${FM_FAKE_NEW_WINDOW_FAIL:-}" \
    FM_FAKE_STATUS_FAIL="${FM_FAKE_STATUS_FAIL:-}" \
    FM_FAKE_PANE_PID="${FM_FAKE_PANE_PID:-}" \
    FM_FAKE_NO_PANE_PID="${FM_FAKE_NO_PANE_PID:-}" \
    "$SPAWN" "$@" 2>&1
}

snapshot() {  # <case-dir> <id>
  local dir=$1 id=$2
  cp "$dir/home/state/$id.meta" "$dir/meta.before"
}

# A refusal must leave the record, the endpoint inventory, and the retained
# copy exactly as they were.
assert_nothing_changed() {  # <case-dir> <id> <retained>
  local dir=$1 id=$2 retained=$3
  cmp -s "$dir/meta.before" "$dir/home/state/$id.meta" \
    || fail "a refused reattach changed task metadata"
  [ ! -s "$dir/fake/windows" ] \
    || fail "a refused reattach left a replacement endpoint behind: $(cat "$dir/fake/windows")"
  assert_no_grep 'treehouse get' "$dir/fake/literal" \
    "a refused reattach must never acquire a pooled copy"
  [ "$(cat "$retained/committed.txt" 2>/dev/null)" = 'landed work' ] \
    || fail "a refused reattach changed the retained copy's committed content"
  # The allocation ledger measures pool allocation, and a recovery allocates
  # nothing. A refusal that seeded it would leave a permanent artifact behind an
  # operation that is supposed to change nothing.
  [ -z "$(find "$dir/home/data/worktree-allocations" -type f 2>/dev/null)" ] \
    || fail "a refused reattach left a worktree-allocation ledger behind"
}

# The displaced copy is the one the record named before the recovery. It must be
# named on success and never touched, and never mentioned when nothing moved.
assert_no_displacement_notice() {  # <output>
  case "$1" in
    *'left untouched and still allocated'*)
      fail "a refused reattach announced a displacement that never happened"
      ;;
  esac
}

# --- 1. refusals before anything changes ------------------------------------

test_missing_copy_refuses() {
  local dir id=rt-missing retained missing out rc
  dir=$(new_case missing "$id")
  retained="$dir/pool/7/proj"
  missing="$dir/no-such-copy"
  snapshot "$dir" "$id"
  out=$(run_reattach "$dir" "$id" --reattach-worktree "$missing"); rc=$?
  expect_code 1 "$rc" "a missing retained copy must refuse"$'\n'"$out"
  assert_contains "$out" "retained copy '$missing' is missing" \
    "the refusal must name the path it could not find"
  assert_nothing_changed "$dir" "$id" "$retained"
  [ -d "$retained" ] || fail "the refusal disturbed the real retained copy"
  pass "fm-spawn reattach: a missing retained copy refuses and changes nothing"
}

test_wrong_branch_refuses() {
  local dir id=rt-branch retained out rc
  dir=$(new_case branch "$id")
  retained="$dir/pool/7/proj"
  git -C "$retained" branch -qm fm/some-other-task
  snapshot "$dir" "$id"
  out=$(run_reattach "$dir" "$id" --reattach-worktree "$retained"); rc=$?
  expect_code 1 "$rc" "a copy on the wrong branch must refuse"$'\n'"$out"
  assert_contains "$out" "expected 'fm/$id'" \
    "the refusal must name the branch the task's work belongs on"
  assert_nothing_changed "$dir" "$id" "$retained"
  pass "fm-spawn reattach: a copy holding another task's branch refuses and changes nothing"
}

test_live_agent_refuses() {
  local dir id=rt-live retained out rc
  dir=$(new_case live "$id")
  retained="$dir/pool/7/proj"
  pool_status_json "$retained" '[{"pid":4242,"name":"claude"}]' > "$dir/fake/status.json"
  snapshot "$dir" "$id"
  out=$(run_reattach "$dir" "$id" --reattach-worktree "$retained"); rc=$?
  expect_code 1 "$rc" "a copy with a live process must refuse"$'\n'"$out"
  assert_contains "$out" "live process" \
    "the refusal must name the ownership conflict"
  assert_nothing_changed "$dir" "$id" "$retained"
  pass "fm-spawn reattach: a retained copy someone else is using refuses and changes nothing"
}

test_task_identity_mismatch_refuses() {
  local dir id=rt-identity retained out rc meta
  dir=$(new_case identity "$id")
  retained="$dir/pool/7/proj"
  meta="$dir/home/state/$id.meta"
  sed -i 's/^endpoint_task_id=.*/endpoint_task_id=some-other-task/' "$meta"
  snapshot "$dir" "$id"
  out=$(run_reattach "$dir" "$id" --reattach-worktree "$retained"); rc=$?
  expect_code 1 "$rc" "a record bound to another task must refuse"$'\n'"$out"
  assert_contains "$out" "belongs to task some-other-task, not $id" \
    "the refusal must name the exact identity mismatch"
  assert_nothing_changed "$dir" "$id" "$retained"
  pass "fm-spawn reattach: a record bound to another task refuses and changes nothing"
}

test_existing_endpoint_refuses() {
  local dir id=rt-existing retained out rc
  dir=$(new_case existing "$id")
  retained="$dir/pool/7/proj"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  cp "$dir/home/state/$id.meta" "$dir/meta.before"
  out=$(run_reattach "$dir" "$id" --reattach-worktree "$retained"); rc=$?
  expect_code 1 "$rc" "an endpoint that still exists must refuse"$'\n'"$out"
  assert_contains "$out" "--relaunch" \
    "the refusal must point at the path that adopts an existing endpoint"
  cmp -s "$dir/meta.before" "$dir/home/state/$id.meta" \
    || fail "a refused reattach changed task metadata"
  pass "fm-spawn reattach: a task whose endpoint still exists is relaunch's job, not reattach's"
}

test_unreadable_ownership_refuses() {
  local dir id=rt-unreadable retained out rc
  dir=$(new_case unreadable "$id")
  retained="$dir/pool/7/proj"
  snapshot "$dir" "$id"
  out=$(FM_FAKE_STATUS_FAIL=1 run_reattach "$dir" "$id" --reattach-worktree "$retained"); rc=$?
  expect_code 1 "$rc" "an unreadable pool inventory must refuse"$'\n'"$out"
  assert_nothing_changed "$dir" "$id" "$retained"
  pass "fm-spawn reattach: ownership that cannot be read refuses instead of guessing"
}

test_delivery_axes_cannot_be_overridden() {
  local dir id=rt-axes retained out rc
  dir=$(new_case axes "$id")
  retained="$dir/pool/7/proj"
  snapshot "$dir" "$id"
  out=$(run_reattach "$dir" "$id" --mode direct-PR --reattach-worktree "$retained"); rc=$?
  expect_code 1 "$rc" "a contradicting delivery flag must refuse"$'\n'"$out"
  assert_contains "$out" "--mode cannot override it" \
    "the refusal must say the delivery contract comes from the task's own record"
  assert_nothing_changed "$dir" "$id" "$retained"
  pass "fm-spawn reattach: the recorded delivery contract cannot be overridden on the command line"
}

test_unidentifiable_replacement_pane_refuses() {
  local dir id=rt-panepid retained out rc
  dir=$(new_case panepid "$id")
  retained="$dir/pool/7/proj"
  snapshot "$dir" "$id"
  out=$(FM_FAKE_NO_PANE_PID=1 run_reattach "$dir" "$id" --reattach-worktree "$retained"); rc=$?
  expect_code 1 "$rc" "a replacement pane with no readable process id must refuse"$'\n'"$out"
  assert_contains "$out" "did not report its own process id" \
    "the refusal must name why ownership can no longer be told apart"
  assert_nothing_changed "$dir" "$id" "$retained"
  pass "fm-spawn reattach: a replacement pane it cannot identify refuses instead of guessing ownership"
}

# --- 2. success preserves the work ------------------------------------------

test_uncommitted_content_survives_reattach() {
  local dir id=rt-dirty retained out rc meta tip_before tip_after
  dir=$(new_case dirty "$id")
  retained="$dir/pool/7/proj"
  printf 'unsaved recovery work\n' > "$retained/uncommitted.txt"
  printf 'edited in place\n' >> "$retained/committed.txt"
  tip_before=$(git -C "$retained" rev-parse HEAD)
  out=$(run_reattach "$dir" "$id" --reattach-worktree "$retained"); rc=$?
  expect_code 0 "$rc" "a clean, unowned retained copy should reattach"$'\n'"$out"
  meta="$dir/home/state/$id.meta"

  [ "$(cat "$retained/uncommitted.txt")" = 'unsaved recovery work' ] \
    || fail "the reattach destroyed untracked work in the retained copy"
  assert_grep 'edited in place' "$retained/committed.txt" \
    "the reattach reverted a tracked file's uncommitted edit"
  tip_after=$(git -C "$retained" rev-parse HEAD)
  [ "$tip_before" = "$tip_after" ] \
    || fail "the reattach moved the retained copy off its own tip ($tip_before -> $tip_after)"
  [ "$(git -C "$retained" symbolic-ref --short HEAD)" = "fm/$id" ] \
    || fail "the reattach moved the retained copy off its task branch"

  assert_grep "worktree=$retained" "$meta" \
    "the published record must name the retained copy"
  assert_grep "endpoint_task_id=$id" "$meta" \
    "the published record must keep the exact task identity"
  assert_grep 'window=firstmate:fm-'"$id" "$meta" \
    "the published record must name the replacement endpoint"
  assert_grep 'kind=ship' "$meta" "the published record must keep the recorded kind"
  assert_grep 'mode=no-mistakes' "$meta" "the published record must keep the recorded delivery mode"
  [ "$(grep -c '^worktree=' "$meta")" = 1 ] \
    || fail "the published record must bind exactly one copy"

  assert_no_grep 'treehouse get' "$dir/fake/literal" \
    "the reattach must not acquire another pooled copy"
  assert_no_grep 'get' "$dir/fake/treehouse.log" \
    "the reattach must not ask treehouse to allocate or return anything"
  assert_contains "$out" "spawned $id" "the operation should report success"
  pass "fm-spawn reattach: uncommitted work survives and the retained binding is published"
}

# The staged launch line is a shell command LIST, not a bare command word: the
# gate loop precedes it and a recovery may prepend `unset TRACEPARENT;` ahead of
# the real launch. The other cases only ever record that literal, so a line that
# is well-formed as text but broken as a command would pass them. This one runs
# it for real, in the DEFAULT trace-context-off configuration where the recovery
# does prepend that unset.
test_staged_launch_line_actually_runs_the_agent() {
  local dir id=rt-exec retained out rc line stub ran seen_traceparent
  dir=$(new_case exec "$id")
  retained="$dir/pool/7/proj"
  out=$(run_reattach "$dir" "$id" --reattach-worktree "$retained"); rc=$?
  expect_code 0 "$rc" "the reattach should succeed"$'\n'"$out"

  line=$(grep -F "spawn_gen=" "$dir/fake/literal" | tail -1)
  [ -n "$line" ] || fail "no gated launch line was staged in the replacement pane"

  stub="$dir/execbin"
  mkdir -p "$stub"
  cat > "$stub/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${TRACEPARENT-<unset>}" > "$FM_EXEC_PROBE/traceparent"
: > "$FM_EXEC_PROBE/ran"
exit 0
SH
  chmod +x "$stub/claude"
  mkdir -p "$dir/probe"

  ran=$(cd "$retained" && env PATH="$stub:$PATH" FM_EXEC_PROBE="$dir/probe" \
    TRACEPARENT=00-11111111111111111111111111111111-2222222222222222-01 \
    bash -c "$line" 2>&1)

  [ -f "$dir/probe/ran" ] \
    || fail "the staged launch line never started the agent:"$'\n'"$ran"
  case "$ran" in
    *'not found'*) fail "the staged launch line produced a shell diagnostic:"$'\n'"$ran" ;;
  esac
  seen_traceparent=$(cat "$dir/probe/traceparent")
  [ "$seen_traceparent" = '<unset>' ] \
    || fail "a trace-context-off recovery left TRACEPARENT set for the agent (got '$seen_traceparent')"
  pass "fm-spawn reattach: the staged launch line runs the agent with no inherited trace carrier"
}

test_success_gates_the_agent_behind_the_published_record() {
  local dir id=rt-gate retained out rc gen
  dir=$(new_case gate "$id")
  retained="$dir/pool/7/proj"
  out=$(run_reattach "$dir" "$id" --reattach-worktree "$retained"); rc=$?
  expect_code 0 "$rc" "the reattach should succeed"$'\n'"$out"
  gen=$(grep '^spawn_gen=' "$dir/home/state/$id.meta" | cut -d= -f2-)
  [ -n "$gen" ] || fail "the published record carries no incarnation token"
  assert_grep "spawn_gen=$gen" "$dir/fake/literal" \
    "the replacement agent must wait for its own published record before starting"
  pass "fm-spawn reattach: the replacement agent starts only after the new binding is published"
}

test_displaced_copy_is_named_and_left_alone() {
  local dir id=rt-displaced retained returned out rc ledger
  dir=$(new_case displaced "$id")
  retained="$dir/pool/7/proj"
  returned="$dir/pool/3/proj"
  printf 'work that was never proved\n' > "$returned/unproven.txt"
  out=$(run_reattach "$dir" "$id" --reattach-worktree "$retained"); rc=$?
  expect_code 0 "$rc" "the reattach should succeed"$'\n'"$out"

  assert_contains "$out" "$returned" \
    "a successful reattach must name the copy it displaced so it can be dealt with deliberately"
  assert_contains "$out" "left untouched and still allocated" \
    "the notice must say the displaced copy was not reclaimed"

  [ -d "$returned" ] \
    || fail "the reattach removed the displaced copy instead of leaving it alone"
  [ "$(cat "$returned/unproven.txt")" = 'work that was never proved' ] \
    || fail "the reattach touched content in the displaced copy it had proved nothing about"
  assert_no_grep 'return' "$dir/fake/treehouse.log" \
    "the reattach must never ask treehouse to return the displaced copy"

  # No release may be invented for a copy that was never returned: an unpaired
  # acquire is the honest record that it is still allocated.
  ledger=$(find "$dir/home/data/worktree-allocations" -type f 2>/dev/null | head -1)
  if [ -n "$ledger" ]; then
    assert_no_grep '"event":"release"' "$ledger" \
      "the reattach recorded a pool release that never happened"
  fi
  pass "fm-spawn reattach: the displaced copy is named, left allocated, and never returned or faked as released"
}

test_unresolvable_wiring_snapshot_refuses_before_arming() {
  local dir id=rt-wiring retained token out rc
  dir=$(new_case wiring "$id")
  retained="$dir/pool/7/proj"
  # grok is a harness whose per-task wiring resolution reads a turn-end token
  # file. An unreadable token makes that resolution fail, which is the case a
  # snapshot must refuse on: arming would otherwise proceed with a partial
  # backup that a rollback could not restore.
  sed -i 's/^harness=.*/harness=grok/' "$dir/home/state/$id.meta"
  token="$dir/home/state/$id.grok-turnend-token"
  printf 'prior-token\n' > "$token"
  chmod 000 "$token"
  snapshot "$dir" "$id"
  out=$(run_reattach "$dir" "$id" --reattach-worktree "$retained"); rc=$?
  chmod 600 "$token"
  expect_code 1 "$rc" "an unresolvable wiring snapshot must refuse"$'\n'"$out"
  assert_contains "$out" "existing harness wiring" \
    "the refusal must name the wiring it could not preserve"
  assert_nothing_changed "$dir" "$id" "$retained"
  [ "$(cat "$token")" = 'prior-token' ] \
    || fail "the refused reattach disturbed the prior turn-end token"
  pass "fm-spawn reattach: wiring that cannot be preserved refuses before anything is armed"
}

# --- 3. all-or-nothing ------------------------------------------------------

# Trace context is default-off, so its interaction with a held record lock and
# an unpublished record only shows up when it is deliberately enabled.
test_recorded_trace_carrier_survives_reattach() {
  local dir id=rt-trace retained out rc carrier recorded injected
  dir=$(new_case trace "$id")
  retained="$dir/pool/7/proj"
  carrier=00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
  mkdir -p "$dir/home/config"
  printf 'on\n' > "$dir/home/config/trace-context"
  printf '%s\n' "$$" > "$dir/home/state/.lock"
  printf '%s on\n' "$$" > "$dir/home/state/.trace-context-effective"
  printf 'traceparent=%s\n' "$carrier" >> "$dir/home/state/$id.meta"
  out=$(run_reattach "$dir" "$id" --reattach-worktree "$retained"); rc=$?
  expect_code 0 "$rc" "a reattach with trace context enabled should succeed"$'\n'"$out"
  recorded=$(grep '^traceparent=' "$dir/home/state/$id.meta" | cut -d= -f2-)
  [ "$recorded" = "$carrier" ] \
    || fail "the reattach lost the task's recorded trace identity (got '$recorded')"
  [ "$(grep -c '^traceparent=' "$dir/home/state/$id.meta")" = 1 ] \
    || fail "the published record must carry exactly one trace identity"
  injected=$(grep '^export TRACEPARENT=' "$dir/fake/keys" | tail -1 | cut -d= -f2-)
  [ "$injected" = "$carrier" ] \
    || fail "the replacement agent was given a different trace identity (got '$injected')"
  pass "fm-spawn reattach: the task keeps one trace identity across the recovery"
}

test_launch_failure_restores_everything() {
  local dir id=rt-rollback retained out rc
  dir=$(new_case rollback "$id")
  retained="$dir/pool/7/proj"
  printf 'must survive the rollback\n' > "$retained/uncommitted.txt"
  snapshot "$dir" "$id"
  out=$(FM_FAKE_LAUNCH_FAIL=1 run_reattach "$dir" "$id" --reattach-worktree "$retained"); rc=$?
  expect_code 1 "$rc" "a launch transport failure must fail the operation"$'\n'"$out"
  cmp -s "$dir/meta.before" "$dir/home/state/$id.meta" \
    || fail "a failed reattach did not restore the prior record byte-for-byte"
  [ ! -s "$dir/fake/windows" ] \
    || fail "a failed reattach left the replacement endpoint behind"
  [ "$(cat "$retained/uncommitted.txt")" = 'must survive the rollback' ] \
    || fail "a failed reattach destroyed uncommitted work"
  pass "fm-spawn reattach: a failure after the endpoint exists restores the record and removes it"
}

# The prior record is the only rollback material a reattach has. When the
# restore itself cannot be completed, destroying that copy would leave the task
# bound to an endpoint the rollback just removed with nothing left to undo it.
test_failed_restore_keeps_the_prior_record() {
  local dir id=rt-restorefail retained out rc preserved
  dir=$(new_case restorefail "$id")
  retained="$dir/pool/7/proj"
  # Fail only the restore move, so the operation gets past publication and then
  # cannot put the prior record back.
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in *reattach-prior*) exit 1 ;; esac
done
[ ! -x /bin/mv ] || exec /bin/mv "$@"
exec /usr/bin/mv "$@"
SH
  chmod +x "$dir/fakebin/mv"
  snapshot "$dir" "$id"
  out=$(FM_FAKE_ENTER_FAIL=1 run_reattach "$dir" "$id" --reattach-worktree "$retained"); rc=$?
  expect_code 1 "$rc" "a failure after publication must fail the operation"$'\n'"$out"
  [ ! -s "$dir/fake/windows" ] \
    || fail "the failed reattach left the replacement endpoint behind"

  preserved=$(find "$dir/home/state" -name ".$id.meta.reattach-prior.*" | head -1)
  [ -n "$preserved" ] \
    || fail "a failed restore deleted the only copy of task $id's prior record"$'\n'"$out"
  cmp -s "$dir/meta.before" "$preserved" \
    || fail "the preserved copy is not the record the reattach displaced"
  assert_contains "$out" "$preserved" \
    "the warning must name where the only copy of the prior record was left"
  pass "fm-spawn reattach: a restore that fails keeps the prior record and says where it is"
}

test_ownership_race_after_endpoint_creation_refuses() {
  local dir id=rt-race retained out rc racer
  dir=$(new_case race "$id")
  retained="$dir/pool/7/proj"
  /bin/sleep 30 &
  racer=$!
  pool_status_json "$retained" "[{\"pid\":$racer,\"name\":\"claude\"}]" > "$dir/fake/status-2.json"
  snapshot "$dir" "$id"
  out=$(run_reattach "$dir" "$id" --reattach-worktree "$retained"); rc=$?
  kill "$racer" 2>/dev/null || true
  wait "$racer" 2>/dev/null || true
  expect_code 1 "$rc" "an owner arriving after endpoint creation must refuse"$'\n'"$out"
  assert_contains "$out" "live process" \
    "the refusal must name the ownership conflict it caught"
  cmp -s "$dir/meta.before" "$dir/home/state/$id.meta" \
    || fail "the caught race left the record changed"
  [ ! -s "$dir/fake/windows" ] \
    || fail "the caught race left the replacement endpoint behind"
  pass "fm-spawn reattach: an owner that arrives before publication is caught and rolled back"
}

# Run each case through a dispatcher: a name with no matching function is a
# missing test, which must fail the run rather than pass quietly.
run_case() {  # <function-name>
  if ! declare -F "$1" >/dev/null; then
    fail "test case $1 is listed but not defined"
  fi
  "$1"
}

run_case test_missing_copy_refuses
run_case test_wrong_branch_refuses
run_case test_live_agent_refuses
run_case test_task_identity_mismatch_refuses
run_case test_existing_endpoint_refuses
run_case test_unreadable_ownership_refuses
run_case test_delivery_axes_cannot_be_overridden
run_case test_unidentifiable_replacement_pane_refuses
run_case test_uncommitted_content_survives_reattach
run_case test_displaced_copy_is_named_and_left_alone
run_case test_unresolvable_wiring_snapshot_refuses_before_arming
run_case test_staged_launch_line_actually_runs_the_agent
run_case test_success_gates_the_agent_behind_the_published_record
run_case test_recorded_trace_carrier_survives_reattach
run_case test_launch_failure_restores_everything
run_case test_failed_restore_keeps_the_prior_record
run_case test_ownership_race_after_endpoint_creation_refuses

echo "# all fm-spawn-reattach tests passed"
