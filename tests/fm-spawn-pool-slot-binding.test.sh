#!/usr/bin/env bash
# fm-spawn.sh must never accept a pooled copy that another task record in this
# home still binds.
#
# `treehouse get` only remembers an interactive acquisition by the acquiring
# shell's pid, so after a host reboot a parked task's clean, committed copy reads
# as available again and the pool hands it out - checked out at origin's default
# branch - while state/<id>.meta still names it. These tests drive the real spawn
# path against a fake terminal whose fake pool behaves exactly that way, and pin:
#   1. A copy bound by another live record is refused; the spawn steers into an
#      unbound free copy instead and the bound copy is untouched.
#   2. With no unbound free copy, the spawn stops and names the owning task.
#   3. A copy bound only by a torn-down record (teardown_at= stamped, or the
#      record removed) is accepted exactly as before.
#   4. A free copy whose ignored footprint exceeds FM_POOL_COPY_BUDGET_GB is
#      pruned before it is entered; one still over budget after the prune is
#      never handed to the new worker, and the spawn steers to a clean copy or
#      refuses naming the bloated ones.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-pool-slot-binding)
TASK_TMPS=()

binding_cleanup() {
  local d
  for d in "${TASK_TMPS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  fm_test_cleanup
}
trap binding_cleanup EXIT

# A tmux stub whose pane is a fake pool client: `treehouse get` moves the pane
# into the copy the fake pool would hand out AND refreshes that copy to
# origin's default branch, exactly as the real pool does on acquisition;
# `treehouse enter <name>` moves the pane into that named copy and changes
# nothing. `pwd -P > file` answers from the pane's current directory.
make_tmux_stub() {  # <case-dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
printf '%s\n' "$*" >> "$D/tmux.log"
pane_cwd() { [ ! -f "$D/cwd" ] || cat "$D/cwd"; }
case "${1:-}" in
  has-session|new-session|set-window-option) exit 0 ;;
  list-windows)
    [ ! -f "$D/windows" ] || cat "$D/windows"
    exit 0
    ;;
  new-window)
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
        *pane_current_path*) pane_cwd; printf '\n'; exit 0 ;;
        *pane_current_command*) printf 'bash\n'; exit 0 ;;
        *pane_pid*) printf '2147483646\n'; exit 0 ;;
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
    text=${1:-}
    if [ "$literal" = 1 ]; then
      printf '%s\n' "$text" >> "$D/literal"
      exit 0
    fi
    printf '%s\n' "$text" >> "$D/keys"
    case "$text" in
      'treehouse get')
        handout=$(cat "$D/pool-get")
        printf '%s' "$handout" > "$D/cwd"
        if git -C "$handout" remote get-url origin >/dev/null 2>&1; then
          git -C "$handout" checkout -q --detach refs/remotes/origin/main
        else
          git -C "$handout" checkout -q --detach main
        fi
        ;;
      'treehouse enter '*)
        name=${text#treehouse enter }
        awk -F '\t' -v n="$name" '$1 == n { print $2 }' "$D/pool-slots" | tr -d '\n' > "$D/cwd"
        ;;
      'pwd -P > '*)
        ( cd "$(pane_cwd)" && eval "$text" ) || true
        ;;
    esac
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

# The treehouse binary fm-spawn calls directly answers only `status --json`,
# from the inventory the case owns.
make_treehouse_stub() {  # <case-dir>
  cat > "$1/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
printf '%s\n' "$*" >> "$D/treehouse.log"
[ "${1:-}" = status ] || exit 1
[ -f "$D/status.json" ] || exit 1
cat "$D/status.json"
exit 0
SH
  chmod +x "$1/fakebin/treehouse"
}

# pool_entry <name> <path> <status> [processes-json]
pool_entry() {
  printf '{"name":"%s","path":"%s","status":"%s","lease_id":"","lease_holder":"","leased_at":null,"processes":%s}' \
    "$1" "$2" "$3" "${4:-[]}"
}

