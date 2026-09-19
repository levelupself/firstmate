#!/usr/bin/env bash
# The pool's own binding for a task's copy is a durable per-task lease.
#
# `treehouse get` used to remember an interactive acquisition only by the
# acquiring shell's pid, so a finished worker's copy read as available again
# between its exit and cleanup, and the pool handed it out from under a record
# that still bound it. bin/fm-spawn.sh now acquires every pooled copy with
# `treehouse get --lease --lease-holder <task-id>`, records the lease in
# state/<id>.meta, and only bin/fm-teardown.sh's successful return releases it.
# These tests drive the real spawn and teardown paths against the shared fake
# pool in tests/pool-helpers.sh (which models the lease exactly as treehouse
# 2.1.0 does) and pin:
#   1. A spawned task's copy is leased under its task id in the pool's own
#      inventory, its record carries that lease, and once the worker exits the
#      pool still refuses to hand the copy to anyone else.
#   2. Two concurrent spawns receive distinct copies under distinct leases.
#   3. A spawn that fails after leasing returns its lease, so a refused launch
#      never leaks a pool slot.
#   4. Early cleanup releases the lease, a reacquire takes a new one and records
#      it, and the post-merge cleanup returns the new copy under the new lease
#      while the old copy, now someone else's, is never touched.
#   5. --relaunch and --reattach-worktree carry the task's own lease; a
#      retained copy leased to another holder is still refused.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/pool-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/pool-helpers.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-pool-lease)
TASK_TMPS=()

lease_cleanup() {
  local d
  for d in "${TASK_TMPS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  fm_test_cleanup
}
trap lease_cleanup EXIT

# The teardown steps that reach outside the pool: no PR, no active pipeline
# run, so a forced cleanup exercises only the copy return.
write_teardown_stubs() {  # <fakebin>
  local fb=$1
  cat > "$fb/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []"; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2; exit 1 ;;
esac
exit 0
SH
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
echo "error: pull request not found" >&2
exit 1
SH
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/gh-axi" "$fb/gh" "$fb/no-mistakes"
}

# new_case <name> -> echoes the case dir. A project with an origin and a pool
# of two free detached copies, 1 and 2, both available and unleased.
new_case() {  # <name>
  local name=$1 dir home proj one two
  dir="$TMP_ROOT/$name-$RANDOM"
  home="$dir/home"
  proj="$dir/proj"
  one="$dir/pool/1/proj"
  two="$dir/pool/2/proj"
  mkdir -p "$home/state" "$home/data" "$home/config" "$dir/fake" "$dir/fakebin"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  : > "$dir/fake/tmux.log"
  : > "$dir/fake/treehouse.log"
  : > "$dir/fake/windows"
  fm_fake_pool_write_treehouse "$dir/fakebin"
  fm_fake_pool_write_tmux "$dir/fakebin"
  write_teardown_stubs "$dir/fakebin"
  printf 'codex\n' > "$home/config/crew-harness"
  touch "$home/state/.last-watcher-beat"

  git init --quiet -b main "$proj"
  printf 'base\n' > "$proj/README.md"
  git -C "$proj" add README.md
  git -C "$proj" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$proj" "$dir/origin.git"
  git -C "$proj" remote add origin "file://$dir/origin.git"
  git -C "$proj" fetch --quiet origin
  git -C "$proj" worktree add --quiet --detach "$one"
  git -C "$proj" worktree add --quiet --detach "$two"
  fm_fake_pool_inventory "$(fm_fake_pool_entry 1 "$one" available)" "$(fm_fake_pool_entry 2 "$two" available)" \
    > "$dir/fake/status.json"
  printf '%s\n' "$dir"
}

prepare_task() {  # <case-dir> <id>
  local dir=$1 id=$2
  mkdir -p "$dir/home/data/$id"
  printf '# brief for %s\n\nDelivery contract: mode=no-mistakes\n' "$id" > "$dir/home/data/$id/brief.md"
  fm_test_backlog_ensure_queue "$dir/home" "$id"
  TASK_TMPS+=("/tmp/fm-$id")
}

