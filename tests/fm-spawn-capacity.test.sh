#!/usr/bin/env bash
# fm-spawn.sh must refuse to start another agent on a host that cannot carry it,
# and must refuse before anything durable exists so the task stays queued.
#
# On 2026-09-07 an unbounded fleet plus concurrent CI builds exhausted a fixed
# 48 GB host twice and the kernel OOM killer took every agent window at once.
# These tests drive the real spawn path against a fake terminal and a fake
# Linux /proc, and pin the dispatch-time ceiling:
#   1. FM_SPAWN_MAX_ACTIVE counts the home's ACTIVE direct reports - records
#      with a live agent whose last status event is not done or failed - so a
#      finished worker waiting on its merge never blocks a new one, while a
#      live working one does.
#   2. FM_SPAWN_MAX_LOAD refuses while the 1-minute load average exceeds it.
#   3. FM_SPAWN_MIN_MEM_GB refuses while MemAvailable is below it.
#   4. Every refusal names the measured value and the threshold, creates no
#      endpoint and no record, and the identical command succeeds once the
#      host has room again, so a refused spawn never loses the task.
#   5. An invalid threshold stops the spawn rather than defaulting; a host with
#      no Linux-compatible /proc is still bounded by the active-worker cap.
#   6. A recovery relaunch passes the same guard before it touches the recorded
#      endpoint, and the relaunched task's own record is not counted against it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-capacity)
TASK_TMPS=()

capacity_cleanup() {
  local d
  for d in "${TASK_TMPS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  fm_test_cleanup
}
trap capacity_cleanup EXIT

# A tmux stub whose pane is a fake pool client. `list-windows` answers from
# the case's windows file, so a record whose window is listed there exists and
# one whose window is absent is authoritatively missing; `pane_current_command`
# answers from the case's pane-cmd.<window> file when one exists, else from its
# pane-cmd file (default bash), so a listed window reads as a live agent when
# the file that covers it names one and as agent-free when it names a shell.
# `treehouse get` moves the pane into the copy the fake pool hands out, exactly
# as the real pool does.
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
    target=
    prev=
    for a in "$@"; do
      [ "$prev" != -t ] || target=$a
      prev=$a
    done
    window=${target#*:}
    for a in "$@"; do
      case "$a" in
        *pane_current_path*) pane_cwd; printf '\n'; exit 0 ;;
        *pane_current_command*)
          if [ -n "$window" ] && [ -f "$D/pane-cmd.$window" ]; then cat "$D/pane-cmd.$window"
          elif [ -f "$D/pane-cmd" ]; then cat "$D/pane-cmd"
          else printf 'bash\n'; fi
          exit 0
          ;;
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
        git -C "$handout" checkout -q --detach refs/remotes/origin/main
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
  cat > "$fb/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
printf '%s\n' "$*" >> "$D/treehouse.log"
[ "${1:-}" = status ] || exit 1
cat "$D/status.json"
exit 0
SH
  chmod +x "$fb/treehouse"
}

# write_proc <case-dir> <load1> <mem-available-kb>: the fake kernel readings.
write_proc() {
  mkdir -p "$1/proc"
  printf '%s 0.50 0.25 1/100 4242\n' "$2" > "$1/proc/loadavg"
  printf 'MemTotal:       49329784 kB\nMemFree:         1000000 kB\nMemAvailable:   %s kB\n' "$3" > "$1/proc/meminfo"
}

# write_record <case-dir> <id> [status-line]: another direct report in this
# home whose window the fake terminal lists, with an optional last status event.
write_record() {
  local dir=$1 id=$2
  {
    echo "window=firstmate:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$dir/elsewhere/$id"
    echo "project=$dir/proj"
    echo "harness=codex"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "spawned_at=2026-09-10T00:00:00Z"
  } > "$dir/home/state/$id.meta"
  printf 'fm-%s\n' "$id" >> "$dir/fake/windows"
  [ -z "${3:-}" ] || printf '%s\n' "$3" > "$dir/home/state/$id.status"
}