# write_meta_for <home> <id> <worktree> <project> [extra-line...]
write_meta_for() {
  local home=$1 id=$2 wt=$3 proj=$4
  shift 4
  {
    echo "window=firstmate:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=codex"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-$id"
    echo "model=default"
    echo "effort=default"
    echo "spawned_at=2026-09-10T00:00:00Z"
    printf '%s\n' "$@"
  } > "$home/state/$id.meta"
}

# new_case <name> <id> -> echoes the case dir.
#
# The project has an origin, pool copy 7 sits clean on fm/<other>'s branch with
# committed work exactly as a parked task leaves it, and pool copy 3 is a free
# detached copy. The fake pool reports both as available and would hand out 7.
new_case() {  # <name> <id> <other-id>
  local name=$1 id=$2 other=$3 dir home proj bound free
  dir="$TMP_ROOT/$name-$RANDOM"
  home="$dir/home"
  proj="$dir/proj"
  bound="$dir/pool/7/proj"
  free="$dir/pool/3/proj"
  mkdir -p "$home/state" "$home/data/$id" "$home/config" "$dir/fake"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  : > "$dir/fake/tmux.log"
  : > "$dir/fake/treehouse.log"
  : > "$dir/fake/windows"
  make_tmux_stub "$dir"
  make_treehouse_stub "$dir"
  printf 'codex\n' > "$home/config/crew-harness"
  touch "$home/state/.last-watcher-beat"

  git init --quiet -b main "$proj"
  printf 'base\n' > "$proj/README.md"
  # Ignored build output and scratch let the footprint gate cases below bloat
  # a copy with prunable (target/) and unprunable (scratch/) content.
  printf 'target/\nscratch/\n' > "$proj/.gitignore"
  printf '[package]\nname = "proj"\nversion = "0.1.0"\n' > "$proj/Cargo.toml"
  git -C "$proj" add README.md .gitignore Cargo.toml
  git -C "$proj" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$proj" "$dir/origin.git"
  git -C "$proj" remote add origin "file://$dir/origin.git"
  git -C "$proj" fetch --quiet origin
  git -C "$proj" worktree add --quiet -b "fm/$other" "$bound"
  git -C "$proj" worktree add --quiet --detach "$free"
  printf 'parked work\n' > "$bound/parked.txt"
  git -C "$bound" add parked.txt
  git -C "$bound" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'parked task work'

  printf '# brief for %s\n\nDelivery contract: mode=no-mistakes\n' "$id" > "$home/data/$id/brief.md"
  fm_test_backlog_ensure_queue "$home" "$id"
  write_meta_for "$home" "$other" "$bound" "$proj"
  printf '%s\n' "$bound" > "$dir/fake/pool-get"
  printf '7\t%s\n3\t%s\n' "$bound" "$free" > "$dir/fake/pool-slots"
  printf '[%s,%s]\n' "$(pool_entry 3 "$free" available)" "$(pool_entry 7 "$bound" available)" \
    > "$dir/fake/status.json"
  TASK_TMPS+=("/tmp/fm-$id")
  printf '%s\n' "$dir"
}

# The stubbed tmux backend is selected explicitly: runtime auto-detection
# would otherwise spawn into whatever real terminal runs this suite.
run_spawn() {  # <case-dir> <args...>
  local dir=$1; shift
  env -u HERDR_ENV -u TMUX PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_BACKEND=tmux FM_SPAWN_NO_GUARD=1 FM_SPAWN_CWD_PROOF_POLLS=1 \
    "$SPAWN" "$@" 2>&1
}

assert_bound_copy_untouched() {  # <bound> <other> <head-before>
  local bound=$1 other=$2 before=$3
  [ "$(git -C "$bound" symbolic-ref --quiet --short HEAD 2>/dev/null)" = "fm/$other" ] \
    || fail "the bound copy was moved off fm/$other: $(git -C "$bound" rev-parse --abbrev-ref HEAD 2>&1)"
  [ "$(git -C "$bound" rev-parse HEAD)" = "$before" ] \
    || fail "the bound copy's HEAD moved"
  [ "$(cat "$bound/parked.txt" 2>/dev/null)" = 'parked work' ] \
    || fail "the bound copy's committed content changed"
}

