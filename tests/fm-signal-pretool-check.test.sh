#!/usr/bin/env bash
# Behavior tests for the crew signal guard (docs/signal-guard.md).
#
# The guard is a crew/scout PreToolUse check that denies a shell command which
# would signal a process the session cannot prove it started. These tests run
# the real transport (bin/fm-signal-pretool-check.sh) and policy owner
# (bin/fm-signal-command-policy.mjs) against real process trees: a fake agent
# process carries the session's process-scope marker exactly as fm-spawn
# launches a crew agent, and every verified target is a real live process.
# The wiring tests run the real fm-spawn against a fake tmux pane and drive the
# generated Claude settings, OpenCode plugin, and Pi extension.
#
# No test here sends a signal to anything it did not start itself, and none
# touches a Herdr session.
#
# Single quotes are deliberate throughout: the commands under test are literal
# shell text for the guard to classify, and agent bodies expand only inside the
# fake agent shell.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-signal-pretool-check.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-signal-pretool-check)
TOKEN="fm-signal-test.$$.$RANDOM"
SPAWNED_PIDS="$TMP_ROOT/spawned.pids"
: > "$SPAWNED_PIDS"
export CHECK TOKEN TMP_ROOT SPAWNED_PIDS
unset FM_PROC_SCOPE

# Stop only the sleepers this suite started and recorded, then remove fixtures.
signal_test_cleanup() {
  local pid
  if [ -f "$SPAWNED_PIDS" ]; then
    while IFS= read -r pid; do
      case "$pid" in ''|*[!0-9]*) continue ;; esac
      kill "$pid" 2>/dev/null || true
    done < "$SPAWNED_PIDS"
  fi
  fm_test_cleanup
}
trap signal_test_cleanup EXIT

# The exact command a crew ran on 2026-11-20 before the shared terminal server
# and the user service manager went down: it signalled the PARENT of every
# process whose command line matched a pattern.
INCIDENT_COMMAND=$(cat <<'CMD'
ps -eo pid,ppid,cmd | grep "landing-ui-t102/recheck" | grep -v grep | grep python3 | awk '{print $1, $2}' | while read p pp; do kill $pp $p; done; sleep 3; ps -eo pid,cmd | grep "landing-ui-t102/recheck" | grep -v grep; mv work/landing-ui-t102/recheck work/landing-ui-t102/recheck-attempt4-queued 2>/dev/null; mv work/landing-ui-t102/recheck.log work/landing-ui-t102/recheck-attempt4-queued.log; git log --oneline -1 fm/ds2-build-persist-t72; git log --oneline 7fe361004..fm/ds2-build-persist-t72 | wc -l; git merge --no-ff --no-edit fm/ds2-build-persist-t72 2>&1 | tail -2; git status --short | grep -v "^??" | grep -E "^(U.|.U|AA|DD)"
CMD
)

# check <command>: run the checker in CLI mode from the current shell and print
# "<exit> <deny-code>" (the code is empty on allow). Inside in_agent the current
# shell is the fake agent, so the checker runs as that agent's descendant.
check() {
  local err rc code
  err=$("$CHECK" --scope "$TOKEN" --command "$1" 2>&1 >/dev/null)
  rc=$?
  code=$(printf '%s' "$err" | sed -n 's/.*"systemMessage":"\[\([a-z-]*\)\].*/\1/p')
  printf '%s %s\n' "$rc" "$code"
}
export -f check

# in_agent <body>: run <body> in a fake agent process carrying the session's
# process-scope marker, the way fm-spawn prefixes FM_PROC_SCOPE onto a crew's
# launch. The trailing `true` keeps bash from exec'ing the last command, so the
# agent stays the parent of everything the body starts.
in_agent() {
  env FM_PROC_SCOPE="$TOKEN" bash -c "$1"$'\n'"true"
}

# record_pid <pid>: remember a sleeper this suite started so cleanup stops it.
record_pid() {
  printf '%s\n' "$1" >> "$SPAWNED_PIDS"
}
export -f record_pid

