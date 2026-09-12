#!/usr/bin/env bash
# fm-spawn.sh --reacquire-worktree: recover a task whose recorded pooled copy
# was taken by another task while its branch survived in the shared repository.
#
# Neither existing recovery path serves this case: --relaunch adopts the recorded
# copy, which now holds the other task's checkout, and --reattach-worktree needs
# a retained copy that still holds the work. These tests drive the real spawn
# path against a fake terminal whose fake pool behaves like treehouse, and pin:
#   1. A success acquires a fresh copy, checks the task's branch out there at its
#      current head, and republishes the binding, without touching the copy the
#      other task now owns or that task's record.
#   2. A copy the pool would hand out while another record binds it is avoided
#      here exactly as on a fresh spawn, and an agent-free recorded endpoint is
#      closed before the replacement is created.
#   3. A recorded copy that still holds the task's branch refuses, pointing at
#      the recovery path that adopts it.
#   4. A failure after the replacement endpoint exists restores the prior record,
#      removes the endpoint, and leaves the fresh copy off the task's branch.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-reacquire)
TASK_TMPS=()

reacquire_cleanup() {
  local d
  for d in "${TASK_TMPS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  fm_test_cleanup
}
trap reacquire_cleanup EXIT

# The same pool-aware tmux stub tests/fm-spawn-pool-slot-binding.test.sh uses:
# `treehouse get` enters the copy the fake pool would hand out and refreshes it,
# `treehouse enter <name>` enters that copy untouched, and the launch literal
# can be made to fail after the endpoint exists.
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
    printf '%s\n' "$*" >> "$D/killed"
    : > "$D/windows"
    exit 0
    ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *pane_current_path*) pane_cwd; printf '\n'; exit 0 ;;
        *pane_current_command*) printf '%s\n' "${FM_FAKE_PANE_COMMAND:-bash}"; exit 0 ;;
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
      [ -z "${FM_FAKE_LAUNCH_FAIL:-}" ] || case "$text" in *codex*) exit 1 ;; esac
      exit 0
    fi
    printf '%s\n' "$text" >> "$D/keys"
    case "$text" in
      'treehouse get')
        handout=$(cat "$D/pool-get")
        printf '%s' "$handout" > "$D/cwd"
        git -C "$handout" checkout -q --detach refs/remotes/origin/main
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

pool_entry() {  # <name> <path> <status> [processes-json]
  printf '{"name":"%s","path":"%s","status":"%s","lease_id":"","lease_holder":"","leased_at":null,"processes":%s}' \
    "$1" "$2" "$3" "${4:-[]}"
}

write_meta_for() {  # <home> <id> <worktree> <project>
  local home=$1 id=$2 wt=$3 proj=$4
  {
    echo "window=firstmate:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "worktree_allocation=reused"
    echo "allocation_project=$proj"
    echo "project=$proj"
    echo "harness=codex"
    echo "kind=ship"
    echo "mode=direct-PR"
    echo "yolo=on"
    echo "tasktmp=/tmp/fm-$id"
    echo "spawned_at=2026-09-10T23:18:04Z"
    echo "model=default"
    echo "effort=high"
    echo "spawn_gen=s1.1.1"
  } > "$home/state/$id.meta"
}