test_bound_by_live_record_steers_to_free_copy() {
  local dir id=psb-fresh-a other=psb-parked-a bound free before out rc meta
  dir=$(new_case live "$id" "$other")
  bound="$dir/pool/7/proj"
  free="$dir/pool/3/proj"
  before=$(git -C "$bound" rev-parse HEAD)
  cp "$dir/home/state/$other.meta" "$dir/other.meta.before"
  out=$(run_spawn "$dir" "$id" "$dir/proj" --mode no-mistakes --yolo off); rc=$?
  expect_code 0 "$rc" "a spawn offered a bound copy must take the free copy instead"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_no_grep 'treehouse get' "$dir/fake/keys" \
    "the pane must not run treehouse get while the pool would hand out a bound copy"
  assert_grep 'treehouse enter 3' "$dir/fake/keys" \
    "the pane did not enter the unbound free copy by name"
  meta="$dir/home/state/$id.meta"
  assert_grep "worktree=$free" "$meta" "the new task's record does not name the free copy"
  assert_no_grep "worktree=$bound" "$meta" "the new task's record names the copy $other still binds"
  assert_bound_copy_untouched "$bound" "$other" "$before"
  cmp -s "$dir/other.meta.before" "$dir/home/state/$other.meta" \
    || fail "the parked task's record changed"
  [ "$(git -C "$free" rev-parse HEAD)" = "$(git -C "$free" rev-parse origin/main)" ] \
    || fail "the free copy was not refreshed to origin/main before the branch"
  git -C "$free" symbolic-ref --quiet HEAD >/dev/null 2>&1 \
    && fail "the free copy was left on a branch instead of detached at the refreshed base"
  assert_contains "$out" "$other" "the steer notice must name the task whose copy was avoided"
  pass "fm-spawn: a copy bound by another live record is refused and an unbound free copy is entered instead"
}

test_bound_by_live_record_with_no_free_copy_refuses() {
  local dir id=psb-fresh-b other=psb-parked-b bound before out rc
  dir=$(new_case nofree "$id" "$other")
  bound="$dir/pool/7/proj"
  before=$(git -C "$bound" rev-parse HEAD)
  printf '[%s]\n' "$(pool_entry 7 "$bound" available)" > "$dir/fake/status.json"
  out=$(run_spawn "$dir" "$id" "$dir/proj" --mode no-mistakes --yolo off); rc=$?
  [ "$rc" -ne 0 ] || fail "a spawn with only a bound copy on offer must refuse"$'\n'"$out"
  assert_contains "$out" "$other" "the refusal must name the task that still binds the copy"
  assert_contains "$out" "$bound" "the refusal must name the bound copy"
  assert_no_grep 'treehouse get' "$dir/fake/keys" \
    "a refused spawn must never run treehouse get against a bound copy"
  assert_no_grep 'treehouse enter' "$dir/fake/keys" \
    "a refused spawn must not enter any copy"
  assert_bound_copy_untouched "$bound" "$other" "$before"
  assert_absent "$dir/home/state/$id.meta" "a refused spawn must publish no record"
  assert_no_grep '^new-window ' "$dir/fake/tmux.log" \
    "pool preflight refusal must happen before endpoint creation"
  [ ! -s "$dir/fake/windows" ] || fail "pool refusal left an endpoint behind"
  assert_absent "$dir/home/state/$id.meta" "a refused spawn must publish no record"
  printf '[%s,%s]\n' "$(pool_entry 3 "$dir/pool/3/proj" available)" \
    "$(pool_entry 7 "$bound" available)" > "$dir/fake/status.json"
  out=$(run_spawn "$dir" "$id" "$dir/proj" --mode no-mistakes --yolo off); rc=$?
  expect_code 0 "$rc" "the same task must retry after pool availability is restored"$'\n'"$out"
  assert_grep "worktree=$dir/pool/3/proj" "$dir/home/state/$id.meta" \
    "the retry must bind the restored free copy"
  assert_bound_copy_untouched "$bound" "$other" "$before"
  pass "fm-spawn: with no unbound free copy the spawn stops and names the owning task"
}

