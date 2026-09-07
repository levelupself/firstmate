#!/usr/bin/env bash
# Regression test for the fm-spawn.sh treehouse-get worktree-detection settle
# loop (bin/fm-spawn.sh, the `for _ in $(seq 1 60)` loop after `treehouse get`).
#
# On some tmux/WSL setups a brand-new window's pane_current_path transiently
# reports a stale, unrelated-but-real path on the very first poll, before the
# pane actually settles into the worktree treehouse get moved it to. That stale
# path still passes the loop's "differs from the project" check and
# validate_spawn_worktree's "is a real, distinct worktree" check (it IS a real
# git checkout, just the wrong one), so a naive single-read loop silently
# records the wrong worktree= in state/<id>.meta. This test simulates that
# transient-then-settled pane_current_path sequence with a fake tmux and
# asserts the recorded worktree resolves to the real, settled worktree, never
# the stale first read.
#
# It also covers the harder case the settle loop alone cannot answer: a pane
# that keeps reporting a real-but-unentered worktree path while its shell never
# leaves the primary checkout. Two consecutive agreeing reads satisfy the settle
# loop and the reported path passes validate_spawn_worktree, so the launch went
# ahead in the PRIMARY CHECKOUT while state/<id>.meta recorded an isolated copy
# the shell had never entered. The fake tmux below therefore models the pane's
# reported path and the pane shell's actual cwd as two independent facts, and
# these cases drive them apart.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-settle)

# make_settle_fakebin <dir> builds a fake tmux whose `#{pane_current_path}`
# query returns FM_FAKE_PANE_STALE for the first FM_FAKE_PANE_STALE_READS
# calls, then FM_FAKE_PANE_PATH forever after - reproducing a pane that
# transiently reports a stale cwd before settling into the real worktree.
make_settle_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ "$n" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_STALE:-}"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  # Every sent line is recorded, so a case can prove a launch command was never
  # issued. fm_fake_pane_shell (tests/lib.sh) supplies the pane's own shell.
  send-keys) printf '%s\n' "$*" >> "${FM_FAKE_SENDLOG:?FM_FAKE_SENDLOG unset}"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_pane_shell "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_settle_case <name> <id> <stale_reads> [shell_cwd_kind] builds a home, a
# primary project with a real worktree (the eventual settled path), and a
# separate real git repo standing in for the stale path (a real checkout of
# something else entirely, distinct from both the project and the worktree -
# mirroring the live incident where the stale read was another real firstmate
# home). shell_cwd_kind names where the fake pane's SHELL actually sits - wt
# (default), project, or stale - independently of what the pane reports.
make_settle_case() {
  local name=$1 id=$2 stale_reads=$3 shell_kind=${4:-wt}
  local case_dir home proj wt stale fakebin countfile sendlog shell_cwd
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  stale="$case_dir/stale-other-checkout"
  countfile="$case_dir/pane-call-count"
  sendlog="$case_dir/pane-send-log"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_git_init_commit "$stale"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  fm_test_backlog_queue "$home" "$id"
  touch "$home/state/.last-watcher-beat"
  : > "$sendlog"
  case "$shell_kind" in
    project) shell_cwd=$proj ;;
    stale) shell_cwd=$stale ;;
    *) shell_cwd=$wt ;;
  esac
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin|$countfile|$stale_reads|$shell_cwd|$sendlog"
}

read_settle_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR COUNTFILE STALE_READS \
    SHELL_CWD SENDLOG <<EOF
$1
EOF
}

run_settle_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    FM_FAKE_SHELL_CWD="$SHELL_CWD" FM_FAKE_SENDLOG="$SENDLOG" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# How many times the settle loop read pane_current_path. The loop sleeps once
# per read, so this count IS its cycle count - and unlike wall-clock seconds it
# is the same number on an idle machine and a saturated one. Wall clock cannot
# stand in for it: a busy host stretches the identical two-read path from about
# two seconds to seventeen without the loop doing anything different.
settle_pane_reads() {
  cat "$COUNTFILE"
}

# A single stale first read (the exact incident) must not be accepted: the
# loop should keep polling until two consecutive reads agree, landing on the
# real settled worktree instead. A mismatch must make the stale path the new
# candidate rather than reset the wait, so this costs exactly three reads: the
# stale one, the first real one, and one confirming read.
test_single_stale_first_read_is_not_accepted() {
  local rec id out status reads
  id=settle-single-stale-z1
  rec=$(make_settle_case settle-single "$id" 1)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane settles"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_grep 'worktree_allocation=reused' "$HOME_DIR/state/$id.meta" \
    "meta did not preserve that the pooled worktree predated this allocation"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the transient stale path as the worktree"
  reads=$(settle_pane_reads)
  [ "$reads" = 3 ] || fail "a single stale first read cost $reads pane_current_path reads - expected the stale read, the first real read, and one confirming read"
  pass "a single transient stale pane_current_path read is not accepted as the worktree"
}

# A pane that reports the real worktree from the very first read still only
# costs the loop's existing one-second inter-poll sleep to confirm - not an
# extra full cycle on top of that. That is exactly two reads.
test_already_settled_pane_costs_one_confirm_sleep() {
  local rec id out status reads
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  reads=$(settle_pane_reads)
  [ "$reads" = 2 ] || fail "an already-settled pane cost $reads pane_current_path reads - expected the first read plus one confirming read"
  pass "an already-settled pane confirms via the existing inter-poll sleep, not an extra full cycle"
}

# The live incident: the isolated-copy pool was exhausted, the pane's shell
# never left the primary checkout, and the pane nevertheless kept reporting a
# real pooled worktree. The settle loop's two agreeing reads and
# validate_spawn_worktree both pass on that reported path, so the agent was
# launched into the primary checkout while the durable record claimed a copy the
# shell had never entered. Only the brief's own isolation sentence stopped it.
# Entering the worktree and launching must be one atomic step: no confirmed
# entry means no agent and no recorded worktree.
test_unentered_worktree_launches_nothing_and_records_nothing() {
  local rec id out status
  id=settle-unentered-z3
  rec=$(make_settle_case settle-unentered "$id" 0 project)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded while its shell was still in the primary checkout: $out"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "a spawn that never entered a worktree still left durable task metadata behind"
  assert_no_grep codex "$SENDLOG" \
    "an agent launch was sent to the pane despite the shell never entering a worktree"
  pass "a pane reporting a worktree its shell never entered launches no agent and records no worktree"
}

# The recorded worktree must be where the agent actually is, not what the
# terminal reported. Here the pane reports the unrelated stale checkout for
# every read while the shell sits in the real worktree, so the durable record
# must name the shell's worktree.
test_recorded_worktree_is_the_shell_own_cwd() {
  local rec id out status
  id=settle-shell-authority-z4
  rec=$(make_settle_case settle-shell-authority "$id" 999 wt)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed when the shell is in a real isolated worktree"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the worktree the shell is actually in"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta recorded the terminal's reported path instead of the shell's own cwd"
  pass "the recorded worktree is the shell's own cwd, not the pane's reported path"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_sleep
test_unentered_worktree_launches_nothing_and_records_nothing
test_recorded_worktree_is_the_shell_own_cwd

echo "# all fm-spawn-worktree-settle tests passed"