# new_case <name> <id> <holder-id> -> echoes the case dir.
#
# Models the incident: <id>'s record names pool copy 9, whose checkout now holds
# <holder>'s branch under <holder>'s live record; <id>'s branch survived in the
# shared object store with its work committed; pool copy 12 is free.
new_case() {  # <name> <id> <holder>
  local name=$1 id=$2 holder=$3 dir home proj taken free
  dir="$TMP_ROOT/$name-$RANDOM"
  home="$dir/home"
  proj="$dir/proj"
  taken="$dir/pool/9/proj"
  free="$dir/pool/12/proj"
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
  git -C "$proj" add README.md
  git -C "$proj" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$proj" "$dir/origin.git"
  git -C "$proj" remote add origin "file://$dir/origin.git"
  git -C "$proj" fetch --quiet origin
  # The task's branch, created and committed in copy 9, then displaced there
  # exactly as the pool does on handout: the branch survives, the checkout moves.
  git -C "$proj" worktree add --quiet -b "fm/$id" "$taken"
  printf 'kernel work\n' > "$taken/kernel.txt"
  git -C "$taken" add kernel.txt
  git -C "$taken" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'task work committed before the reboot'
  git -C "$taken" checkout -q --detach refs/remotes/origin/main
  git -C "$taken" checkout -q -b "fm/$holder"
  printf 'holder work\n' > "$taken/holder.txt"
  git -C "$taken" add holder.txt
  git -C "$taken" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'holder task work'
  git -C "$proj" worktree add --quiet --detach "$free"

  printf '# brief for %s\n\nDelivery contract: mode=direct-PR\n' "$id" > "$home/data/$id/brief.md"
  fm_test_backlog_ensure_queue "$home" "$id"
  write_meta_for "$home" "$id" "$taken" "$proj"
  write_meta_for "$home" "$holder" "$taken" "$proj"
  printf '%s\n' "$free" > "$dir/fake/pool-get"
  printf '9\t%s\n12\t%s\n' "$taken" "$free" > "$dir/fake/pool-slots"
  printf '[%s,%s]\n' "$(pool_entry 9 "$taken" in-use '[{"pid":4242,"name":"bash"}]')" \
    "$(pool_entry 12 "$free" available)" > "$dir/fake/status.json"
  TASK_TMPS+=("/tmp/fm-$id")
  printf '%s\n' "$dir"
}

run_spawn() {  # <case-dir> <args...>
  local dir=$1; shift
  env -u HERDR_ENV -u TMUX PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_SPAWN_NO_GUARD=1 FM_SPAWN_CWD_PROOF_POLLS=1 \
    FM_FAKE_LAUNCH_FAIL="${FM_FAKE_LAUNCH_FAIL:-}" \
    FM_FAKE_PANE_COMMAND="${FM_FAKE_PANE_COMMAND:-}" \
    "$SPAWN" "$@" 2>&1
}

assert_holder_untouched() {  # <case-dir> <holder> <taken> <head-before>
  local dir=$1 holder=$2 taken=$3 before=$4
  [ "$(git -C "$taken" symbolic-ref --quiet --short HEAD 2>/dev/null)" = "fm/$holder" ] \
    || fail "the copy the other task holds was moved off fm/$holder"
  [ "$(git -C "$taken" rev-parse HEAD)" = "$before" ] || fail "the other task's HEAD moved"
  [ "$(cat "$taken/holder.txt" 2>/dev/null)" = 'holder work' ] \
    || fail "the other task's committed content changed"
  cmp -s "$dir/holder.meta.before" "$dir/home/state/$holder.meta" \
    || fail "the other task's record changed"
}