# new_case <name> <id> -> echoes the case dir: a project with an origin, one
# free pool copy, a fake /proc with an idle host, and no other records.
new_case() {  # <name> <id>
  local name=$1 id=$2 dir home proj free
  dir="$TMP_ROOT/$name-$RANDOM"
  home="$dir/home"
  proj="$dir/proj"
  free="$dir/pool/3/proj"
  mkdir -p "$home/state" "$home/data/$id" "$home/config" "$dir/fake" "$dir/elsewhere"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  : > "$dir/fake/tmux.log"
  : > "$dir/fake/treehouse.log"
  : > "$dir/fake/windows"
  make_tmux_stub "$dir"
  printf 'codex\n' > "$home/config/crew-harness"
  touch "$home/state/.last-watcher-beat"
  write_proc "$dir" 1.00 40000000

  git init --quiet -b main "$proj"
  printf 'base\n' > "$proj/README.md"
  git -C "$proj" add README.md
  git -C "$proj" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$proj" "$dir/origin.git"
  git -C "$proj" remote add origin "file://$dir/origin.git"
  git -C "$proj" fetch --quiet origin
  git -C "$proj" worktree add --quiet --detach "$free"

  printf '# brief for %s\n\nDelivery contract: mode=no-mistakes\n' "$id" > "$home/data/$id/brief.md"
  fm_test_backlog_ensure_queue "$home" "$id"
  printf '%s\n' "$free" > "$dir/fake/pool-get"
  printf '[{"name":"3","path":"%s","status":"available","lease_id":"","lease_holder":"","leased_at":null,"processes":[]}]\n' \
    "$free" > "$dir/fake/status.json"
  TASK_TMPS+=("/tmp/fm-$id")
  printf '%s\n' "$dir"
}

# The stubbed tmux backend is selected explicitly, and the fake /proc replaces
# the real host's readings so the verdict never depends on the machine running
# this suite. Threshold variables are unset here so each case sets exactly the
# ones it is about and the rest read their documented defaults.
run_spawn() {  # <case-dir> [FM_SPAWN_<name>=<value> ...] <spawn-args...>
  local dir=$1; shift
  local -a thresholds=()
  while [ $# -gt 0 ]; do
    case "$1" in
      FM_SPAWN_*=*) thresholds+=("$1"); shift ;;
      *) break ;;
    esac
  done
  env -u HERDR_ENV -u TMUX -u FM_SPAWN_MAX_ACTIVE -u FM_SPAWN_MAX_LOAD -u FM_SPAWN_MIN_MEM_GB \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_PROC_ROOT_OVERRIDE="$dir/proc" \
    FM_BACKEND=tmux FM_SPAWN_NO_GUARD=1 FM_SPAWN_CWD_PROOF_POLLS=1 \
    "${thresholds[@]+"${thresholds[@]}"}" "$SPAWN" "$@" 2>&1
}

assert_refused_before_anything_durable() {  # <case-dir> <id> <out>
  local dir=$1 id=$2 out=$3
  assert_no_grep '^new-window ' "$dir/fake/tmux.log" \
    "a capacity refusal must happen before endpoint creation"$'\n'"$out"
  assert_no_grep 'treehouse get' "$dir/fake/keys" \
    "a capacity refusal must not acquire a copy"$'\n'"$out"
  assert_absent "$dir/home/state/$id.meta" "a capacity refusal must publish no record"
}

