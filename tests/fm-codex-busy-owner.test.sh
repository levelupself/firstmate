#!/usr/bin/env bash
# tests/fm-codex-busy-owner.test.sh - real-process proof that the codex
# rollout busy source (bin/fm-busy-lib.sh) binds an open turn bracket to a
# live agent process.
#
# It runs a REAL process in a REAL tmux server on a private socket (`-L`) and
# needs no harness and no credentials, so it runs everywhere CI runs tmux. The
# hermetic fold matrix that serves the liveness verdict from a stub is
# tests/fm-codex-harness.test.sh; the tmux classifier itself is pinned by
# tests/fm-tmux-agent-liveness.test.sh; the live per-harness counterpart is
# tests/fm-codex-busy-live-e2e.test.sh.
#
# The defect it exists for: after a host reboot every codex worker died
# mid-turn, each rollout ended on an open task_started with no close, and the
# fold kept reporting busy for panes that were bare shells, so parked tasks read
# working and the watcher wedge-escalated them every few minutes. An open
# bracket is proof of a turn only while the backend can attribute a live agent
# to the pane.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
SLEEP_BIN=$(command -v sleep) || { echo "skip: sleep not found"; exit 0; }

REAL_TMUX=$(command -v tmux)
SOCKET="fm-codex-owner-$$"
LAB=$(fm_test_tmproot fm-codex-owner)
SESSION=owner

cleanup_server() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup_server EXIT

# A `tmux` shim on PATH so bin/backends/tmux.sh's bare `tmux` calls reach the
# private socket and never touch the host's real sessions.
mkdir -p "$LAB/shim" "$LAB/bin" "$LAB/wt" "$LAB/state" "$LAB/sessions/2026/09/11"
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"
PATH="$LAB/shim:$PATH"
export PATH

# A stand-in harness binary: a SYMLINK to a real long-running system binary
# (a copied platform binary fails code-signing validation on macOS arm64). The
# symlink name is what the kernel records as the executable identity, which is
# the signal the liveness classifier reads.
ln -s "$SLEEP_BIN" "$LAB/bin/codex-link"

# shellcheck source=bin/fm-backend.sh
# shellcheck disable=SC1091
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=bin/fm-busy-lib.sh
# shellcheck disable=SC1091
. "$ROOT/bin/fm-busy-lib.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

# The rollout this pane owns: an interactive session whose cwd is the worktree,
# holding one open turn, plus the sidecar fm-spawn writes.
ROLLOUT="$LAB/sessions/2026/09/11/rollout-2026-09-11T04-04-22-s-owner.jsonl"
{
  printf '{"timestamp":"2026-09-11T04:04:22.000Z","type":"session_meta","payload":'
  printf '{"session_id":"s-owner","cwd":"%s","originator":"codex-tui","source":"cli","cli_version":"0.153.4"}}\n' "$LAB/wt"
  printf '{"timestamp":"2026-09-11T04:04:23.000Z","type":"event_msg","payload":{"type":"task_started"}}\n'
} > "$ROLLOUT"
printf 'sessions_root=%s\nworkspace_root=%s\n' "$LAB/sessions" "$LAB/wt" > "$LAB/state/task.codex-session"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n idle -c "$LAB/wt" \
  || fail "could not start the private tmux server"

# The worker window runs the harness-named process in its foreground group and
# drops to a plain interactive shell when that process dies - the exact shape a
# rebooted or killed worker leaves behind.
"$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n worker -c "$LAB/wt" -- \
  bash -c "'$LAB/bin/codex-link' 900 & printf '%s\n' \"\$!\" > '$LAB/agent.pid'; wait; exec /bin/sh" \
  || fail "could not create the worker window"
TARGET="$SESSION:worker"

wait_for_agent_state() {  # <expected> [tries]
  local expected=$1 tries=${2:-100} got i=0
  while [ "$i" -lt "$tries" ]; do
    got=$(fm_backend_agent_state tmux "$TARGET")
    [ "$got" = "$expected" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  printf 'last agent state for %s was %s (expected %s)\n' "$TARGET" "${got:-<none>}" "$expected" >&2
  return 1
}

# --- an open bracket with a live owner stays busy ---------------------------
wait_for_agent_state alive \
  || fail "precondition: the harness-named foreground process must classify alive"
out=$(fm_busy_classify tmux "$TARGET" codex task "$LAB/state")
[ "$out" = "busy codex-rollout" ] \
  || fail "an open turn whose owner is a live process must stay busy, got '$out'"
pass "codex owner binding: an open bracket with a live agent process classifies busy"

# --- the same bracket with its owner gone folds to not-busy ------------------
agent_pid=$(cat "$LAB/agent.pid" 2>/dev/null || true)
[ -n "$agent_pid" ] || fail "the worker window did not record its agent pid"
kill "$agent_pid" 2>/dev/null || fail "could not stop the stand-in agent process"
wait_for_agent_state dead \
  || fail "precondition: the pane left behind must classify as an agent-free shell"
[ "$(fm_busy_codex_turn_state "$ROLLOUT")" = busy ] \
  || fail "precondition: the rollout itself must still hold the open bracket"
out=$(fm_busy_classify tmux "$TARGET" codex task "$LAB/state")
[ "$out" = "idle codex-owner-gone" ] \
  || fail "an open turn whose owner is gone must fold to not-busy, got '$out'"
fm_busy_is_busy tmux "$TARGET" codex task "$LAB/state" \
  && fail "fm_busy_is_busy must not report an orphaned open turn as busy"
pass "codex owner binding: the same open bracket folds to not-busy once its process is gone"

# --- an interrupt still closes a live turn through the log -------------------
printf '{"timestamp":"2026-09-11T04:05:00.000Z","type":"event_msg","payload":{"type":"turn_aborted"}}\n' >> "$ROLLOUT"
out=$(fm_busy_classify tmux "$TARGET" codex task "$LAB/state")
[ "$out" = "idle codex-rollout" ] \
  || fail "a turn closed by turn_aborted must read idle from the rollout, got '$out'"
pass "codex owner binding: a turn_aborted close still settles the turn from the rollout alone"