test_reacquire_rebinds_to_fresh_copy_at_branch_head() {
  local dir id=rq-collided-a holder=rq-holder-a taken free head holder_head out rc meta
  dir=$(new_case success "$id" "$holder")
  taken="$dir/pool/9/proj"
  free="$dir/pool/12/proj"
  head=$(git -C "$dir/proj" rev-parse "refs/heads/fm/$id")
  holder_head=$(git -C "$taken" rev-parse HEAD)
  cp "$dir/home/state/$holder.meta" "$dir/holder.meta.before"
  out=$(run_spawn "$dir" "$id" --reacquire-worktree); rc=$?
  expect_code 0 "$rc" "reacquire should succeed"$'\n'"$out"
  assert_contains "$out" "spawned $id" "reacquire did not report success"
  assert_contains "$out" "worktree=$free" "reacquire did not report the fresh copy"
  meta="$dir/home/state/$id.meta"
  assert_grep "worktree=$free" "$meta" "the record does not name the fresh copy"
  assert_grep "window=firstmate:fm-$id" "$meta" "the record does not name the replacement endpoint"
  assert_grep 'mode=direct-PR' "$meta" "the record lost its delivery mode"
  assert_grep 'yolo=on' "$meta" "the record lost its yolo posture"
  assert_grep 'effort=high' "$meta" "the record lost its effort axis"
  assert_grep 'spawned_at=2026-09-10T23:18:04Z' "$meta" "the record lost its original spawn time"
  assert_no_grep 'spawn_gen=s1.1.1' "$meta" "the record kept the previous incarnation token"
  assert_grep 'spawn_gen=' "$meta" "the record has no incarnation token"
  [ "$(git -C "$free" symbolic-ref --quiet --short HEAD 2>/dev/null)" = "fm/$id" ] \
    || fail "the fresh copy is not on fm/$id: $(git -C "$free" rev-parse --abbrev-ref HEAD 2>&1)"
  [ "$(git -C "$free" rev-parse HEAD)" = "$head" ] \
    || fail "the fresh copy is not at the branch's recorded head"
  [ "$(cat "$free/kernel.txt" 2>/dev/null)" = 'kernel work' ] \
    || fail "the fresh copy does not hold the task's committed work"
  assert_holder_untouched "$dir" "$holder" "$taken" "$holder_head"
  assert_contains "$out" "$taken" "the success notice must name the displaced copy"
  assert_grep 'codex' "$dir/fake/literal" "no replacement agent launch was staged"
  assert_grep 'Enter' "$dir/fake/keys" "the replacement agent was never activated"
  pass "fm-spawn reacquire: a collided task is rebound to a fresh copy at its branch head without touching the other task's copy"
}

test_reacquire_avoids_bound_handout_and_closes_agent_free_endpoint() {
  local dir id=rq-collided-b holder=rq-holder-b taken free head holder_head out rc
  dir=$(new_case steer "$id" "$holder")
  taken="$dir/pool/9/proj"
  free="$dir/pool/12/proj"
  head=$(git -C "$dir/proj" rev-parse "refs/heads/fm/$id")
  holder_head=$(git -C "$taken" rev-parse HEAD)
  cp "$dir/home/state/$holder.meta" "$dir/holder.meta.before"
  # The pool believes copy 9 is free again and would hand it out first.
  printf '[%s,%s]\n' "$(pool_entry 9 "$taken" available)" "$(pool_entry 12 "$free" available)" \
    > "$dir/fake/status.json"
  printf '%s\n' "$taken" > "$dir/fake/pool-get"
  # The recorded endpoint still exists with only a shell in it.
  printf 'fm-%s\n' "$id" > "$dir/fake/windows"
  out=$(run_spawn "$dir" "$id" --reacquire-worktree); rc=$?
  expect_code 0 "$rc" "reacquire should succeed around a bound handout"$'\n'"$out"
  assert_no_grep 'treehouse get' "$dir/fake/keys" \
    "reacquire must not run treehouse get while the pool would hand out the other task's copy"
  assert_grep 'treehouse enter 12' "$dir/fake/keys" "reacquire did not enter the free copy by name"
  assert_grep 'kill-window' "$dir/fake/killed" "the agent-free recorded endpoint was not closed"
  assert_grep "worktree=$free" "$dir/home/state/$id.meta" "the record does not name the fresh copy"
  [ "$(git -C "$free" rev-parse HEAD)" = "$head" ] \
    || fail "the fresh copy is not at the branch's recorded head"
  assert_holder_untouched "$dir" "$holder" "$taken" "$holder_head"
  pass "fm-spawn reacquire: the bound copy is avoided and an agent-free recorded endpoint is closed first"
}