test_active_worker_cap_counts_live_unfinished_workers_only() {
  local dir id=cap-count-a out rc
  dir=$(new_case count "$id")
  printf 'codex\n' > "$dir/fake/pane-cmd"
  write_record "$dir" cap-live-working 'working: implementing'
  write_record "$dir" cap-live-done 'done: PR https://example.invalid/pr/1 merged pending'
  write_record "$dir" cap-live-failed 'failed: could not build'
  write_record "$dir" cap-gone-working 'working: implementing'
  # The gone worker's record survives but its window does not.
  grep -v '^fm-cap-gone-working$' "$dir/fake/windows" > "$dir/fake/windows.new"
  mv "$dir/fake/windows.new" "$dir/fake/windows"
  out=$(run_spawn "$dir" FM_SPAWN_MAX_ACTIVE=1 "$id" "$dir/proj" --mode no-mistakes --yolo off); rc=$?
  [ "$rc" -ne 0 ] || fail "one live working record must fill FM_SPAWN_MAX_ACTIVE=1"$'\n'"$out"
  assert_contains "$out" 'FM_SPAWN_MAX_ACTIVE=1' "the refusal must name the cap"
  assert_contains "$out" 'cap-live-working' "the refusal must name the active worker it counted"
  assert_not_contains "$out" 'cap-live-done' "a done worker waiting on its merge must not count"
  assert_not_contains "$out" 'cap-live-failed' "a failed worker must not count"
  assert_not_contains "$out" 'cap-gone-working' "a record whose agent is gone must not count"
  assert_refused_before_anything_durable "$dir" "$id" "$out"
  out=$(run_spawn "$dir" FM_SPAWN_MAX_ACTIVE=2 "$id" "$dir/proj" --mode no-mistakes --yolo off); rc=$?
  expect_code 0 "$rc" "one active worker under FM_SPAWN_MAX_ACTIVE=2 must leave room for this spawn"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_present "$dir/home/state/$id.meta" "the admitted spawn must publish its record"
  pass "fm-spawn: the active-worker cap counts live unfinished workers and ignores done, failed, and gone records"
}

test_active_worker_cap_refusal_keeps_task_retryable() {
  local dir id=cap-retry-a out rc
  dir=$(new_case retry "$id")
  printf 'codex\n' > "$dir/fake/pane-cmd"
  write_record "$dir" cap-busy-one 'working: implementing'
  write_record "$dir" cap-busy-two 'working: implementing'
  out=$(run_spawn "$dir" FM_SPAWN_MAX_ACTIVE=2 "$id" "$dir/proj" --mode no-mistakes --yolo off); rc=$?
  [ "$rc" -ne 0 ] || fail "two live working records must fill FM_SPAWN_MAX_ACTIVE=2"$'\n'"$out"
  assert_contains "$out" 'FM_SPAWN_MAX_ACTIVE=2' "the refusal must name the cap"
  assert_refused_before_anything_durable "$dir" "$id" "$out"
  # One worker finishes: its last status event is done, so the same command fits.
  printf 'done: PR https://example.invalid/pr/2\n' >> "$dir/home/state/cap-busy-two.status"
  out=$(run_spawn "$dir" FM_SPAWN_MAX_ACTIVE=2 "$id" "$dir/proj" --mode no-mistakes --yolo off); rc=$?
  expect_code 0 "$rc" "the identical command must succeed once a worker finishes"$'\n'"$out"
  assert_present "$dir/home/state/$id.meta" "the retried spawn must publish its record"
  pass "fm-spawn: a cap refusal leaves the task queued and the identical command succeeds once a worker finishes"
}

test_load_guard_refuses_and_names_the_reading() {
  local dir id=cap-load-a out rc
  dir=$(new_case load "$id")
  write_proc "$dir" 61.25 40000000
  out=$(run_spawn "$dir" "$id" "$dir/proj" --mode no-mistakes --yolo off); rc=$?
  [ "$rc" -ne 0 ] || fail "load 61.25 must refuse under the default FM_SPAWN_MAX_LOAD"$'\n'"$out"
  assert_contains "$out" '61.25' "the refusal must name the measured load"
  assert_contains "$out" 'FM_SPAWN_MAX_LOAD=60' "the refusal must name the default load threshold"
  assert_refused_before_anything_durable "$dir" "$id" "$out"
  write_proc "$dir" 59.99 40000000
  out=$(run_spawn "$dir" "$id" "$dir/proj" --mode no-mistakes --yolo off); rc=$?
  expect_code 0 "$rc" "load 59.99 must be admitted under the default FM_SPAWN_MAX_LOAD"$'\n'"$out"
  assert_present "$dir/home/state/$id.meta" "the admitted spawn must publish its record"
  pass "fm-spawn: the load guard refuses above FM_SPAWN_MAX_LOAD naming the reading and admits once load drops"
}

