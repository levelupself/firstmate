#!/usr/bin/env bash
# fm-spawn.sh retained-worktree reattach recovery.
#
# The recovery path must prove the task and copy identities before creating a
# replacement endpoint, and it must never refresh, reset, or discard the copy.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-reattach)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

make_tmux_stub() {  # <dir>
  local dir=$1
  mkdir -p "$dir/fakebin" "$dir/fake"
  : > "$dir/fake/tmux.log"
  : > "$dir/fake/literal"
  : > "$dir/fake/treehouse.log"
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
printf '%s\n' "$*" >> "$D/tmux.log"
case "${1:-}" in
  has-session) exit 0 ;;
  list-windows)
    [ ! -f "$D/window-live" ] || printf 'fm-%s\n' "$FM_FAKE_TASK_ID"
    ;;
  new-window)
    cwd=
    while [ $# -gt 0 ]; do
      case "$1" in
        -c) cwd=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s' "$cwd" > "$D/cwd"
    : > "$D/window-live"
    printf '@17\n'
    ;;
  set-window-option) ;;
  display-message)
    for arg in "$@"; do
      case "$arg" in
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
        *pane_current_command*) printf 'bash\n'; exit 0 ;;
        *pane_id*) printf '%%17\n'; exit 0 ;;
      esac
    done
    printf 'firstmate\n'
    ;;
  send-keys)
    [ -z "${FM_FAKE_SEND_FAIL:-}" ] || exit 1
    if [ "${*: -1}" = Enter ] && [ -f "$D/launch-staged" ]; then
      if [ -n "${FM_FAKE_REQUIRE_COMMIT:-}" ] \
         && ! grep -q '^while ! grep -qxF ' "$D/literal"; then
        printf 'agent activated before commit\n' > "$FM_FAKE_RETAINED/agent-ran-before-commit.txt"
      fi
      [ -z "${FM_FAKE_ENTER_FAIL:-}" ] || exit 1
    fi
    shift
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l)
          shift
          printf '%s\n' "${1:-}" >> "$D/literal"
          case "${1:-}" in *claude*) : > "$D/launch-staged" ;; esac
          exit 0
          ;;
        *) shift ;;
      esac
    done
    ;;
  kill-window)
    [ -n "${FM_FAKE_KILL_FAIL:-}" ] || rm -f "$D/window-live"
    ;;
  capture-pane) printf 'ready\n' ;;
esac
exit 0
SH
  chmod +x "$dir/fakebin/tmux"
  cat > "$dir/fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/fakebin/sleep"
}

make_treehouse_stub() {  # <dir>
  local dir=$1
  cat > "$dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_DIR/treehouse.log"
[ "${1:-}" = status ] && [ "${2:-}" = --json ] || {
  echo "error: unexpected treehouse command: $*" >&2
  exit 1
}
if [ -n "${FM_FAKE_TREEHOUSE_MALFORMED:-}" ]; then
  printf 'not-json\n'
  exit 0
fi
if [ -n "${FM_FAKE_REFUSE_LOCKED_STATUS:-}" ] \
   && ! flock -n "$FM_FAKE_RETAINED/../../treehouse-state.lock" true 2>/dev/null; then
  echo "error: recursive Treehouse lock" >&2
  exit 88
fi
jq -cn \
  --arg path "$FM_FAKE_RETAINED" \
  --argjson processes "${FM_FAKE_TREEHOUSE_PROCESSES:-[]}" \
  '[{name:"7", path:$path, status:(if ($processes | length) == 0 then "available" else "in-use" end), lease_id:"", lease_holder:"", leased_at:null, processes:$processes}]'
SH
  chmod +x "$dir/fakebin/treehouse"
}

new_case() {  # <name> <id>
  local name=$1 id=$2 dir project retained
  dir="$TMP_ROOT/$name-$RANDOM"
  mkdir -p "$dir/home/state" "$dir/home/data/$id" "$dir/fake"
  project="$dir/project"
  retained="$dir/pool/7/project"
  fm_git_worktree "$project" "$retained" "fm/$id"
  jq -n --arg path "$retained" '{worktrees:[{name:"7",path:$path,created_at:"2026-01-01T00:00:00Z"}]}' \
    > "$dir/pool/treehouse-state.json"
  printf '# brief\n\nDelivery contract: mode=no-mistakes\n' > "$dir/home/data/$id/brief.md"
  {
    echo "window=firstmate:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$dir/returned-copy"
    echo "project=$project"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
  } > "$dir/home/state/$id.meta"
  make_tmux_stub "$dir"
  make_treehouse_stub "$dir"
  printf '%s\n' "$dir"
}