expect_line() {  # <actual-line> <expected> <message>
  [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"
}

line() {  # <text> <n>
  printf '%s\n' "$1" | sed -n "${2}p"
}

test_incident_command_is_denied() {
  local payload err out rc
  payload=$(jq -cn --arg c "$INCIDENT_COMMAND" '{tool_name:"Bash",tool_input:{command:$c},cwd:"/tmp"}')
  err="$TMP_ROOT/incident.err"
  out=$(printf '%s' "$payload" | "$CHECK" --claude --scope "$TOKEN" 2>"$err")
  rc=$?
  expect_code 2 "$rc" "the exact incident command must be denied through the Claude transport"
  [ -z "$out" ] || fail "--claude must keep stdout empty on deny, got: $out"
  grep -q '"permissionDecision":"deny"' "$err" || fail "deny must carry a PreToolUse deny object: $(cat "$err")"
  grep -q '\[signal-unprovable-target\]' "$err" || fail "incident deny must name the unprovable target: $(cat "$err")"
  grep -q 'parent' "$err" || fail "deny must explain the parent-PID hazard: $(cat "$err")"
  grep -q '\$!' "$err" || fail "deny must say how to signal safely: $(cat "$err")"
  expect_line "$(check "$INCIDENT_COMMAND")" "2 signal-unprovable-target" "the incident command must be denied through the CLI transport"
  pass "the exact incident command (signal the parent of every pattern match) is denied with a safe alternative"
}

test_own_process_stop_is_allowed() {
  local out
  out=$(in_agent '
    sleep 120 >/dev/null 2>&1 & own=$!; record_pid "$own"
    check "kill $own"
    check "kill -TERM $own"
    check "sleep 120 & pid=\$!; kill \$pid"
    check "sleep 120 & kill \"\$!\""
    check "sleep 120 & kill %1"
    check "sleep 120 & kill \$(jobs -p)"
    printf "%s\n" "$own" > "$TMP_ROOT/own.pid"
    check "kill \"\$(cat $TMP_ROOT/own.pid)\""
    check "kill \$(< $TMP_ROOT/own.pid)"
    kill "$own"
  ')
  expect_line "$(line "$out" 1)" "0 " "a literal PID the session launched must be allowed"
  expect_line "$(line "$out" 2)" "0 " "an explicit signal to the session's own PID must be allowed"
  expect_line "$(line "$out" 3)" "0 " "a variable assigned from \$! must be allowed"
  expect_line "$(line "$out" 4)" "0 " "\$! itself must be allowed"
  expect_line "$(line "$out" 5)" "0 " "a job spec must be allowed"
  expect_line "$(line "$out" 6)" "0 " "\$(jobs -p) must be allowed"
  expect_line "$(line "$out" 7)" "0 " "a PID file naming the session's own process must be allowed"
  expect_line "$(line "$out" 8)" "0 " "a \$(< file) PID file read must be allowed"
  pass "stopping a process the session launched and recorded stays allowed"
}

test_orphaned_own_job_is_allowed_by_marker() {
  local out
  # A background job outlives the tool call that started it: its shell exits,
  # the kernel reparents it outside the agent's tree, and only the inherited
  # process-scope marker still ties it to this session.
  out=$(in_agent '
    ( sleep 120 >/dev/null 2>&1 & echo $! > "$TMP_ROOT/orphan.pid" )
    orphan=$(cat "$TMP_ROOT/orphan.pid"); record_pid "$orphan"
    ( env -u FM_PROC_SCOPE sleep 120 >/dev/null 2>&1 & echo $! > "$TMP_ROOT/foreign-orphan.pid" )
    foreign=$(cat "$TMP_ROOT/foreign-orphan.pid"); record_pid "$foreign"
    i=0
    while [ "$i" -lt 50 ]; do
      p=$(ps -o ppid= -p "$orphan" | tr -d " ")
      [ -n "$p" ] && [ "$p" != "$$" ] && break
      sleep 0.1; i=$((i + 1))
    done
    printf "ppid %s self %s\n" "$(ps -o ppid= -p "$orphan" | tr -d " ")" "$$"
    check "kill $orphan"
    check "kill \"\$(cat $TMP_ROOT/orphan.pid)\""
    check "kill $foreign"
  ')
  [ "$(line "$out" 1 | awk '{print $2}')" != "$(line "$out" 1 | awk '{print $4}')" ] \
    || fail "the orphan must be reparented away from the agent so only its marker ties it to the session: $(line "$out" 1)"
  expect_line "$(line "$out" 2)" "0 " "an orphaned job carrying the session marker must be allowed"
  expect_line "$(line "$out" 3)" "0 " "a PID file naming an orphaned own job must be allowed"
  expect_line "$(line "$out" 4)" "2 signal-outside-session" "an orphan without the session marker must be denied"
  pass "an orphaned background job is still recognized as the session's own by its marker"
}

test_descendant_without_marker_is_allowed() {
  local out
  out=$(in_agent '
    env -u FM_PROC_SCOPE sleep 120 >/dev/null 2>&1 & child=$!; record_pid "$child"
    check "kill $child"
    kill "$child"
  ')
  expect_line "$out" "0 " "a live descendant of the agent must be allowed even when its marker was stripped"
  pass "a live descendant of the agent is allowed by ancestry alone"
}

test_ancestors_and_unrelated_processes_are_denied() {
  local out unrelated
  sleep 120 >/dev/null 2>&1 & unrelated=$!
  record_pid "$unrelated"
  out=$(UNRELATED=$unrelated in_agent '
    check "kill $$"
    check "kill $PPID"
    check "kill -9 1"
    check "kill $UNRELATED"
    check "kill 999999999"
  ')
  expect_line "$(line "$out" 1)" "2 signal-outside-session" "the agent itself must be denied"
  expect_line "$(line "$out" 2)" "2 signal-outside-session" "the agent's parent must be denied"
  expect_line "$(line "$out" 3)" "2 signal-outside-session" "PID 1 must be denied"
  expect_line "$(line "$out" 4)" "2 signal-outside-session" "an unrelated process must be denied"
  expect_line "$(line "$out" 5)" "2 signal-outside-session" "a PID that does not exist must be denied"
  kill "$unrelated" 2>/dev/null || true
  pass "a literal PID outside the session's own tree - an ancestor or a stranger - is denied"
}

test_process_groups() {
  local out
  command -v setsid >/dev/null 2>&1 || { pass "skip: setsid not found for the process-group case"; return 0; }
  out=$(in_agent '
    setsid sleep 120 >/dev/null 2>&1 & own=$!; record_pid "$own"
    i=0
    while [ "$i" -lt 50 ]; do
      [ "$(ps -o pgid= -p "$own" | tr -d " ")" = "$own" ] && break
      sleep 0.1; i=$((i + 1))
    done
    check "kill -- -$own"
    check "kill -TERM -$own"
    check "kill -- -$(ps -o pgid= -p $$ | tr -d " ")"
    kill "$own"
  ')
  expect_line "$(line "$out" 1)" "0 " "a process group made only of the session's own processes must be allowed"
  expect_line "$(line "$out" 2)" "0 " "a signalled own process group must be allowed"
  expect_line "$(line "$out" 3)" "2 signal-outside-session" "a process group containing the agent must be denied"
  pass "process-group signals are allowed only when every member is the session's own"
}

test_selection_by_name_or_pattern_is_denied() {
  local cmd
  for cmd in \
    'pkill -f "scripts/test.py"' \
    'pkill python3' \
    'killall node' \
    '/usr/bin/killall -9 herdr' \
    'nice -n 5 pkill -f x' \
    'sudo pkill x' \
    'fuser -k 8080/tcp' \
    'fuser -km /mnt/data' \
    'skill -KILL fungiman' \
    'killall5 -15'; do
    expect_line "$(check "$cmd")" "2 signal-by-name" "selection by name must be denied: $cmd"
  done
  pass "pkill, killall, skill, killall5, and fuser -k are denied because they select targets by name"
}

test_runtime_derived_targets_are_denied() {
  local cmd
  for cmd in \
    'kill $(pgrep -f "landing/recheck")' \
    'kill `pidof python3`' \
    'kill $PPID' \
    'kill -9 "$PPID"' \
    'pid=$(pgrep x); kill $pid' \
    'pid=$!; pid=$PPID; kill $pid' \
    'ps -eo pid,cmd | grep x | awk "{print \$1}" | xargs kill' \
    'pgrep x | xargs -r kill -9' \
    'for p in $(pgrep x); do kill $p; done' \
    'pgrep x | while read p; do kill "$p"; done' \
    'find /tmp -name "*.pid" -exec kill {} \;' \
    'kill $(ps -o ppid= -p $$)' \
    'bash -c "kill \$PPID"' \
    'sh -c '"'"'kill $(pgrep y)'"'"'' \
    'trap "kill \$PPID" EXIT' \
    '(kill $PPID)' \
    'echo $(kill $PPID)' \
    'if true; then kill $PPID; fi' \
    'timeout 5 kill $PPID' \
    'env FOO=1 kill $PPID' \
    'kill -s TERM $target' \
    '/bin/kill python3'; do
    expect_line "$(check "$cmd")" "2 signal-unprovable-target" "a run-time-derived target must be denied: $cmd"
  done
  pass "targets from pattern searches, parent PIDs, stdin, loops, and other substitutions are denied wherever the signal hides"
}

test_broadcast_targets_are_denied() {
  expect_line "$(check 'kill -9 -1')" "2 signal-broadcast" "kill -1 must be denied"
  expect_line "$(check 'kill -- -1')" "2 signal-broadcast" "kill -- -1 must be denied"
  expect_line "$(check 'kill 0')" "2 signal-broadcast" "kill 0 must be denied"
  pass "signals to every process (-1) or to the caller's own process group (0) are denied"
}

test_harmless_forms_are_allowed() {
  local cmd
  for cmd in \
    'echo "kill 1"' \
    'git commit -m "pkill and killall are now denied"' \
    'grep -n kill bin/fm-spawn.sh' \
    'kill -0 1' \
    'while kill -0 $PPID 2>/dev/null; do sleep 1; done' \
    'kill -s 0 $(pgrep x)' \
    'kill -l' \
    'kill -l 9' \
    'command -v kill' \
    'type pkill' \
    'timeout -s KILL 5 sleep 1' \
    'ls -la' \
    'cat <<EOF
kill $PPID
EOF'; do
    expect_line "$(check "$cmd")" "0 " "a command that sends no unproven signal must be allowed: $cmd"
  done
  pass "probes, signal listings, and kill mentioned as data are allowed"
}

test_unparseable_signal_command_is_denied() {
  expect_line "$(check 'case x in y) kill $PPID;; esac')" "2 signal-unclassifiable" "an unparseable command mentioning kill must be denied"
  expect_line "$(check 'echo "unterminated kill')" "2 signal-unclassifiable" "malformed quoting around kill must be denied"
  pass "a command that mentions a signal tool but cannot be parsed is denied rather than guessed"
}

test_missing_scope_marker() {
  local out own
  sleep 120 >/dev/null 2>&1 & own=$!
  record_pid "$own"
  out=$(env -u FM_PROC_SCOPE bash -c '
    sleep 120 >/dev/null 2>&1 & child=$!; record_pid "$child"
    err=$("$CHECK" --command "kill $child" 2>&1 >/dev/null); echo "rc=$?"
    printf "%s\n" "$err" | grep -o "\[signal-no-scope\]"
    "$CHECK" --command "sleep 1 & kill \$!" >/dev/null 2>&1; echo "rc=$?"
    "$CHECK" --scope "fm-other.1" --command "kill $child" >/dev/null 2>&1; echo "rc=$?"
    kill "$child"
    true
  ')
  expect_line "$(line "$out" 1)" "rc=2" "a literal PID must be denied when no scope marker is available"
  expect_line "$(line "$out" 2)" "[signal-no-scope]" "the deny must name the missing scope"
  expect_line "$(line "$out" 3)" "rc=0" "\$! must still be allowed without a scope marker"
  expect_line "$(line "$out" 4)" "rc=2" "a scope token no ancestor carries must not verify anything"
  kill "$own" 2>/dev/null || true
  pass "without this session's marker among its ancestors, only same-command child forms are allowed"
}

test_transport_contract() {
  local out err rc payload
  out=$("$CHECK" --scope "$TOKEN" --command 'ls -la' 2>"$TMP_ROOT/allow.err")
  rc=$?
  expect_code 0 "$rc" "allow must exit 0"
  [ -z "$out" ] && [ ! -s "$TMP_ROOT/allow.err" ] || fail "allow must print nothing"

  out=$("$CHECK" --scope "$TOKEN" --command 'pkill x' 2>"$TMP_ROOT/deny.err")
  rc=$?
  expect_code 2 "$rc" "deny must exit 2"
  printf '%s' "$out" | jq -e '.decision == "deny" and (.reason | startswith("[signal-by-name]"))' >/dev/null \
    || fail "default deny must print a decision object on stdout, got: $out"
  jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$TMP_ROOT/deny.err" >/dev/null \
    || fail "deny must print a PreToolUse deny object on stderr: $(cat "$TMP_ROOT/deny.err")"

  payload=$(jq -cn '{toolInput:{command:"killall herdr"}}')
  out=$(printf '%s' "$payload" | "$CHECK" --scope "$TOKEN" 2>/dev/null)
  rc=$?
  expect_code 2 "$rc" "a Grok-shaped stdin payload must be classified"

  out=$(printf 'not json' | "$CHECK" --claude --scope "$TOKEN" 2>&1)
  rc=$?
  expect_code 0 "$rc" "an unparseable transport payload carries no command and must not block"

  out=$(: | "$CHECK" --claude 2>&1)
  rc=$?
  expect_code 0 "$rc" "an empty payload must not block"
  pass "transport: silent allow, exit-2 deny objects for Claude and Grok shapes, and no block without a command"
}

test_missing_runtime_fails_closed_for_signals_only() {
  local nonode tool rc err
  nonode="$TMP_ROOT/nonode"
  mkdir -p "$nonode"
  for tool in bash sh cat dirname sed tr jq printf; do
    if command -v "$tool" >/dev/null 2>&1 && [ "$(type -t "$tool")" = file ]; then
      ln -sf "$(command -v "$tool")" "$nonode/$tool"
    fi
  done
  PATH="$nonode" "$CHECK" --scope "$TOKEN" --command 'ls -la' >/dev/null 2>&1
  rc=$?
  expect_code 0 "$rc" "a command with no signal tool must never be blocked by a missing runtime"
  err=$(PATH="$nonode" "$CHECK" --scope "$TOKEN" --command 'kill 12345' 2>&1 >/dev/null)
  rc=$?
  expect_code 2 "$rc" "a signal the guard cannot verify must be denied when its runtime is missing"
  case "$err" in *"[signal-unverifiable]"*) ;; *) fail "the deny must name the unverifiable check: $err" ;; esac
  pass "a missing policy runtime denies only commands that send a signal"
}


test_review_regressions() {
  local cmd action out n
  for cmd in \
    'bash -c "kill $(pgrep -f service)"' \
    'bash -c "kill $target"' \
    'bash <<< "kill $(pgrep service)"' \
    'eval "kill $(pgrep service)"' \
    'trap "kill $(pgrep service)" EXIT' \
    'env -S "kill $(pgrep service)"' \
    'env -S"kill $(pgrep service)"' \
    'env --split-string "kill $(pgrep service)"' \
    'env --split-string="kill $(pgrep service)"' \
    'env -S "nice $(echo kill) $(pgrep service)"' \
    'env -S "kill $(pgrep service)" nice true'; do
    expect_line "$(check "$cmd")" "2 signal-unprovable-target" "expanded executable text must be denied: $cmd"
  done
  for cmd in \
    "bash -c 'sleep 1 & kill \$!'" \
    "bash <<< 'sleep 1 & kill \$!'" \
    "eval 'sleep 1 & kill \$!'" \
    "trap 'kill -0 1' EXIT" \
    "nice env -S 'kill -0 1'"; do
    expect_line "$(check "$cmd")" "0 " "literal safe payload must remain allowed: $cmd"
  done
  for action in -exec -execdir -ok -okdir; do
    cmd="find . -name '*.pid' $action sh -c 'kill \$(cat \"\$1\")' sh {} \\;"
    expect_line "$(check "$cmd")" "2 signal-unprovable-target" "find shell payload must recurse: $action"
    cmd="find . $action nice env FOO=1 sh -c 'kill \$PPID' sh {} +"
    expect_line "$(check "$cmd")" "2 signal-unprovable-target" "find wrappers must recurse: $action"
    expect_line "$(check "find . $action kill {} \\;")" "2 signal-unprovable-target" "find operands must remain unprovable"
    expect_line "$(check "find . $action sh -c 'kill -0 1' \\;")" "0 " "find harmless nested probe must pass"
  done
  for cmd in \
    $'cat <<EOF\n$(kill $PPID)\nEOF' \
    $'cat <<EOF\n\'$(kill $PPID)\'\nEOF' \
    $'cat <<-EOF\n\t$(kill "$PPID")\n\tEOF' \
    $'cat <<EOF\n`kill $PPID`\nEOF' \
    $'cat 3<<EOF\n$(kill $PPID)\nEOF'; do
    expect_line "$(check "$cmd")" "2 signal-unprovable-target" "unquoted heredoc substitutions execute for any consumer"
  done
  for cmd in \
    $'cat <<\'EOF\'\n$(kill $PPID)\nEOF' \
    $'cat <<"EOF"\n$(kill $PPID)\nEOF' \
    $'cat <<\\EOF\n$(kill $PPID)\nEOF' \
    $'cat <<EOF\n\\$(kill $PPID)\nEOF'; do
    expect_line "$(check "$cmd")" "0 " "literal heredoc data must remain allowed"
  done
  expect_line "$(check $'sh <<\'EOF\'\nkill $PPID\nEOF')" "2 signal-unprovable-target" "quoted shell heredocs still execute as programs"
  out=$(in_agent '
    sleep 120 >/dev/null 2>&1 & own=$!; record_pid "$own"
    mkdir -p "$TMP_ROOT/path-case/other"
    printf "%s\n" "$own" > "$TMP_ROOT/path-case/job.pid"
    printf "%s\n" "$$" > "$TMP_ROOT/path-case/other/job.pid"
    cd "$TMP_ROOT/path-case" || exit 1
    check "cd other && kill \"\$(cat job.pid)\""
    check "cd other && kill \$(< job.pid)"
    check "env -C other kill \"\$(cat job.pid)\""
    check "sh -c '\''cd other; kill \"\$(cat job.pid)\"'\''"
    check "kill \"\$(cat '\''~/job.pid'\'')\""
    check "kill \$(< \"~/job.pid\")"
    check "cd other && kill \"\$(cat $TMP_ROOT/path-case/job.pid)\""
    HOME="$TMP_ROOT/path-case" check "kill \"\$(cat ~/job.pid)\""
    HOME="$TMP_ROOT/path-case" check "kill \$(< ~/job.pid)"
    check "/usr/bin/kill --timeout 1000 KILL --signal 0 $$"
    check "/usr/bin/kill --timeout=1000 KILL --signal=0 $$"
    check "/usr/bin/kill --signal 0 --timeout 1000 KILL $own"
    check "/usr/bin/kill --signal 0 $$"
    check "/usr/bin/kill --signal 0 $$ --timeout 1000 KILL"
    kill "$own"
  ')
  for n in 1 2 3 4 5 6; do
    expect_line "$(line "$out" "$n")" "2 signal-unprovable-target" "relative and quoted tilde PID paths must be unprovable"
  done
  for n in 7 8 9 12 13; do
    expect_line "$(line "$out" "$n")" "0 " "absolute own PID files, unquoted tilde, owned scheduled sends, and ordinary probes remain allowed"
  done
  for n in 10 11; do
    expect_line "$(line "$out" "$n")" "2 signal-outside-session" "scheduled sends must verify targets even with initial signal zero"
  done
  expect_line "$(line "$out" 14)" "2 signal-unprovable-target" "a delayed signal after operands must also disable the probe exemption"
  pass "expanded payloads, nested execution, PID paths, and scheduled signals obey the allow rule"
}


test_shell_modes_split_arguments_and_pidfile_conflicts() {
  local cmd action out n
  for cmd in \
    "bash -o pipefail -c 'kill \$(pgrep -f service)'" \
    "bash +o pipefail -c 'kill \$PPID'" \
    "bash -O extglob -c 'kill \$PPID'" \
    "bash +O extglob -c 'kill \$PPID'" \
    "bash -eo pipefail -c 'kill \$PPID'" \
    "bash -co pipefail 'kill \$PPID'" \
    "bash -c -o pipefail 'kill \$PPID'" \
    "bash -c -- 'kill \$PPID'" \
    "bash -o pipefail <<< 'kill \$PPID'" \
    $'bash -o pipefail <<\'EOF\'\nkill $PPID\nEOF' \
    "bash -o <<< 'kill 1'" \
    "env -S 'bash -o pipefail' <<< 'kill \$PPID'" \
    "bash --unknown-option 'kill \$PPID'" \
    "bash -o \"\$option\" -c 'kill \$PPID'"; do
    expect_line "$(check "$cmd")" "2 signal-unprovable-target" "shell option parsing must not conceal sends: $cmd"
  done
  for action in -exec -execdir -ok -okdir; do
    cmd="find . $action nice bash -o pipefail -c 'kill \$PPID' \\;"
    expect_line "$(check "$cmd")" "2 signal-unprovable-target" "find shell mode must be resolved: $action"
  done
  for cmd in \
    "bash -o pipefail -c 'sleep 1 & kill \$!'" \
    "bash -eo pipefail -c 'kill -0 1'" \
    "bash -co pipefail 'kill -0 1'" \
    "bash -c -o pipefail 'kill -0 1'" \
    "bash -c -- 'kill -0 1'" \
    "bash +O extglob <<< 'kill -0 1'" \
    "bash -s argument <<< 'kill -0 1'"; do
    expect_line "$(check "$cmd")" "0 " "resolved safe shell payload must stay allowed: $cmd"
  done
  out=$(in_agent '
    sleep 120 >/dev/null 2>&1 & own=$!; record_pid "$own"
    for prefix in "env -S" "command env -S" "env --split-string" "env --split-string=" "nice env -S" "env FOO=1 env -S"; do
      case "$prefix" in
        *"=") check "$prefix\"kill -TERM\" $$" ;;
        *) check "$prefix '\''kill -TERM'\'' $$" ;;
      esac
    done
    check "env -S'\''kill -TERM'\'' $$"
    check "env -S '\''nice kill -TERM'\'' $$"
    check "env -S '\''kill'\'' -TERM $$"
    check "env -S '\''kill -TERM'\'' $own"
    check "env -S '\''kill -0'\'' $$"
    check "env -S '\''bash -c \"kill 1\"'\''"
    printf "%s\n" "$own" > "$TMP_ROOT/review.pid"
    cd "$TMP_ROOT" || exit 1
    check "pgrep -f service > $TMP_ROOT/review.pid; kill \$(cat $TMP_ROOT/review.pid)"
    check "pgrep -f service > $TMP_ROOT/review.pid; kill \$(< $TMP_ROOT/review.pid)"
    check "tee $TMP_ROOT/./review.pid; kill \$(cat $TMP_ROOT/review.pid)"
    check "kill \$(cat $TMP_ROOT/review.pid); cp other.pid ./review.pid"
    check "sh -c '\''printf 1 > $TMP_ROOT/review.pid'\''; kill \$(cat $TMP_ROOT/review.pid)"
    check "echo \$(cat $TMP_ROOT/review.pid); kill \$(cat $TMP_ROOT/review.pid)"
    check "kill \$(cat $TMP_ROOT/review.pid)"
    check "kill \$(< $TMP_ROOT/review.pid)"
    check "echo unrelated.pid; kill \$(cat $TMP_ROOT/review.pid)"
    check "sh -o pipefail -c '\''kill \$(cat $TMP_ROOT/review.pid)'\''"
    kill "$own"
  ')
  for n in 1 2 3 4 5 6 7 8 9; do
    expect_line "$(line "$out" "$n")" "2 signal-outside-session" "env split arguments must reach target verification"
  done
  for n in 10 11 19 20 21 22; do
    expect_line "$(line "$out" "$n")" "0 " "owned targets and isolated PID-file reads must remain allowed"
  done
  for n in 12 13 14 15 16 17 18; do
    expect_line "$(line "$out" "$n")" "2 signal-unprovable-target" "uncertain split syntax and repeated PID paths must fail closed"
  done
  pass "shell modes, env split arguments, and PID-file conflicts are checked"
}


test_conservative_pid_records_and_env_signal_options() {
  local option suffix cmd binding out n
  for option in --default-signal --block-signal --ignore-signal; do
    for suffix in '' '=TERM'; do
      expect_line "$(check "env $option$suffix pkill -f service")" "2 signal-by-name" "env signal option must preserve the following command"
      expect_line "$(check "nice env $option$suffix kill \$PPID")" "2 signal-unprovable-target" "env signal option must preserve literal kill"
      expect_line "$(check "env $option$suffix kill -0 1")" "0 " "env signal option must preserve harmless probes"
    done
  done
  for cmd in \
    'sleep 30 & pid=$!; env pid="$PPID" sh -c '\''kill "$pid"'\''' \
    'pid=$!; sudo pid=1 sh -c '\''kill "$pid"'\''' \
    'pid=$!; sh -c '\''pid=$PPID; kill "$pid"'\''' \
    'pid=$!; eval '\''pid=1; kill "$pid"'\''' \
    'pid=$!; trap '\''pid=1; kill "$pid"'\'' EXIT' \
    'pid=$!; env -S '\''pid=1 kill'\'' "$pid"' \
    'pid=$!; pid+=$!; kill $pid' \
    'pid=$!; pid="$!"123; kill $pid' \
    'pid=$!; pid="$!"'\''123'\''; kill $pid' \
    'echo "pid=$!"; kill $pid'; do
    expect_line "$(check "$cmd")" "2 signal-unprovable-target" "every raw assignment must prove the child PID: $cmd"
  done
  for binding in \
    'read pid' 'for pid in 1; do true; done' 'select pid in 1; do true; done' \
    'mapfile pid' 'readarray pid' 'getopts x pid' 'let pid++' \
    'printf -v pid %s 1' 'printf -vpid %s 1' \
    'declare pid' 'declare pid=$!' 'local pid' 'export pid' 'typeset pid' 'readonly pid'; do
    expect_line "$(check "pid=\$!; $binding; kill \$pid")" "2 signal-unprovable-target" "binding commands invalidate child PID variables: $binding"
  done
  for cmd in \
    'sleep 1 & pid=$!; kill "$pid"' \
    'sleep 1 & pid=${!}; kill "$pid"' \
    'sleep 1 & pid="$!"; kill "$pid"' \
    'sleep 1 & pid="${!}"; kill "$pid"' \
    'sleep 1 & pid=$!; pid=$!; kill "$pid"' \
    'sh -c '\''sleep 1 & pid=$!; kill "$pid"'\'''; do
    expect_line "$(check "$cmd")" "0 " "plain child PID records remain allowed: $cmd"
  done
  out=$(in_agent '
    sleep 120 >/dev/null 2>&1 & own=$!; record_pid "$own"
    mkdir -p "$TMP_ROOT/basename-case"
    printf "%s\n" "$own" > "$TMP_ROOT/basename-case/job.pid"
    check "cd $TMP_ROOT/basename-case; pgrep -f service > job.pid; kill \$(cat $TMP_ROOT/basename-case/job.pid)"
    check "cd $TMP_ROOT/basename-case; pgrep -f service > job.pid; kill \$(< $TMP_ROOT/basename-case/job.pid)"
    check "env -C $TMP_ROOT/basename-case sh -c '\''tee job.pid'\''; kill \$(cat $TMP_ROOT/basename-case/job.pid)"
    check "sh -c '\''cd $TMP_ROOT/basename-case; cp other.pid job.pid'\''; kill \$(< $TMP_ROOT/basename-case/job.pid)"
    check "mv other.pid elsewhere/job.pid; kill \$(cat $TMP_ROOT/basename-case/job.pid)"
    check "echo job.pid; kill \$(cat $TMP_ROOT/basename-case/job.pid)"
    check "kill \$(cat $TMP_ROOT/basename-case/job.pid)"
    check "kill \$(< $TMP_ROOT/basename-case/job.pid)"
    kill "$own"
  ')
  for n in 1 2 3 4 5 6; do
    expect_line "$(line "$out" "$n")" "2 signal-unprovable-target" "any repeated raw PID-file basename must deny"
  done
  for n in 7 8; do
    expect_line "$(line "$out" "$n")" "0 " "single PID-file reads remain verified and allowed"
  done
  pass "basename uniqueness, raw PID assignments, and env optional signal arguments are enforced"
}


test_implicit_bindings_and_jobs_output() {
  local cmd binding
  for binding in 'read' 'read -r' 'read -p prompt' 'read -t 1'; do
    expect_line "$(check "sleep 30 & REPLY=\$!; $binding <<< \"\$PPID\"; kill \"\$REPLY\"")" "2 signal-unprovable-target" "implicit REPLY binding must invalidate a child PID"
  done
  for binding in 'mapfile' 'readarray' 'mapfile -t' 'readarray -n 1'; do
    expect_line "$(check "sleep 30 & MAPFILE=\$!; $binding <<< \"\$PPID\"; kill \"\$MAPFILE\"")" "2 signal-unprovable-target" "implicit MAPFILE binding must invalidate a child PID"
  done
  for cmd in 'jobs' 'jobs -l' 'jobs -pl' 'jobs -n' 'jobs -x' 'jobs -r'; do
    expect_line "$(check "sleep 12345 & kill \$($cmd)")" "2 signal-unprovable-target" "only PID-only jobs output may qualify"
  done
  for cmd in 'jobs -p' 'jobs -pr' 'jobs -p -s' 'jobs -r -p' 'jobs -p %1' 'jobs -ps %+ %-'; do
    expect_line "$(check "sleep 12345 & kill \$($cmd)")" "0 " "PID-only jobs output must remain allowed"
  done
  pass "implicit bindings invalidate child PID variables and jobs accepts only PID output"
}

test_unreadable_payload_fails_closed() {
  local nojq tool mode payload err rc
  local -a mode_flags
  nojq="$TMP_ROOT/nojq"
  mkdir -p "$nojq"
  for tool in bash cat sed tr; do
    ln -s "$(command -v "$tool")" "$nojq/$tool"
  done
  for mode in '' '--claude'; do
    mode_flags=()
    [ -z "$mode" ] || mode_flags=("$mode")
    for payload in '{"tool_input":{"command":"kill 123"}}' '{"toolInput":{"command":"fuser -k 80/tcp"}}' 'malformed kill 123'; do
      err=$(printf '%s' "$payload" | PATH="$nojq" "$CHECK" "${mode_flags[@]}" 2>&1)
      rc=$?
      expect_code 2 "$rc" "missing jq with signalling payload must deny"
      case "$err" in *signal-unverifiable*) ;; *) fail "missing jq must explain the unavailable check: $err" ;; esac
    done
    err=$(printf '%s' 'malformed fuser' | "$CHECK" "${mode_flags[@]}" 2>&1)
    expect_code 2 $? "malformed signalling payload must deny even with jq"
    case "$err" in *signal-unverifiable*) ;; *) fail "malformed payload must explain the unavailable check" ;; esac
    printf '%s' '{"tool_input":{"command":"ls"}}' | PATH="$nojq" "$CHECK" "${mode_flags[@]}" >/dev/null 2>&1
    expect_code 0 $? "missing jq must not block a nonsignalling payload"
  done
  pass "missing jq and malformed signalling payloads fail closed on both stdin transports"
}