test_load_guard_honors_configured_threshold() {
  local dir id=cap-load-b out rc
  dir=$(new_case loadcfg "$id")
  write_proc "$dir" 61.25 40000000
  out=$(run_spawn "$dir" FM_SPAWN_MAX_LOAD=80 "$id" "$dir/proj" --mode no-mistakes --yolo off); rc=$?
  expect_code 0 "$rc" "load 61.25 must be admitted under FM_SPAWN_MAX_LOAD=80"$'\n'"$out"
  pass "fm-spawn: FM_SPAWN_MAX_LOAD raises the load ceiling"
}

test_memory_guard_refuses_and_names_the_reading() {
  local dir id=cap-mem-a out rc
  dir=$(new_case mem "$id")
  # 8,000,000 kB is 8.19 decimal GB, under the default 12 GB floor.
  write_proc "$dir" 1.00 8000000
  out=$(run_spawn "$dir" "$id" "$dir/proj" --mode no-mistakes --yolo off); rc=$?
  [ "$rc" -ne 0 ] || fail "8.19 GB available must refuse under the default FM_SPAWN_MIN_MEM_GB"$'\n'"$out"
  assert_contains "$out" '8.19 GB' "the refusal must name the measured available memory"
  assert_contains "$out" 'FM_SPAWN_MIN_MEM_GB=12' "the refusal must name the default memory floor"
  assert_refused_before_anything_durable "$dir" "$id" "$out"
  out=$(run_spawn "$dir" FM_SPAWN_MIN_MEM_GB=4 "$id" "$dir/proj" --mode no-mistakes --yolo off); rc=$?
  expect_code 0 "$rc" "8.19 GB available must be admitted under FM_SPAWN_MIN_MEM_GB=4"$'\n'"$out"
  assert_present "$dir/home/state/$id.meta" "the admitted spawn must publish its record"
  pass "fm-spawn: the memory guard refuses below FM_SPAWN_MIN_MEM_GB naming the reading and honors the configured floor"
}

test_invalid_threshold_stops_the_spawn() {
  local dir id=cap-invalid-a out rc
  dir=$(new_case invalid "$id")
  out=$(run_spawn "$dir" FM_SPAWN_MAX_ACTIVE=0 "$id" "$dir/proj" --mode no-mistakes --yolo off); rc=$?
  [ "$rc" -ne 0 ] || fail "FM_SPAWN_MAX_ACTIVE=0 must stop the spawn rather than default"$'\n'"$out"
  assert_contains "$out" 'FM_SPAWN_MAX_ACTIVE' "the error must name the invalid variable"
  assert_refused_before_anything_durable "$dir" "$id" "$out"
  out=$(run_spawn "$dir" FM_SPAWN_MAX_ACTIVE=12abc "$id" "$dir/proj" --mode no-mistakes --yolo off); rc=$?
  [ "$rc" -ne 0 ] || fail "FM_SPAWN_MAX_ACTIVE=12abc must stop the spawn rather than disable the cap"$'\n'"$out"
  assert_contains "$out" 'FM_SPAWN_MAX_ACTIVE' "the error must name the invalid variable"
  assert_refused_before_anything_durable "$dir" "$id" "$out"
  out=$(run_spawn "$dir" FM_SPAWN_MIN_MEM_GB=lots "$id" "$dir/proj" --mode no-mistakes --yolo off); rc=$?
  [ "$rc" -ne 0 ] || fail "FM_SPAWN_MIN_MEM_GB=lots must stop the spawn rather than default"$'\n'"$out"
  assert_contains "$out" 'FM_SPAWN_MIN_MEM_GB' "the error must name the invalid variable"
  assert_refused_before_anything_durable "$dir" "$id" "$out"
  pass "fm-spawn: an invalid capacity threshold stops the spawn naming the variable"
}