# run_spawn <case-dir> <fake-dir> <args...>: the stubbed tmux backend is
# selected explicitly so runtime auto-detection cannot reach a real terminal.
run_spawn() {  # <case-dir> <fake-dir> <args...>
  local dir=$1 fake=$2; shift 2
  env -u HERDR_ENV -u TMUX PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$fake" \
    FM_FAKE_POOL_STATE="$dir/fake/status.json" \
    FM_BACKEND=tmux FM_SPAWN_NO_GUARD=1 FM_SPAWN_CWD_PROOF_POLLS=1 \
    "$SPAWN" "$@" 2>&1
}

run_teardown() {  # <case-dir> <args...>
  local dir=$1; shift
  env -u HERDR_ENV -u TMUX PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_FAKE_POOL_STATE="$dir/fake/status.json" \
    "$TEARDOWN" "$@" 2>&1
}

meta_value() {  # <meta> <key>
  sed -n "s/^$2=//p" "$1" | head -n 1
}

# assert_leased_to <case-dir> <id>: the copy the task's record names is leased
# to that task in the pool's own inventory, under the lease the record carries.
assert_leased_to() {  # <case-dir> <id>
  local dir=$1 id=$2 meta wt lease pool_lease holder status
  meta="$dir/home/state/$id.meta"
  wt=$(meta_value "$meta" worktree)
  [ -n "$wt" ] || fail "$id: the record names no copy"
  lease=$(meta_value "$meta" pool_lease_id)
  [ -n "$lease" ] || fail "$id: the record carries no pool lease for '$wt'"
  status=$(fm_fake_pool_field "$dir/fake/status.json" "$wt" status)
  holder=$(fm_fake_pool_field "$dir/fake/status.json" "$wt" lease_holder)
  pool_lease=$(fm_fake_pool_field "$dir/fake/status.json" "$wt" lease_id)
  [ "$status" = leased ] || fail "$id: the pool reports '$wt' as '$status', not leased"
  [ "$holder" = "$id" ] || fail "$id: the pool leases '$wt' to '$holder', not to the task"
  [ "$pool_lease" = "$lease" ] || fail "$id: the record's lease '$lease' is not the pool's lease '$pool_lease' for '$wt'"
}

test_finished_workers_copy_stays_leased_until_cleanup() {
  local dir id=lease-a out rc wt outsider
  dir=$(new_case finished)
  prepare_task "$dir" "$id"
  out=$(run_spawn "$dir" "$dir/fake" "$id" "$dir/proj" --mode no-mistakes --yolo off); rc=$?
  expect_code 0 "$rc" "the spawn must succeed"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_leased_to "$dir" "$id"
  wt=$(meta_value "$dir/home/state/$id.meta" worktree)
  assert_grep "get --lease --lease-holder $id" "$dir/fake/treehouse.log" \
    "the copy was not acquired through a lease held under the task id"
  [ "$(cd "$wt" && pwd -P)" = "$(cd "$(cat "$dir/fake/cwd")" && pwd -P)" ] \
    || fail "the pane is in '$(cat "$dir/fake/cwd")', not the leased copy '$wt'"
  # The worker finished and its pane exited: the pool forgets every process.
  fm_fake_pool_forget_processes "$dir/fake/status.json"
  assert_leased_to "$dir" "$id"
  # Anyone acquiring from the pool now - another home, a human, a raced spawn -
  # must be handed a different copy.
  outsider=$(cd "$dir/proj" && FM_FAKE_DIR="$dir/fake" FM_FAKE_POOL_STATE="$dir/fake/status.json" \
    PATH="$dir/fakebin:$PATH" treehouse get --lease --lease-holder outsider 2>/dev/null) \
    || fail "the pool had no other copy to hand out"
  [ "$(cd "$outsider" && pwd -P)" != "$(cd "$wt" && pwd -P)" ] \
    || fail "the pool handed task $id's copy '$wt' to another acquirer after the worker exited"
  pass "fm-spawn: a task's copy stays leased under its id after the worker exits, so the pool never re-hands it"
}