# --- fm-spawn wiring ---------------------------------------------------------

make_spawn_fakebin() {
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
  fm_fake_exit0 "$fakebin" pi opencode claude codex
  fm_fake_treehouse_lease "$fakebin"
  printf '%s\n' "$fakebin"
}

# spawn_case <name> <harness> <id>: run the real fm-spawn for one ship task and
# set HOME_DIR, WT_DIR, and SENDLOG for the generated wiring.
spawn_case() {
  local name=$1 harness=$2 id=$3 case_dir proj fakebin out
  case_dir="$TMP_ROOT/$name"
  HOME_DIR="$case_dir/home"
  proj="$case_dir/project"
  WT_DIR="$case_dir/wt"
  SENDLOG="$case_dir/pane-send-log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$HOME_DIR/data/$id" "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config"
  printf '%s\n' "$harness" > "$HOME_DIR/config/crew-harness"
  fm_git_worktree "$proj" "$WT_DIR" "wt-$name"
  touch "$HOME_DIR/state/.last-watcher-beat"
  printf 'brief for %s\n' "$id" > "$HOME_DIR/data/$id/brief.md"
  fm_test_backlog_queue "$HOME_DIR" "$id"
  : > "$SENDLOG"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_SENDLOG="$SENDLOG" TMUX="fake,1,0" \
    GROK_HOME="$HOME_DIR/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off 2>&1)
  expect_code 0 $? "$harness spawn should succeed: $out"
}