test_unreadable_inventory_with_bound_copies_refuses() {
  local dir id=psb-fresh-c other=psb-parked-c bound before out rc
  dir=$(new_case unreadable "$id" "$other")
  bound="$dir/pool/7/proj"
  before=$(git -C "$bound" rev-parse HEAD)
  rm -f "$dir/fake/status.json"
  out=$(run_spawn "$dir" "$id" "$dir/proj" --mode no-mistakes --yolo off); rc=$?
  [ "$rc" -ne 0 ] || fail "an unreadable pool inventory with bound copies must refuse"$'\n'"$out"
  assert_contains "$out" "$other" "the refusal must name the task whose copy could not be protected"
  assert_no_grep 'treehouse get' "$dir/fake/keys" \
    "a spawn that cannot read the inventory must not gamble on treehouse get"
  assert_bound_copy_untouched "$bound" "$other" "$before"
  assert_no_grep '^new-window ' "$dir/fake/tmux.log" \
    "pool preflight refusal must happen before endpoint creation"
  [ ! -s "$dir/fake/windows" ] || fail "pool refusal left an endpoint behind"
  assert_absent "$dir/home/state/$id.meta" "a refused spawn must publish no record"
  printf '[%s,%s]\n' "$(pool_entry 3 "$dir/pool/3/proj" available)" \
    "$(pool_entry 7 "$bound" available)" > "$dir/fake/status.json"
  out=$(run_spawn "$dir" "$id" "$dir/proj" --mode no-mistakes --yolo off); rc=$?
  expect_code 0 "$rc" "the same task must retry after pool availability is restored"$'\n'"$out"
  assert_grep "worktree=$dir/pool/3/proj" "$dir/home/state/$id.meta" \
    "the retry must bind the restored free copy"
  assert_bound_copy_untouched "$bound" "$other" "$before"
  pass "fm-spawn: an unreadable pool inventory refuses rather than guessing while a bound copy exists"
}

test_bound_only_by_torn_down_record_is_accepted() {
  local dir id=psb-fresh-d other=psb-torn-d bound out rc meta
  dir=$(new_case torndown "$id" "$other")
  bound="$dir/pool/7/proj"
  # Teardown stamps teardown_at= only after its landed-work test, and removes
  # the record afterwards; either form releases the binding.
  echo 'teardown_at=2026-09-11T00:00:00Z' >> "$dir/home/state/$other.meta"
  out=$(run_spawn "$dir" "$id" "$dir/proj" --mode no-mistakes --yolo off); rc=$?
  expect_code 0 "$rc" "a copy bound only by a torn-down record must be accepted"$'\n'"$out"
  assert_grep 'treehouse get' "$dir/fake/keys" "the pane should acquire through the pool as before"
  meta="$dir/home/state/$id.meta"
  assert_grep "worktree=$bound" "$meta" "the new task's record does not name the copy the pool handed out"
  [ "$(git -C "$bound" rev-parse HEAD)" = "$(git -C "$bound" rev-parse origin/main)" ] \
    || fail "the released copy was not refreshed to origin/main"
  pass "fm-spawn: a copy bound only by a torn-down record is accepted"

  id=psb-fresh-e
  other=psb-retired-e
  dir=$(new_case retired "$id" "$other")
  bound="$dir/pool/7/proj"
  rm -f "$dir/home/state/$other.meta"
  printf 'done: retired\n' > "$dir/home/state/$other.status"
  out=$(run_spawn "$dir" "$id" "$dir/proj" --mode no-mistakes --yolo off); rc=$?
  expect_code 0 "$rc" "a copy whose only record was removed must be accepted"$'\n'"$out"
  assert_grep "worktree=$bound" "$dir/home/state/$id.meta" \
    "the new task's record does not name the copy the pool handed out"
  pass "fm-spawn: a copy named only by a retired status log is accepted"
}