run_reattach() {  # <dir> <id> <worktree>
  local dir=$1 id=$2 retained=$3
  env PATH="$dir/fakebin:$PATH" \
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_SPAWN_NO_GUARD=1 \
    FM_FAKE_DIR="$dir/fake" FM_FAKE_TASK_ID="$id" \
    FM_FAKE_RETAINED="$retained" \
    FM_FAKE_TREEHOUSE_PROCESSES="${FM_FAKE_TREEHOUSE_PROCESSES:-[]}" \
    FM_FAKE_SEND_FAIL="${FM_FAKE_SEND_FAIL:-}" \
    FM_FAKE_ENTER_FAIL="${FM_FAKE_ENTER_FAIL:-}" \
    FM_FAKE_REQUIRE_COMMIT="${FM_FAKE_REQUIRE_COMMIT:-}" \
    FM_FAKE_KILL_FAIL="${FM_FAKE_KILL_FAIL:-}" \
    FM_FAKE_REFUSE_LOCKED_STATUS="${FM_FAKE_REFUSE_LOCKED_STATUS:-}" \
    "$SPAWN" "$id" --reattach-worktree "$retained" 2>&1
}

run_reattach_with_axes() {  # <dir> <id> <worktree>
  local dir=$1 id=$2 retained=$3
  env PATH="$dir/fakebin:$PATH" \
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_SPAWN_NO_GUARD=1 \
    FM_FAKE_DIR="$dir/fake" FM_FAKE_TASK_ID="$id" \
    FM_FAKE_RETAINED="$retained" \
    "$SPAWN" "$id" --mode direct-PR --yolo on --reattach-worktree "$retained" 2>&1
}

assert_unchanged_refusal() {  # <dir> <id> <before-meta>
  local dir=$1 id=$2 before=$3
  cmp -s "$before" "$dir/home/state/$id.meta" \
    || fail "a refused reattach changed task metadata"
  [ ! -e "$dir/fake/window-live" ] \
    || fail "a refused reattach left a replacement endpoint behind"
}

test_wrong_branch_refuses() {
  local dir id=rt-wrong-branch retained out rc before
  dir=$(new_case wrong-branch "$id")
  retained="$dir/pool/7/project"
  git -C "$retained" branch -m fm/some-other-task
  before="$dir/meta.before"
  cp "$dir/home/state/$id.meta" "$before"
  out=$(run_reattach "$dir" "$id" "$retained"); rc=$?
  expect_code 1 "$rc" "wrong branch must refuse"$'\n'"$out"
  assert_contains "$out" "expected 'fm/$id'" "wrong-branch refusal must name the expected task branch"
  assert_unchanged_refusal "$dir" "$id" "$before"
  pass "fm-spawn reattach: wrong branch refuses without publishing or creating an endpoint"
}

test_live_agent_refuses() {
  local dir id=rt-live retained out rc before
  dir=$(new_case live "$id")
  retained="$dir/pool/7/project"
  before="$dir/meta.before"
  cp "$dir/home/state/$id.meta" "$before"
  out=$(FM_FAKE_TREEHOUSE_PROCESSES='[{"pid":42,"name":"codex"}]' \
    run_reattach "$dir" "$id" "$retained"); rc=$?
  expect_code 1 "$rc" "live owner must refuse"$'\n'"$out"
  assert_contains "$out" "live process" "live-owner refusal must name the ownership conflict"
  assert_unchanged_refusal "$dir" "$id" "$before"
  pass "fm-spawn reattach: a live owner refuses without publishing or creating an endpoint"
}

test_task_identity_mismatch_refuses() {
  local dir id=rt-identity retained out rc before meta
  dir=$(new_case identity "$id")
  retained="$dir/pool/7/project"
  meta="$dir/home/state/$id.meta"
  sed 's/^endpoint_task_id=.*/endpoint_task_id=another-task/' "$meta" > "$meta.tmp"
  mv "$meta.tmp" "$meta"
  before="$dir/meta.before"
  cp "$meta" "$before"
  out=$(run_reattach "$dir" "$id" "$retained"); rc=$?
  expect_code 1 "$rc" "task identity mismatch must refuse"$'\n'"$out"
  assert_contains "$out" "belongs to task another-task, not $id" "identity refusal must name the exact mismatch"
  assert_unchanged_refusal "$dir" "$id" "$before"
  pass "fm-spawn reattach: task identity mismatch refuses without publishing or creating an endpoint"
}

