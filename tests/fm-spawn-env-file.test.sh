#!/usr/bin/env bash
# fm-spawn.sh --env-file: a caller-supplied KEY=VALUE file is exported into the
# task's pane shell before the harness launches, so the agent and every child
# process inherit it. An isolated copy strips the ambient environment an
# ordinary pooled copy happens to inherit (a like-for-like model comparison
# stopped because MTG_ORACLE_ROOT was unset in every arm), and the fix has to be
# mechanical rather than a line in the brief the worker may or may not act on.
#
# The fake tmux below records every sent line so the test can prove the order:
# every export lands before the launch command, values are shell-quoted, and a
# file that is malformed or names a firstmate-owned variable refuses the spawn
# before any endpoint exists.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-env-file)

make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) printf '%s\n' "$*" >> "${FM_FAKE_SENDLOG:?FM_FAKE_SENDLOG unset}"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_pane_shell "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

make_case() {  # <name> <id>
  local name=$1 id=$2 case_dir home proj wt fakebin sendlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  sendlog="$case_dir/pane-send-log"
  fakebin=$(make_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  fm_test_backlog_queue "$home" "$id"
  touch "$home/state/.last-watcher-beat"
  : > "$sendlog"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$sendlog"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR SENDLOG <<EOF
$1
EOF
}

run_spawn() {  # <id> [extra spawn args...]
  local id=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_SENDLOG="$SENDLOG" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off "$@" 2>&1
}

test_env_file_exports_land_before_the_launch() {
  local rec id out status env_file export_line launch_line
  id=envfile-exports-z1
  rec=$(make_case exports "$id")
  read_case "$rec"
  env_file="$CASE_DIR/arm.env"
  printf "MTG_ORACLE_ROOT=/data/oracle\nQUOTED=it's here\n\n# a comment\n" > "$env_file"

  out=$(run_spawn "$id" --env-file "$env_file")
  status=$?
  expect_code 0 "$status" "spawn with a valid --env-file should succeed: $out"
  assert_grep "export MTG_ORACLE_ROOT='/data/oracle'" "$SENDLOG" \
    "the first variable was not exported into the pane"
  assert_grep "export QUOTED='it'\\''s here'" "$SENDLOG" \
    "a value with an apostrophe was not shell-quoted"
  export_line=$(grep -n "export MTG_ORACLE_ROOT" "$SENDLOG" | head -1 | cut -d: -f1)
  launch_line=$(grep -n "codex" "$SENDLOG" | head -1 | cut -d: -f1)
  [ -n "$launch_line" ] || fail "no launch command was sent"
  [ "$export_line" -lt "$launch_line" ] || fail "the export (line $export_line) landed after the launch (line $launch_line)"
  assert_grep "env_file=$env_file" "$HOME_DIR/state/$id.meta" \
    "meta did not record the env file the pane was launched with"
  pass "--env-file exports every variable, shell-quoted, before the launch command"
}

test_env_file_refuses_a_malformed_line() {
  local rec id out status env_file
  id=envfile-malformed-z2
  rec=$(make_case malformed "$id")
  read_case "$rec"
  env_file="$CASE_DIR/arm.env"
  printf 'GOOD=1\nnot an assignment\n' > "$env_file"

  out=$(run_spawn "$id" --env-file "$env_file")
  status=$?
  [ "$status" -ne 0 ] || fail "a malformed env file must refuse the spawn: $out"
  assert_contains "$out" "not an assignment" "the refusal must name the offending line"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn left task metadata behind"
  assert_no_grep codex "$SENDLOG" "a launch was sent despite the malformed env file"
  pass "--env-file refuses a malformed line before any endpoint exists"
}

test_env_file_refuses_firstmate_owned_names() {
  local rec id out status env_file
  id=envfile-owned-z3
  rec=$(make_case owned "$id")
  read_case "$rec"
  env_file="$CASE_DIR/arm.env"
  printf 'FM_HOME=/elsewhere\n' > "$env_file"

  out=$(run_spawn "$id" --env-file "$env_file")
  status=$?
  [ "$status" -ne 0 ] || fail "an env file naming FM_HOME must refuse the spawn: $out"
  assert_contains "$out" "FM_HOME" "the refusal must name the owned variable"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn left task metadata behind"
  pass "--env-file refuses firstmate-owned variable names"
}

test_env_file_exports_land_before_the_launch
test_env_file_refuses_a_malformed_line
test_env_file_refuses_firstmate_owned_names

echo "# all fm-spawn-env-file tests passed"