spawn_until_admitted() {  # <case-dir> <fake-dir> <id>
  local dir=$1 fake=$2 id=$3 out rc i=0
  while :; do
    out=$(run_spawn "$dir" "$fake" "$id" "$dir/proj" --mode no-mistakes --yolo off); rc=$?
    case "$out" in
      *"task set is locked by another operation"*)
        i=$((i + 1))
        [ "$i" -lt 100 ] || { printf '%s\n' "$out"; return "$rc"; }
        sleep 0.1
        continue
        ;;
    esac
    printf '%s\n' "$out"
    return "$rc"
  done
}

test_concurrent_spawns_receive_distinct_leased_copies() {
  local dir b=lease-b c=lease-c pid_b pid_c rc_b rc_c wt_b wt_c
  dir=$(new_case concurrent)
  prepare_task "$dir" "$b"
  prepare_task "$dir" "$c"
  mkdir -p "$dir/fake-b" "$dir/fake-c"
  for f in "$dir/fake-b" "$dir/fake-c"; do
    : > "$f/literal"; : > "$f/keys"; : > "$f/tmux.log"; : > "$f/treehouse.log"; : > "$f/windows"
  done
  # The home serializes its own fresh spawns through the task-set lock and
  # refuses rather than waits, so each racer retries that one refusal exactly
  # as firstmate would retry a queued task; everything else runs concurrently.
  spawn_until_admitted "$dir" "$dir/fake-b" "$b" > "$dir/out-b" &
  pid_b=$!
  spawn_until_admitted "$dir" "$dir/fake-c" "$c" > "$dir/out-c" &
  pid_c=$!
  wait "$pid_b"; rc_b=$?
  wait "$pid_c"; rc_c=$?
  expect_code 0 "$rc_b" "spawn $b must succeed"$'\n'"$(cat "$dir/out-b")"
  expect_code 0 "$rc_c" "spawn $c must succeed"$'\n'"$(cat "$dir/out-c")"
  assert_leased_to "$dir" "$b"
  assert_leased_to "$dir" "$c"
  wt_b=$(meta_value "$dir/home/state/$b.meta" worktree)
  wt_c=$(meta_value "$dir/home/state/$c.meta" worktree)
  [ "$(cd "$wt_b" && pwd -P)" != "$(cd "$wt_c" && pwd -P)" ] \
    || fail "two concurrent spawns received the same copy '$wt_b'"
  [ "$(meta_value "$dir/home/state/$b.meta" pool_lease_id)" != "$(meta_value "$dir/home/state/$c.meta" pool_lease_id)" ] \
    || fail "two concurrent spawns recorded the same lease"
  pass "fm-spawn: two concurrent spawns receive distinct copies under distinct leases"
}

test_failed_spawn_returns_its_lease() {
  local dir id=lease-d out rc lease
  dir=$(new_case abandoned)
  prepare_task "$dir" "$id"
  out=$(FM_FAKE_LAUNCH_FAIL=1 FM_FAKE_POOL_ENTER_STALL=1 run_spawn "$dir" "$dir/fake" "$id" "$dir/proj" --mode no-mistakes --yolo off); rc=$?
  [ "$rc" -ne 0 ] || fail "a spawn whose pane never enters its copy must fail"$'\n'"$out"
  assert_grep "get --lease --lease-holder $id" "$dir/fake/treehouse.log" "the spawn never leased a copy"
  lease=$(sed -n 's/^return --force --if-lease-id \([0-9a-f]*\) .*/\1/p' "$dir/fake/treehouse.log" | head -n 1)
  [ -n "$lease" ] || fail "the failed spawn did not return its lease under the lease id it held: $(cat "$dir/fake/treehouse.log")"
  ! grep -q '"status":"leased"' "$dir/fake/status.json" \
    || fail "a copy stayed leased after the failed spawn: $(cat "$dir/fake/status.json")"
  assert_absent "$dir/home/state/$id.meta" "a failed spawn must publish no record"
  pass "fm-spawn: a spawn that fails after leasing returns its lease"
}

