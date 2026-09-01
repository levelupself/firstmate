#!/usr/bin/env bash
# Tests for bounded foreground watcher checkpoints used by Codex supervision.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-checkpoint)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

test_quiet_checkpoint_exits_124_cleanly() {
  local home out err status
  home=$(make_home quiet)
  out="$home/out.txt"
  err="$home/err.txt"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "quiet checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 1s" "quiet checkpoint line missing"
  assert_absent "$home/state/.watch.lock/pid" "watch lock pid survived quiet checkpoint timeout"
  pass "quiet checkpoint exits 124 with a clean checkpoint line and no live lock"
}

test_signal_passes_through_and_exits_zero() {
  local home out err status drained
  home=$(make_home signal)
  out="$home/out.txt"
  err="$home/err.txt"
  (
    sleep 1
    printf 'done: synthetic wake\n' > "$home/state/demo.status"
  ) &
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 8 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "signal checkpoint exit"
  assert_contains "$(cat "$out")" "signal:" "signal wake was not passed through"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" $'\tsignal\tdemo.status\t' "signal wake was not queued durably"
  pass "checkpoint passes through a real watcher wake and leaves the queue for drain"
}

test_registered_check_uses_preserved_watcher_environment() {
  local home out err status
  home=$(make_home check-env)
  out="$home/out.txt"
  err="$home/err.txt"
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$home/state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$home/state/.pr-check-migration-v1"
  chmod 0600 "$home/state/.pr-check-migration-scan-v1" "$home/state/.pr-check-migration-v1"
  cat > "$home/state/env-check.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'env check fired with FM_CHECK_INTERVAL=%s\n' "${FM_CHECK_INTERVAL:-missing}"
SH
  chmod 0700 "$home/state/env-check.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" env-check >/dev/null \
    || fail "could not register checkpoint custom check"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "check checkpoint exit"
  assert_contains "$(cat "$out")" "check:" "check wake was not passed through"
  assert_contains "$(cat "$out")" "FM_CHECK_INTERVAL=1" "watcher environment was not preserved"
  pass "checkpoint preserves watcher environment for registered custom checks"
}

test_existing_singleton_watcher_is_not_success() {
  local home out err status
  home=$(make_home singleton)
  out="$home/out.txt"
  err="$home/err.txt"
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$home/state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$home/state/.pr-check-migration-v1"
  chmod 0600 "$home/state/.pr-check-migration-scan-v1" "$home/state/.pr-check-migration-v1"
  mkdir "$home/state/.watch.lock"
  printf '%s\n' "$$" > "$home/state/.watch.lock/pid"
  status=0
  FM_HOME="$home" FM_GUARD_GRACE=300 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "singleton checkpoint exit"
  assert_contains "$(cat "$out")" "watcher: already running" "singleton watcher output was not passed through"
  assert_contains "$(cat "$err")" "outside this foreground checkpoint" "singleton watcher failure was not explained"
  pass "checkpoint rejects an existing watcher singleton as unowned"
}

test_term_during_nested_command_substitution_runs_cleanup() {
  local home state fakebin out err trigger pid status i proc_stat real_cut
  home=$(make_home term-cleanup)
  state="$home/state"
  fakebin="$home/fakebin"
  out="$home/out.txt"
  err="$home/err.txt"
  trigger="$home/signal-on-backend-cut"
  real_cut=$(command -v cut)
  mkdir -p "$fakebin"
  cat > "$fakebin/cut" <<'SH'
#!/usr/bin/env bash
set -u
input=$(cat)
case "$input" in
  backend=*)
    if [ -e "$FM_SIGNAL_TRIGGER" ]; then
      rm -f "$FM_SIGNAL_TRIGGER"
      watcher_pid=$(cat "$FM_STATE_OVERRIDE/.watch.lock/pid")
      kill -TERM "$watcher_pid"
    fi
    ;;
esac
printf '%s\n' "$input" | "$FM_REAL_CUT" "$@"
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  capture-pane) printf 'fresh pane output\n'; exit 0 ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/cut" "$fakebin/tmux"
  printf 'window=test:fm-term-cleanup\nbackend=tmux\nkind=ship\n' > "$state/term-cleanup.meta"
  : > "$trigger"

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_SIGNAL_TRIGGER="$trigger" FM_REAL_CUT="$real_cut" FM_POLL=5 \
    FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$out" 2> "$err" &
  pid=$!

  i=0
  while [ "$i" -lt 50 ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    proc_stat=$(ps -p "$pid" -o stat= 2>/dev/null || true)
    case "$proc_stat" in Z*) break ;; esac
    sleep 0.1
    i=$((i + 1))
  done
  if [ "$i" -eq 50 ]; then
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "watcher survived TERM during nested command substitution: $(cat "$err")"
  fi
  status=0
  wait "$pid" || status=$?

  [ "$status" -eq 143 ] \
    || fail "TERM cleanup watcher exit: expected 143, got $status: $(cat "$err")"
  [ ! -s "$err" ] || fail "TERM cleanup printed a shell diagnostic: $(cat "$err")"
  assert_absent "$state/.watch.lock/pid" "watch lock pid survived TERM cleanup"
  assert_contains "$(cat "$state/.watcher-down" 2>/dev/null || true)" \
    "pending:downtime:" "TERM cleanup did not publish watcher downtime"
  pass "TERM during nested command substitution exits through watcher cleanup"
}

test_quiet_checkpoint_exits_124_cleanly
test_signal_passes_through_and_exits_zero
test_registered_check_uses_preserved_watcher_environment
test_existing_singleton_watcher_is_not_success
test_term_during_nested_command_substitution_runs_cleanup