test_reacquire_refuses_copy_that_still_holds_the_branch() {
  local dir id=rq-intact-c holder=rq-holder-c taken free out rc
  dir=$(new_case intact "$id" "$holder")
  taken="$dir/pool/9/proj"
  free="$dir/pool/12/proj"
  # Put the recorded copy back on the task's own branch: nothing was displaced.
  git -C "$taken" checkout -q "fm/$id"
  rm -f "$dir/home/state/$holder.meta"
  cp "$dir/home/state/$id.meta" "$dir/meta.before"
  out=$(run_spawn "$dir" "$id" --reacquire-worktree); rc=$?
  [ "$rc" -ne 0 ] || fail "a recorded copy still holding the branch must refuse"$'\n'"$out"
  assert_contains "$out" "--relaunch" "the refusal must point at the path that adopts the intact copy"
  cmp -s "$dir/meta.before" "$dir/home/state/$id.meta" || fail "a refused reacquire changed the record"
  [ ! -s "$dir/fake/windows" ] || fail "a refused reacquire created an endpoint"
  assert_no_grep 'treehouse' "$dir/fake/keys" "a refused reacquire touched the pool"
  git -C "$free" symbolic-ref --quiet HEAD >/dev/null 2>&1 \
    && fail "a refused reacquire checked something out in the free copy"
  pass "fm-spawn reacquire: a recorded copy that still holds the task's branch is relaunch's job"
}

test_reacquire_failure_after_endpoint_rolls_back() {
  local dir id=rq-rollback-d holder=rq-holder-d taken free holder_head out rc
  dir=$(new_case rollback "$id" "$holder")
  taken="$dir/pool/9/proj"
  free="$dir/pool/12/proj"
  holder_head=$(git -C "$taken" rev-parse HEAD)
  cp "$dir/home/state/$holder.meta" "$dir/holder.meta.before"
  cp "$dir/home/state/$id.meta" "$dir/meta.before"
  out=$(FM_FAKE_LAUNCH_FAIL=1 run_spawn "$dir" "$id" --reacquire-worktree); rc=$?
  [ "$rc" -ne 0 ] || fail "a failed launch stage must fail the reacquire"$'\n'"$out"
  assert_contains "$out" "leaving the task on its previous record" \
    "the failure must say the prior record stands"
  cmp -s "$dir/meta.before" "$dir/home/state/$id.meta" \
    || fail "a failed reacquire did not restore the prior record"
  [ ! -s "$dir/fake/windows" ] || fail "a failed reacquire left its replacement endpoint behind"
  git -C "$free" symbolic-ref --quiet HEAD >/dev/null 2>&1 \
    && fail "a failed reacquire left the fresh copy on the task's branch"
  git -C "$dir/proj" rev-parse --verify --quiet "refs/heads/fm/$id" >/dev/null \
    || fail "a failed reacquire lost the task's branch"
  assert_holder_untouched "$dir" "$holder" "$taken" "$holder_head"
  ls "$dir/home/state"/.*reattach* >/dev/null 2>&1 \
    && fail "a failed reacquire left undo material behind"
  pass "fm-spawn reacquire: a failure after the replacement endpoint exists restores the prior record and detaches the fresh copy"
}

make_herdr_statefake() {  # <dir> -> echoes fakebin dir; seeds an empty state file
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  printf '{"next":1,"workspaces":[],"tabs":[],"agent_status":{}}\n' > "$dir/state.json"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_HERDR_LOG:?}"
STATE="${FM_FAKE_HERDR_STATE:?}"
{
  printf 'HERDR_SESSION=%s' "${HERDR_SESSION:-}"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"

jq_state() { jq "$@" "$STATE"; }
save() { local tmp="$STATE.tmp.$$"; cat > "$tmp" && mv "$tmp" "$STATE"; }

cmd=${1:-}; sub=${2:-}
ws=""; label=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    --workspace) ws=${args[$((i+1))]:-} ;;
    --label) label=${args[$((i+1))]:-} ;;
  esac
done