# Early cleanup, exactly as bin/fm-teardown.sh leaves a task whose PR is still
# open: the copy returned under the task's lease, the record kept and stamped
# teardown_at=. Modelled directly against the fake pool so the reacquire that
# follows runs against the real state such a cleanup produces.
early_cleanup() {  # <case-dir> <id>
  local dir=$1 id=$2 meta wt lease
  meta="$dir/home/state/$id.meta"
  wt=$(meta_value "$meta" worktree)
  lease=$(meta_value "$meta" pool_lease_id)
  (cd "$dir/proj" && FM_FAKE_DIR="$dir/fake" FM_FAKE_POOL_STATE="$dir/fake/status.json" PATH="$dir/fakebin:$PATH" \
    treehouse return --force --if-lease-id "$lease" "$wt" >/dev/null) || fail "early cleanup could not return '$wt' under lease '$lease'"
  printf 'teardown_at=2026-09-19T01:00:00Z\n' >> "$meta"
}

test_early_cleanup_reacquire_and_post_merge_cleanup_keep_the_lease_consistent() {
  local dir id=lease-e out rc old_wt old_lease new_wt new_lease outsider
  dir=$(new_case lifecycle)
  prepare_task "$dir" "$id"
  out=$(run_spawn "$dir" "$dir/fake" "$id" "$dir/proj" --mode no-mistakes --yolo off); rc=$?
  expect_code 0 "$rc" "the spawn must succeed"$'\n'"$out"
  assert_leased_to "$dir" "$id"
  old_wt=$(meta_value "$dir/home/state/$id.meta" worktree)
  old_lease=$(meta_value "$dir/home/state/$id.meta" pool_lease_id)
  # The worker committed its branch and pushed; the branch survives in the
  # shared repository once its copy is returned.
  git -C "$old_wt" checkout -q -b "fm/$id"
  printf 'work\n' > "$old_wt/work.txt"
  git -C "$old_wt" add work.txt
  git -C "$old_wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'task work'
  git -C "$old_wt" checkout -q --detach
  early_cleanup "$dir" "$id"
  [ "$(fm_fake_pool_field "$dir/fake/status.json" "$old_wt" status)" = available ] \
    || fail "early cleanup did not release the lease on '$old_wt'"
  # The released copy goes to someone else, as the pool is free to do.
  outsider=$(cd "$dir/proj" && FM_FAKE_DIR="$dir/fake" FM_FAKE_POOL_STATE="$dir/fake/status.json" \
    PATH="$dir/fakebin:$PATH" treehouse get --lease --lease-holder outsider 2>/dev/null) || fail "no copy for the outsider"
  [ "$(cd "$outsider" && pwd -P)" = "$(cd "$old_wt" && pwd -P)" ] || fail "the fake pool did not re-lease the returned copy first"
  : > "$dir/fake/keys"
  out=$(run_spawn "$dir" "$dir/fake" "$id" --reacquire-worktree); rc=$?
  expect_code 0 "$rc" "the reacquire must succeed"$'\n'"$out"
  assert_leased_to "$dir" "$id"
  new_wt=$(meta_value "$dir/home/state/$id.meta" worktree)
  new_lease=$(meta_value "$dir/home/state/$id.meta" pool_lease_id)
  [ "$(cd "$new_wt" && pwd -P)" != "$(cd "$old_wt" && pwd -P)" ] || fail "the reacquire took the copy the outsider now leases"
  [ "$new_lease" != "$old_lease" ] || fail "the reacquire recorded the released lease instead of its new one"
  [ "$(git -C "$new_wt" symbolic-ref --quiet --short HEAD)" = "fm/$id" ] || fail "the reacquired copy is not on fm/$id"
  [ "$(fm_fake_pool_field "$dir/fake/status.json" "$old_wt" lease_holder)" = outsider ] \
    || fail "the reacquire disturbed the outsider's lease on the old copy"
  : > "$dir/fake/treehouse.log"
  out=$(run_teardown "$dir" "$id" --force); rc=$?
  expect_code 0 "$rc" "the post-merge cleanup must succeed"$'\n'"$out"
  assert_grep "return --force --if-lease-id $new_lease $new_wt" "$dir/fake/treehouse.log" \
    "the post-merge cleanup did not return the new copy under the new lease: $(cat "$dir/fake/treehouse.log")"
  assert_no_grep "$old_wt" "$dir/fake/treehouse.log" "the post-merge cleanup touched the old copy"
  [ "$(fm_fake_pool_field "$dir/fake/status.json" "$new_wt" status)" = available ] \
    || fail "the post-merge cleanup did not release the new lease"
  [ "$(fm_fake_pool_field "$dir/fake/status.json" "$old_wt" lease_holder)" = outsider ] \
    || fail "the post-merge cleanup disturbed the outsider's lease on the old copy"
  assert_absent "$dir/home/state/$id.meta" "the post-merge cleanup did not retire the record"
  [ -z "$(FM_HOME="$dir/home" "$ROOT/bin/fm-worktree-allocation.sh" holder "$(cd "$dir/proj" && pwd -P)" "$new_wt")" ] \
    || fail "the allocation ledger still names a holder for the returned copy"
  pass "fm-spawn/fm-teardown: early cleanup, reacquire, and post-merge cleanup keep the lease consistent"
}