test_relaunch_is_bounded_by_the_active_cap_excluding_its_own_record() {
  local dir id=cap-relaunch-a out rc
  dir=$(new_case relaunch "$id")
  printf 'codex\n' > "$dir/fake/pane-cmd"
  # The task being relaunched: its record and window survive, but its pane
  # holds only a shell, so it is positively agent-free (relaunch's precondition).
  write_record "$dir" "$id" 'working: implementing'
  git -C "$dir/proj" worktree add --quiet -b "task-$id" "$dir/elsewhere/$id"
  printf '%s' "$dir/elsewhere/$id" > "$dir/fake/cwd"
  printf 'bash\n' > "$dir/fake/pane-cmd.fm-$id"
  write_record "$dir" cap-relaunch-busy 'working: implementing'
  cp "$dir/home/state/$id.meta" "$dir/$id.meta.before"
  out=$(run_spawn "$dir" FM_SPAWN_MAX_ACTIVE=1 "$id" --relaunch); rc=$?
  [ "$rc" -ne 0 ] || fail "one other live working record must refuse a relaunch under FM_SPAWN_MAX_ACTIVE=1"$'\n'"$out"
  assert_contains "$out" 'FM_SPAWN_MAX_ACTIVE=1' "the relaunch refusal must name the cap"
  assert_contains "$out" 'has 1 active direct reports (cap-relaunch-busy)' \
    "the relaunch refusal must count only the other live worker, never the relaunched task's own record"
  assert_no_grep '^new-window ' "$dir/fake/tmux.log" \
    "a refused relaunch must create no endpoint"$'\n'"$out"
  assert_no_grep '^send-keys ' "$dir/fake/tmux.log" \
    "a refused relaunch must send nothing to the recorded endpoint"$'\n'"$out"
  cmp -s "$dir/$id.meta.before" "$dir/home/state/$id.meta" \
    || fail "a refused relaunch must leave the task's record exactly as it was"
  out=$(run_spawn "$dir" FM_SPAWN_MAX_ACTIVE=2 "$id" --relaunch); rc=$?
  assert_not_contains "$out" 'host capacity' \
    "one other live worker under FM_SPAWN_MAX_ACTIVE=2 must leave room for the relaunch"$'\n'"$out"
  expect_code 0 "$rc" "the admitted relaunch must succeed"$'\n'"$out"
  pass "fm-spawn: a relaunch is refused by the active-worker cap naming it and excluding the relaunched task's own record"
}

test_host_without_proc_is_still_bounded_by_the_active_cap() {
  local dir id=cap-noproc-a out rc
  dir=$(new_case noproc "$id")
  rm -f "$dir/proc/loadavg" "$dir/proc/meminfo"
  printf 'codex\n' > "$dir/fake/pane-cmd"
  write_record "$dir" cap-noproc-busy 'working: implementing'
  out=$(run_spawn "$dir" FM_SPAWN_MAX_ACTIVE=1 "$id" "$dir/proj" --mode no-mistakes --yolo off); rc=$?
  [ "$rc" -ne 0 ] || fail "without /proc the active-worker cap must still refuse"$'\n'"$out"
  assert_contains "$out" 'FM_SPAWN_MAX_ACTIVE=1' "the refusal must name the cap"
  assert_refused_before_anything_durable "$dir" "$id" "$out"
  out=$(run_spawn "$dir" FM_SPAWN_MAX_ACTIVE=2 "$id" "$dir/proj" --mode no-mistakes --yolo off); rc=$?
  expect_code 0 "$rc" "without /proc a spawn under the active-worker cap must be admitted"$'\n'"$out"
  assert_contains "$out" 'notice:' "a host with no /proc readings must say the load and memory guard did not run"
  pass "fm-spawn: a host without /proc readings says so and stays bounded by the active-worker cap"
}

test_active_worker_cap_counts_live_unfinished_workers_only
test_active_worker_cap_refusal_keeps_task_retryable
test_load_guard_refuses_and_names_the_reading
test_load_guard_honors_configured_threshold
test_memory_guard_refuses_and_names_the_reading
test_invalid_threshold_stops_the_spawn
test_relaunch_is_bounded_by_the_active_cap_excluding_its_own_record
test_host_without_proc_is_still_bounded_by_the_active_cap

echo "# all fm-spawn-capacity tests passed"