case "$cmd $sub" in
  "status --json")
    printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'
    ;;
  "session list")
    jq -n --arg socket "$FM_FAKE_DIR/herdr.sock" '{sessions:[{name:"fmtest",running:true,socket_path:$socket}]}'
    ;;
  "workspace list")
    jq_state '{result:{workspaces:.workspaces}}'
    ;;
  "workspace create")
    n=$(jq_state -r '.next'); wsid="w$n"; dn=$((n + 1))
    jq_state --arg wsid "$wsid" --arg wlabel "$label" \
      --arg tabid "$wsid:t$dn" --arg paneid "$wsid:p$dn" \
      '.workspaces += [{workspace_id:$wsid, label:$wlabel}]
       | .tabs += [{tab_id:$tabid, label:"1", workspace_id:$wsid, pane_id:$paneid}]
       | .next = (.next + 2)' | save
    printf '{"result":{"workspace":{"workspace_id":"%s","label":"%s"},"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' \
      "$wsid" "$label" "$wsid:t$dn" "$wsid:p$dn"
    ;;
  "tab list")
    jq_state --arg w "$ws" '{result:{tabs:[.tabs[]|select(.workspace_id==$w)]}}'
    ;;
  "tab create")
    n=$(jq_state -r '.next'); tabid="$ws:t$n"; paneid="$ws:p$n"
    jq_state --arg w "$ws" --arg wlabel "$label" --arg tabid "$tabid" --arg paneid "$paneid" \
      '.tabs += [{tab_id:$tabid, label:$wlabel, workspace_id:$w, pane_id:$paneid}]
       | .next = (.next + 1)' | save
    printf '{"result":{"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' "$tabid" "$paneid"
    ;;
  "pane get")
    p=${3:-}
    if jq_state -e --arg p "$p" '.tabs[] | select(.pane_id == $p)' >/dev/null; then
      jq_state --arg p "$p" --arg cwd "$(cat "$FM_FAKE_DIR/cwd")" '{result:{pane:([.tabs[]|select(.pane_id==$p)][0] + {foreground_cwd:$cwd})}}'
    else
      echo '{"error":{"code":"pane_not_found"}}'
    fi
    ;;
  "pane run")
    text=${4:-}
    printf '%s\n' "$text" >> "$FM_FAKE_DIR/keys"
    case "$text" in
      'treehouse get') cat "$FM_FAKE_DIR/pool-get" > "$FM_FAKE_DIR/cwd"; git -C "$(cat "$FM_FAKE_DIR/cwd")" checkout -q --detach origin/main ;;
      'treehouse enter '*) name=${text#treehouse enter }; awk -F '\t' -v n="$name" '$1==n {print $2}' "$FM_FAKE_DIR/pool-slots" > "$FM_FAKE_DIR/cwd" ;;
      'pwd -P > '*) (cd "$(cat "$FM_FAKE_DIR/cwd")" && eval "$text") ;;
    esac
    ;;
  "pane send-text")
    [ -z "${FM_FAKE_LAUNCH_FAIL:-}" ] || case "${4:-}" in *codex*) exit 1 ;; esac
    printf '%s\n' "${4:-}" >> "$FM_FAKE_DIR/literal" ;;
  "pane list")
    jq_state --arg w "$ws" '{result:{panes:[.tabs[]|select(.workspace_id==$w)|{pane_id:.pane_id, tab_id:.tab_id}]}}'
    ;;
  "pane close")
    pane=${3:-}
    jq_state --arg p "$pane" '.tabs |= [.[]|select(.pane_id != $p)]' | save
    ;;
  "tab close")
    tab=${3:-}
    jq_state --arg t "$tab" '.tabs |= [.[]|select(.tab_id != $t)]' | save
    ;;
  "agent get")
    pane=${3:-}
    status=$(jq_state -r --arg p "$pane" '.agent_status[$p] // empty')
    if [ -n "$status" ]; then
      printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "$status"
    else
      printf '{"error":{"code":"agent_not_found","message":"agent target %s not found"}}\n' "$pane"
    fi
    ;;
  *) : ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