test_empty_inventory_with_bound_copies_acquires_fresh() {
  local dir id=psb-fresh-f other=psb-lost-f bound fresh out rc meta
  dir=$(new_case empty "$id" "$other")
  bound="$dir/pool/7/proj"
  fresh="$dir/pool/9/proj"
  # The pool directory was lost (a host reboot wiped it): the parked task's
  # record still names its copy, but the pool is empty and reads as such, so
  # `treehouse get` can only create a fresh copy - nothing bound can be
  # handed out. Reading a clean empty inventory as unreadable would deadlock
  # every spawn behind records whose copies no longer exist.
  git -C "$dir/proj" worktree remove --force "$bound"
  git -C "$dir/proj" worktree add --quiet --detach "$fresh"
  printf '%s\n' "$fresh" > "$dir/fake/pool-get"
  printf '[]\n' > "$dir/fake/status.json"
  out=$(run_spawn "$dir" "$id" "$dir/proj" --mode no-mistakes --yolo off); rc=$?
  expect_code 0 "$rc" "an empty pool inventory must not be mistaken for an unreadable one"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep 'treehouse get' "$dir/fake/keys" "an empty pool is acquired through the ordinary treehouse get"
  meta="$dir/home/state/$id.meta"
  assert_grep "worktree=$fresh" "$meta" "the new task's record does not name the fresh copy the pool created"
  assert_no_grep "worktree=$bound" "$meta" "the new task's record names the lost copy"
  pass "fm-spawn: an empty pool inventory with bound records acquires a fresh copy"
}

# --- footprint pre-condition ---------------------------------------------------

bloat() {  # <copy> <ignored-subdir> <bytes>
  mkdir -p "$1/$2"
  head -c "$3" /dev/zero | tr '\0' x > "$1/$2/blob"
}

release_binding() {  # <case-dir> <other-id>
  echo 'teardown_at=2026-09-11T00:00:00Z' >> "$1/home/state/$2.meta"
}

test_over_budget_free_copy_is_pruned_then_acquired() {
  local dir id=psb-fresh-g other=psb-torn-g handout out rc
  dir=$(new_case pruned "$id" "$other")
  handout="$dir/pool/7/proj"
  release_binding "$dir" "$other"
  bloat "$handout" target 65536
  out=$(FM_POOL_COPY_BUDGET_GB=0.00001 run_spawn "$dir" "$id" "$dir/proj" --mode no-mistakes --yolo off); rc=$?
  expect_code 0 "$rc" "a free copy that the return prune brings under budget must be acquired"$'\n'"$out"
  assert_absent "$handout/target" "the over-budget copy was not pruned before acquisition"
  assert_grep 'treehouse get' "$dir/fake/keys" "a pool whose free copies all fit the budget acquires through treehouse get"
  assert_grep "worktree=$handout" "$dir/home/state/$id.meta" "the new task's record does not name the pruned copy"
  pass "fm-spawn: an over-budget free copy is pruned and entered once it fits the budget"
}

test_unprunable_over_budget_copy_is_skipped_for_a_clean_one() {
  local dir id=psb-fresh-h other=psb-torn-h bloated free out rc
  dir=$(new_case unprunable "$id" "$other")
  bloated="$dir/pool/7/proj"
  free="$dir/pool/3/proj"
  release_binding "$dir" "$other"
  bloat "$bloated" scratch 65536
  out=$(FM_POOL_COPY_BUDGET_GB=0.00001 run_spawn "$dir" "$id" "$dir/proj" --mode no-mistakes --yolo off); rc=$?
  expect_code 0 "$rc" "a spawn with one bloated and one clean free copy must take the clean one"$'\n'"$out"
  assert_no_grep 'treehouse get' "$dir/fake/keys" \
    "the pane must not run treehouse get while the pool could hand out a bloated copy"
  assert_grep 'treehouse enter 3' "$dir/fake/keys" "the pane did not enter the clean free copy by name"
  assert_grep "worktree=$free" "$dir/home/state/$id.meta" "the new task's record does not name the clean copy"
  assert_contains "$out" "$bloated" "the notice must name the bloated copy it refused"
  assert_present "$bloated/scratch/blob" "spawn removed scratch the return prune does not own"
  pass "fm-spawn: a copy still over budget after the prune is skipped for a clean free copy"
}