test_relaunch_and_reattach_carry_the_task_lease() {
  local dir id=lease-f out rc wt lease meta retained
  dir=$(new_case carry)
  prepare_task "$dir" "$id"
  out=$(run_spawn "$dir" "$dir/fake" "$id" "$dir/proj" --mode no-mistakes --yolo off); rc=$?
  expect_code 0 "$rc" "the spawn must succeed"$'\n'"$out"
  meta="$dir/home/state/$id.meta"
  wt=$(meta_value "$meta" worktree)
  lease=$(meta_value "$meta" pool_lease_id)
  git -C "$wt" checkout -q -b "fm/$id"
  # --relaunch adopts the recorded endpoint and copy: the lease must survive.
  out=$(run_spawn "$dir" "$dir/fake" "$id" --relaunch); rc=$?
  expect_code 0 "$rc" "the relaunch must succeed"$'\n'"$out"
  [ "$(meta_value "$meta" pool_lease_id)" = "$lease" ] || fail "the relaunch dropped or changed the recorded lease"
  assert_leased_to "$dir" "$id"
  # --reattach-worktree: the endpoint is gone and the record names another
  # copy, while the retained copy sits in the pool leased to this task.
  retained=$wt
  : > "$dir/fake/windows"
  sed -i "s|^worktree=.*|worktree=$dir/pool/2/proj|" "$meta"
  out=$(run_spawn "$dir" "$dir/fake" "$id" --reattach-worktree "$retained"); rc=$?
  expect_code 0 "$rc" "the reattach to the task's own leased copy must succeed"$'\n'"$out"
  [ "$(meta_value "$meta" worktree)" = "$retained" ] || fail "the reattach did not rebind to the retained copy"
  [ "$(meta_value "$meta" pool_lease_id)" = "$lease" ] || fail "the reattach did not carry the retained copy's lease"
  assert_leased_to "$dir" "$id"
  # A retained copy leased to someone else is not this task's to take.
  : > "$dir/fake/windows"
  sed -i "s|^worktree=.*|worktree=$dir/pool/2/proj|" "$meta"
  node -e '
const fs = require("fs")
const [file, path] = process.argv.slice(1)
const entries = JSON.parse(fs.readFileSync(file, "utf8"))
const real = p => { try { return fs.realpathSync(p) } catch { return p } }
const e = entries.find(x => real(x.path) === real(path))
e.lease_holder = "someone-else"
fs.writeFileSync(file, JSON.stringify(entries) + "\n")
' "$dir/fake/status.json" "$retained"
  out=$(run_spawn "$dir" "$dir/fake" "$id" --reattach-worktree "$retained"); rc=$?
  [ "$rc" -ne 0 ] || fail "a retained copy leased to another holder must be refused"$'\n'"$out"
  assert_contains "$out" "leased to another holder" "the refusal must name the foreign lease"
  pass "fm-spawn: relaunch and reattach carry the task's own lease and refuse another holder's"
}

test_finished_workers_copy_stays_leased_until_cleanup
test_concurrent_spawns_receive_distinct_leased_copies
test_failed_spawn_returns_its_lease
test_early_cleanup_reacquire_and_post_merge_cleanup_keep_the_lease_consistent
test_relaunch_and_reattach_carry_the_task_lease

echo "# all fm-pool-lease tests passed"