# launch_scope: the FM_PROC_SCOPE value fm-spawn placed on the launch line.
launch_scope() {
  grep -o "FM_PROC_SCOPE=[^ ]*" "$SENDLOG" | head -1 | sed -e "s/^FM_PROC_SCOPE=//" -e "s/^'//" -e "s/'\$//"
}

test_claude_spawn_installs_the_guard() {
  local settings hook scope payload rc own_out broken_hook checker mode cmd out
  spawn_case claude-wiring claude sig-claude-1
  settings="$WT_DIR/.claude/settings.local.json"
  [ -f "$settings" ] || fail "claude spawn must write $settings"
  hook=$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command' "$settings")
  jq -e '.hooks.Stop and .hooks.UserPromptSubmit' "$settings" >/dev/null || fail "the busy-state hooks must stay in place"
  scope=$(launch_scope)
  [ -n "$scope" ] || fail "the launch line must carry FM_PROC_SCOPE: $(cat "$SENDLOG")"
  case "$scope" in sig-claude-1.*) ;; *) fail "the scope token must name the task: $scope" ;; esac
  case "$hook" in *"$scope"*) ;; *) fail "the hook must verify against the launch's scope token $scope: $hook" ;; esac

  payload=$(jq -cn --arg c "$INCIDENT_COMMAND" '{tool_name:"Bash",tool_input:{command:$c}}')
  printf '%s' "$payload" | sh -c "$hook" >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "the installed Claude hook must deny the incident command"

  own_out=$(HOOK=$hook env FM_PROC_SCOPE="$scope" bash -c '
    sleep 120 >/dev/null 2>&1 & own=$!; record_pid "$own"
    jq -cn --arg c "kill $own" "{tool_name:\"Bash\",tool_input:{command:\$c}}" | sh -c "$HOOK" >/dev/null 2>&1; echo "rc=$?"
    kill "$own"
    true
  ')
  expect_line "$own_out" "rc=0" "the installed Claude hook must allow stopping the agent's own process under the launch's marker"
  checker="$TMP_ROOT/failed-checker"
  for mode in missing nonexecutable 1 3 143; do
    rm -f "$checker"
    if [ "$mode" != missing ]; then
      printf '#!/bin/sh\nexit %s\n' "${mode/nonexecutable/1}" > "$checker"
      [ "$mode" = nonexecutable ] || chmod +x "$checker"
    fi
    broken_hook=${hook//"$CHECK"/"$checker"}
    for cmd in 'kill 12345' 'k"il"l 12345' 'fu\ser -k 12345' "\$'\\153ill' 12345" '$"kill" 12345' 'echo ordinary'; do
      payload=$(jq -cn --arg c "$cmd" '{tool_input:{command:$c}}')
      out=$(printf '%s' "$payload" | sh -c "$broken_hook" 2>"$TMP_ROOT/hook.err")
      rc=$?
      if [ "$cmd" = 'echo ordinary' ]; then
        expect_code 0 "$rc" "unavailable Claude transport must allow ordinary payloads ($mode)"
      else
        expect_code 2 "$rc" "unavailable Claude transport must block signal payloads ($mode): $cmd"
        [ -z "$out" ] || fail "Claude fallback deny must keep stdout empty"
        jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.systemMessage | contains("[signal-unverifiable]"))' "$TMP_ROOT/hook.err" >/dev/null || fail "Claude fallback must emit a structured unverifiable denial"
      fi
    done
  done
  pass "claude crew spawn installs the signal guard with a scope token matching the launch marker"
}