test_herdr_reacquire() {
  local state=$1 launch_fail=${2:-} dir id="rq-herdr-$1${2:-}" holder="rq-owner-$1${2:-}"
  local taken free head holder_head out rc
  dir=$(new_case herdr "$id" "$holder")
  taken="$dir/pool/9/proj"
  free="$dir/pool/12/proj"
  head=$(git -C "$dir/proj" rev-parse "fm/$id")
  holder_head=$(git -C "$taken" rev-parse HEAD)
  cp "$dir/home/state/$holder.meta" "$dir/holder.meta.before"
  make_herdr_statefake "$dir" >/dev/null
  if [ "$state" = agent-free ]; then
    printf '%s\n' '{"next":1,"workspaces":[{"workspace_id":"w0","label":"firstmate"}],"tabs":[{"workspace_id":"w0","tab_id":"w0:t0","pane_id":"w0:p0","label":"old-task"}],"agent_status":{}}' > "$dir/state.json"
  fi
  printf '%s\n' "$dir/proj" > "$dir/fake/cwd"
  printf 'off\n' > "$dir/home/config/herdr-presentation"
  sed -i.bak "s|window=firstmate:fm-$id|window=fmtest:w0:p0|" "$dir/home/state/$id.meta"
  printf 'backend=herdr\nherdr_session=fmtest\nherdr_workspace_id=w0\nherdr_tab_id=w0:t0\nherdr_pane_id=w0:p0\n' >> "$dir/home/state/$id.meta"
  cp "$dir/home/state/$id.meta" "$dir/meta.before"
  out=$(unset HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_WORKSPACE_ID HERDR_TAB_ID
    export FM_HERDR_LOG="$dir/herdr.log" FM_FAKE_HERDR_STATE="$dir/state.json" HERDR_SESSION=fmtest FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0
    FM_FAKE_LAUNCH_FAIL=$launch_fail run_spawn "$dir" "$id" --reacquire-worktree); rc=$?
  if [ -n "$launch_fail" ]; then
    [ "$rc" -ne 0 ] || fail "Herdr launch failure unexpectedly succeeded"
    assert_contains "$out" 'leaving the task on its previous record' "Herdr rollback was not reached: $out"
    cmp -s "$dir/meta.before" "$dir/home/state/$id.meta" || fail "Herdr rollback changed the prior record"
    git -C "$free" symbolic-ref --quiet HEAD >/dev/null 2>&1 && fail "Herdr rollback left branch checked out"
    jq -e '[.tabs[] | select(.label == "fm-'"$id"'")] | length == 0' "$dir/state.json" >/dev/null || fail "replacement endpoint survived rollback"
  else
    expect_code 0 "$rc" "Herdr $state recovery failed: $out"
    assert_grep "worktree=$free" "$dir/home/state/$id.meta" "Herdr recovery did not rebind"
    assert_no_grep 'herdr_pane_id=w0:p0' "$dir/home/state/$id.meta" "Herdr recovery retained stale endpoint"
    [ "$(git -C "$free" rev-parse HEAD)" = "$head" ] || fail "Herdr recovery changed branch head"
    assert_grep codex "$dir/fake/literal" "Herdr replacement launch missing"
  fi
  if [ "$state" = agent-free ]; then
    jq -e '[.tabs[] | select(.pane_id == "w0:p0")] | length == 0' "$dir/state.json" >/dev/null || fail "old shell endpoint survived"
  fi
  assert_holder_untouched "$dir" "$holder" "$taken" "$holder_head"
  pass "Herdr reacquire: $state endpoint, launch failure=${launch_fail:-no}"
}

test_herdr_reacquire missing
test_herdr_reacquire agent-free
test_herdr_reacquire agent-free 1

test_reacquire_rebinds_to_fresh_copy_at_branch_head
test_reacquire_avoids_bound_handout_and_closes_agent_free_endpoint
test_reacquire_refuses_copy_that_still_holds_the_branch
test_reacquire_failure_after_endpoint_rolls_back

echo "# all fm-spawn-reacquire tests passed"