test_all_free_copies_over_budget_refuses_spawn() {
  local dir id=psb-fresh-i other=psb-torn-i seven three out rc
  dir=$(new_case allbloated "$id" "$other")
  seven="$dir/pool/7/proj"
  three="$dir/pool/3/proj"
  release_binding "$dir" "$other"
  bloat "$seven" scratch 65536
  bloat "$three" scratch 65536
  out=$(FM_POOL_COPY_BUDGET_GB=0.00001 run_spawn "$dir" "$id" "$dir/proj" --mode no-mistakes --yolo off); rc=$?
  [ "$rc" -ne 0 ] || fail "a pool with only bloated free copies must refuse the spawn"$'\n'"$out"
  assert_contains "$out" "$seven" "the refusal must name the first bloated copy"
  assert_contains "$out" "$three" "the refusal must name the second bloated copy"
  assert_no_grep 'treehouse get' "$dir/fake/keys" "a refused spawn must never run treehouse get"
  assert_no_grep 'treehouse enter' "$dir/fake/keys" "a refused spawn must not enter any copy"
  assert_no_grep '^new-window ' "$dir/fake/tmux.log" "footprint refusal must happen before endpoint creation"
  assert_absent "$dir/home/state/$id.meta" "a refused spawn must publish no record"
  pass "fm-spawn: when every free copy stays over budget the spawn refuses naming them"
}

test_bound_copy_with_over_budget_free_copy_refuses() {
  local dir id=psb-fresh-j other=psb-parked-j bound free before out rc
  dir=$(new_case boundbloated "$id" "$other")
  bound="$dir/pool/7/proj"
  free="$dir/pool/3/proj"
  before=$(git -C "$bound" rev-parse HEAD)
  bloat "$free" scratch 65536
  out=$(FM_POOL_COPY_BUDGET_GB=0.00001 run_spawn "$dir" "$id" "$dir/proj" --mode no-mistakes --yolo off); rc=$?
  [ "$rc" -ne 0 ] || fail "a bound copy plus a bloated free copy must refuse"$'\n'"$out"
  assert_contains "$out" "$other" "the refusal must name the task that still binds the copy"
  assert_contains "$out" "$free" "the refusal must name the bloated free copy"
  assert_no_grep 'treehouse enter' "$dir/fake/keys" "a refused spawn must not enter the bloated copy"
  assert_bound_copy_untouched "$bound" "$other" "$before"
  assert_absent "$dir/home/state/$id.meta" "a refused spawn must publish no record"
  pass "fm-spawn: a bloated free copy never substitutes for a bound one"
}

test_failed_listing_refuses_spawn() {
  local dir id=psb-failed-listing other=psb-torn-listing copy index out rc
  dir=$(new_case failedlisting "$id" "$other")
  release_binding "$dir" "$other"
  for copy in "$dir/pool/7/proj" "$dir/pool/3/proj"; do
    index=$(git -C "$copy" rev-parse --git-path index)
    printf 'broken index\n' > "$index"
  done
  out=$(FM_POOL_COPY_BUDGET_GB=0.00001 run_spawn "$dir" "$id" "$dir/proj" --mode no-mistakes --yolo off); rc=$?
  [ "$rc" -ne 0 ] || fail "spawn accepted failed ignored listings: $out"
  assert_contains "$out" "$dir/pool/7/proj" 'refusal omitted the unmeasurable copy'
  assert_no_grep '^new-window ' "$dir/fake/tmux.log" 'failed listing allowed endpoint creation'
  assert_absent "$dir/home/state/$id.meta" 'failed listing published a task record'
  pass 'spawn refuses free copies with failed ignored listings'
}

test_failed_listing_refuses_spawn

test_bound_by_live_record_steers_to_free_copy
test_bound_by_live_record_with_no_free_copy_refuses
test_unreadable_inventory_with_bound_copies_refuses
test_bound_only_by_torn_down_record_is_accepted
test_empty_inventory_with_bound_copies_acquires_fresh
test_over_budget_free_copy_is_pruned_then_acquired
test_unprunable_over_budget_copy_is_skipped_for_a_clean_one
test_all_free_copies_over_budget_refuses_spawn
test_bound_copy_with_over_budget_free_copy_refuses

echo "# all fm-spawn-pool-slot-binding tests passed"