test_opencode_spawn_installs_the_guard() {
  local plugin out
  spawn_case opencode-wiring opencode sig-oc-1
  plugin="$WT_DIR/.opencode/plugins/fm-busy-state.js"
  [ -f "$plugin" ] || fail "opencode spawn must write $plugin"
  out=$(PLUGIN="$plugin" CMD_DENY="$INCIDENT_COMMAND" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const factory = Object.values(mod).find((value) => typeof value === "function");
const hooks = await factory({ directory: process.cwd(), worktree: process.cwd() });
const before = hooks["tool.execute.before"];
if (typeof before !== "function") { console.log("missing"); process.exit(0); }
try {
  await before({ tool: "bash" }, { args: { command: process.env.CMD_DENY } });
  console.log("allowed");
} catch (error) {
  console.log(String(error.message).includes("[signal-unprovable-target]") ? "denied" : `other:${error.message}`);
}
await before({ tool: "bash" }, { args: { command: "ls -la" } });
await before({ tool: "read" }, { args: { command: "pkill x" } });

const childProcess = await import("node:child_process");
const { syncBuiltinESMExports } = await import("node:module");
const realExecFile = childProcess.default.execFile;
for (const failure of ["missing", "exit", "signal", "timeout", "throw"]) {
  childProcess.default.execFile = (file, args, callback) => {
    if (failure === "missing") return realExecFile(process.env.TMP_ROOT + "/absent-checker", args, callback);
    if (failure === "throw") throw new Error("spawn failed");
    callback(failure === "exit" ? { code: 1 } : failure === "timeout" ? { code: "ETIMEDOUT" } : { code: null, signal: "SIGTERM" }, "", "");
  };
  syncBuiltinESMExports();
  for (const command of ["kill 123", "fuser -k 80/tcp", "k\'i\'ll 123", String.fromCharCode(36, 39) + "k\\x69ll\' 123"]) {
    let blocked = false;
    try { await before({ tool: "bash" }, { args: { command } }); }
    catch (error) { blocked = String(error.message).includes("signal-unverifiable"); }
    if (!blocked) throw new Error("checker failure allowed a signal: " + failure);
  }
  await before({ tool: "bash" }, { args: { command: "ls -la" } });
}
childProcess.default.execFile = realExecFile;
syncBuiltinESMExports();

console.log("ok");
EOF
)
  expect_code 0 $? "OpenCode failure-mode checks must pass: $out"
  expect_line "$(line "$out" 1)" "denied" "the OpenCode plugin must throw on the incident command"
  expect_line "$(line "$out" 2)" "ok" "the OpenCode plugin must pass ordinary bash and non-bash tools"
  [ -n "$(launch_scope)" ] || fail "the opencode launch line must carry FM_PROC_SCOPE: $(cat "$SENDLOG")"
  pass "opencode crew spawn installs the signal guard in its per-task plugin"
}