test_missing_copy_refuses() {
  local dir id=rt-missing retained missing out rc before
  dir=$(new_case missing "$id")
  retained="$dir/pool/7/project"
  missing="$dir/no-such-copy"
  before="$dir/meta.before"
  cp "$dir/home/state/$id.meta" "$before"
  out=$(run_reattach "$dir" "$id" "$missing"); rc=$?
  expect_code 1 "$rc" "missing copy must refuse"$'\n'"$out"
  assert_contains "$out" "retained worktree '$missing' is missing" "missing-copy refusal must name the path"
  assert_unchanged_refusal "$dir" "$id" "$before"
  [ -d "$retained" ] || fail "the unrelated retained fixture copy disappeared"
  pass "fm-spawn reattach: a missing retained copy refuses without publishing or creating an endpoint"
}

test_uncommitted_content_survives_success() {
  local dir id=rt-dirty retained out rc meta
  dir=$(new_case dirty "$id")
  retained="$dir/pool/7/project"
  printf 'uncommitted recovery content\n' > "$retained/recovery.txt"
  out=$(run_reattach "$dir" "$id" "$retained"); rc=$?
  expect_code 0 "$rc" "dirty retained copy should reattach"$'\n'"$out"
  meta="$dir/home/state/$id.meta"
  assert_grep "worktree=$retained" "$meta" "published binding must name the retained copy"
  assert_grep 'endpoint_task_id=rt-dirty' "$meta" "published binding must preserve exact task identity"
  [ "$(cat "$retained/recovery.txt")" = 'uncommitted recovery content' ] \
    || fail "reattach changed or removed uncommitted content"
  assert_grep '?? recovery.txt' <(git -C "$retained" status --porcelain) \
    "uncommitted content must remain uncommitted after reattach"
  assert_no_grep 'get\|return' "$dir/fake/treehouse.log" \
    "reattach must not allocate, reset, or return the retained copy"
  assert_no_grep 'treehouse get' "$dir/fake/literal" \
    "reattach must not run the normal pooled-copy acquisition"
  pass "fm-spawn reattach: uncommitted content survives and the new binding is published"
}

test_launch_failure_rolls_back_the_binding() {
  local dir id=rt-rollback retained out rc before wiring
  dir=$(new_case rollback "$id")
  retained="$dir/pool/7/project"
  printf 'must survive rollback\n' > "$retained/rollback.txt"
  before="$dir/meta.before"
  cp "$dir/home/state/$id.meta" "$before"
  wiring="$dir/home/state/$id.claude-turnend-token"
  printf 'prior-token\n' > "$wiring"
  out=$(FM_FAKE_SEND_FAIL=1 run_reattach "$dir" "$id" "$retained"); rc=$?
  expect_code 1 "$rc" "launch transport failure must roll back"$'\n'"$out"
  cmp -s "$before" "$dir/home/state/$id.meta" \
    || fail "failed reattach did not restore prior metadata byte-for-byte"
  [ ! -e "$dir/fake/window-live" ] \
    || fail "failed reattach left the replacement endpoint behind"
  [ "$(cat "$retained/rollback.txt")" = 'must survive rollback' ] \
    || fail "failed reattach changed uncommitted content"
  [ "$(cat "$wiring")" = prior-token ] \
    || fail "failed reattach did not restore prior harness wiring"
  pass "fm-spawn reattach: a launch failure preserves the old binding, wiring, and retained work"
}

test_recovery_axes_cannot_be_overridden() {
  local dir id=rt-axes retained out rc before
  dir=$(new_case axes "$id")
  retained="$dir/pool/7/project"
  before="$dir/meta.before"
  cp "$dir/home/state/$id.meta" "$before"
  out=$(run_reattach_with_axes "$dir" "$id" "$retained"); rc=$?
  expect_code 1 "$rc" "reattach axis overrides must refuse"$'\n'"$out"
  assert_contains "$out" "--mode cannot override it" "reattach must adopt its recorded delivery axes"
  assert_unchanged_refusal "$dir" "$id" "$before"
  pass "fm-spawn reattach: recorded delivery axes cannot be overridden"
}