test_pi_spawn_installs_the_guard() {
  local ext out
  spawn_case pi-wiring pi sig-pi-1
  ext="$HOME_DIR/state/sig-pi-1.pi-ext.ts"
  [ -f "$ext" ] || fail "pi spawn must write $ext"
  out=$(EXT="$ext" CMD_DENY="$INCIDENT_COMMAND" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.EXT).href);
const handlers = {};
mod.default({ on: (name, fn) => { handlers[name] = fn; } });
const toolCall = handlers["tool_call"];
if (typeof toolCall !== "function") { console.log("missing"); process.exit(0); }
const denied = await toolCall({ type: "tool_call", toolName: "bash", input: { command: process.env.CMD_DENY } }, {});
console.log(denied && denied.block === true && String(denied.reason).includes("[signal-unprovable-target]") ? "denied" : `other:${JSON.stringify(denied)}`);
const allowed = await toolCall({ type: "tool_call", toolName: "bash", input: { command: "ls -la" } }, {});

const childProcess = await import("node:child_process");
const { syncBuiltinESMExports } = await import("node:module");
const realExecFile = childProcess.default.execFile;
for (const failure of ["missing", "exit", "signal", "timeout", "throw"]) {
  childProcess.default.execFile = (file, args, callback) => {
    if (failure === "missing") return realExecFile(process.env.TMP_ROOT + "/absent-checker", args, callback);
    if (failure === "throw") throw new Error("spawn failed");
    callback(failure === "exit" ? { code: 1 } : failure === "timeout" ? { code: "ETIMEDOUT" } : { code: null, signal: "SIGTERM" }, "", "");
  };
  syncBuiltinESMExports();
  for (const command of ["kill 123", "fuser -k 80/tcp", "k\'i\'ll 123", String.fromCharCode(36, 39) + "k\\x69ll\' 123"]) {
    const result = await toolCall({ type: "tool_call", toolName: "bash", input: { command } }, {});
    if (!result?.block || !String(result.reason).includes("signal-unverifiable")) throw new Error("checker failure allowed a signal: " + failure);
  }
  const ordinary = await toolCall({ type: "tool_call", toolName: "bash", input: { command: "ls -la" } }, {});
  if (ordinary?.block) throw new Error("checker failure blocked ordinary command");
}
childProcess.default.execFile = realExecFile;
syncBuiltinESMExports();