test_lifecycle_lock_refuses_without_changes() {
  local dir id=rt-control-lock retained out rc before wiring lock
  dir=$(new_case control-lock "$id")
  retained="$dir/pool/7/project"
  printf 'held-lock content\n' > "$retained/held-lock.txt"
  before="$dir/meta.before"
  cp "$dir/home/state/$id.meta" "$before"
  wiring="$dir/home/state/$id.claude-turnend-token"
  printf 'prior-token\n' > "$wiring"
  lock="$dir/home/state/.control-$id.lock"
  mkdir "$lock"
  printf '%s\n' "$$" > "$lock/pid"
  out=$(run_reattach "$dir" "$id" "$retained"); rc=$?
  expect_code 1 "$rc" "held lifecycle lock must refuse reattach"$'\n'"$out"
  assert_contains "$out" "another lifecycle action is already running" "contention refusal must name the lifecycle action"
  assert_unchanged_refusal "$dir" "$id" "$before"
  [ "$(cat "$wiring")" = prior-token ] || fail "control-lock refusal changed prior wiring"
  [ "$(cat "$retained/held-lock.txt")" = 'held-lock content' ] || fail "control-lock refusal changed retained work"
  pass "fm-spawn reattach: lifecycle contention refuses before changing state"
}

test_activation_stages_before_publication() {
  local dir id=rt-final-submit retained out rc before wiring
  dir=$(new_case final-submit "$id")
  retained="$dir/pool/7/project"
  printf 'must remain exact\n' > "$retained/final-submit.txt"
  before="$dir/meta.before"
  cp "$dir/home/state/$id.meta" "$before"
  wiring="$dir/home/state/$id.claude-turnend-token"
  printf 'prior-token\n' > "$wiring"
  out=$(FM_FAKE_REQUIRE_COMMIT=1 run_reattach "$dir" "$id" "$retained"); rc=$?
  expect_code 0 "$rc" "metadata-gated activation must publish successfully"$'\n'"$out"
  assert_grep "worktree=$retained" "$dir/home/state/$id.meta" "activation gate must publish the retained binding"
  [ "$(cat "$retained/final-submit.txt")" = 'must remain exact' ] || fail "metadata-gated activation changed retained content"
  [ ! -e "$retained/agent-ran-before-commit.txt" ] || fail "agent activated before metadata commit"
  pass "fm-spawn reattach: activation is staged behind the metadata commit"
}

test_status_does_not_reacquire_held_treehouse_lock() {
  local dir id=rt-owner-lock retained out rc
  dir=$(new_case owner-lock "$id")
  retained="$dir/pool/7/project"
  out=$(FM_FAKE_REFUSE_LOCKED_STATUS=1 run_reattach "$dir" "$id" "$retained"); rc=$?
  expect_code 0 "$rc" "reattach must not recursively lock Treehouse through status"$'\n'"$out"
  assert_grep "worktree=$retained" "$dir/home/state/$id.meta" \
    "nonrecursive ownership proof must publish the retained binding"
  pass "fm-spawn reattach: the locked owner proof does not recursively call Treehouse status"
}

test_process_arriving_before_lock_refuses() {
  local dir id=rt-process-race retained out rc before process_pid
  dir=$(new_case process-race "$id")
  retained="$dir/pool/7/project"
  before="$dir/meta.before"
  cp "$dir/home/state/$id.meta" "$before"
  (cd "$retained" && /bin/sleep 30) &
  process_pid=$!
  out=$(run_reattach "$dir" "$id" "$retained"); rc=$?
  kill "$process_pid" 2>/dev/null || true
  wait "$process_pid" 2>/dev/null || true
  expect_code 1 "$rc" "a process present at locked recheck must refuse"$'\n'"$out"
  assert_contains "$out" "gained a live process" \
    "locked process refusal must name the ownership race"
  assert_unchanged_refusal "$dir" "$id" "$before"
  pass "fm-spawn reattach: the locked recheck catches a process ownership race"
}

test_wrong_branch_refuses
test_live_agent_refuses
test_task_identity_mismatch_refuses
test_missing_copy_refuses
test_uncommitted_content_survives_success
test_launch_failure_rolls_back_the_binding
test_recovery_axes_cannot_be_overridden
test_lifecycle_lock_refuses_without_changes
test_activation_stages_before_publication
test_status_does_not_reacquire_held_treehouse_lock
test_process_arriving_before_lock_refuses

echo "# all fm-spawn-reattach tests passed"