console.log(allowed && allowed.block ? "blocked" : "ok");
EOF
)
  expect_code 0 $? "Pi failure-mode checks must pass: $out"
  expect_line "$(line "$out" 1)" "denied" "the Pi extension must block the incident command"
  expect_line "$(line "$out" 2)" "ok" "the Pi extension must pass an ordinary bash command"
  [ -n "$(launch_scope)" ] || fail "the pi launch line must carry FM_PROC_SCOPE: $(cat "$SENDLOG")"
  pass "pi crew spawn installs the signal guard in its per-task extension"
}

test_implicit_bindings_and_jobs_output
test_unreadable_payload_fails_closed
test_conservative_pid_records_and_env_signal_options
test_shell_modes_split_arguments_and_pidfile_conflicts
test_review_regressions

test_incident_command_is_denied
test_own_process_stop_is_allowed
test_orphaned_own_job_is_allowed_by_marker
test_descendant_without_marker_is_allowed
test_ancestors_and_unrelated_processes_are_denied
test_process_groups
test_selection_by_name_or_pattern_is_denied
test_runtime_derived_targets_are_denied
test_broadcast_targets_are_denied
test_harmless_forms_are_allowed
test_unparseable_signal_command_is_denied
test_missing_scope_marker
test_transport_contract
test_missing_runtime_fails_closed_for_signals_only
test_claude_spawn_installs_the_guard
test_opencode_spawn_installs_the_guard
test_pi_spawn_installs_the_guard
