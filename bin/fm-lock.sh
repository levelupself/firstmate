#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the harness (agent) process PID found by walking the shell's ancestry,
# which lives as long as the firstmate session - unlike the transient subshell
# PID of any one tool call, which is dead moments after it is written.
# Usage: fm-lock.sh           acquire; exit 1 for a live conflict, 2 when
#                             process identity cannot be determined safely
#        fm-lock.sh status    print holder and liveness; always exits 0
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
mkdir -p "$STATE"
# shellcheck source=bin/fm-process-lib.sh
. "$SCRIPT_DIR/fm-process-lib.sh"

# Known harness command names; extend when a new adapter is verified.
HARNESS_RE='claude|codex|opencode|grok|^pi$'

harness_pid() {
  local pid=$$ comm args
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(fm_process_comm "$pid") || return 1
    args=$(fm_process_args "$pid" 2>/dev/null || true)
    if printf '%s' "$(basename "$comm")" | grep -qE "$HARNESS_RE"; then
      echo "$pid"; return 0
    fi
    # Bare interpreter (e.g. node): match the harness name in its script path.
    case "$comm" in
      *node*|*python*) printf '%s' "$args" | grep -qE "$HARNESS_RE" && { echo "$pid"; return 0; } ;;
    esac
    pid=$(fm_process_ppid "$pid") || return 1
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

holder_alive() {  # 0=live harness, 1=stale/not harness, 2=identity unavailable
  local pid=$1 comm
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(fm_process_comm "$pid") || { fm_process_is_cygwin_ps && return 2; return 1; }
  printf '%s' "$(basename "$comm") $(fm_process_args "$pid" 2>/dev/null || true)" | grep -qE "$HARNESS_RE"
}

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(cat "$LOCK")
  holder_alive "$old"
  holder_rc=$?
  case "$holder_rc" in
    0) echo "lock: held by live harness pid $old" ;;
    2) echo "lock: liveness unknown (Cygwin process table cannot identify pid $old)" ;;
    *) echo "lock: stale (pid $old dead or not a harness)" ;;
  esac
  exit 0
fi

me=$(harness_pid)
harness_rc=$?
if [ "$harness_rc" -ne 0 ]; then
  echo "error: cannot determine harness identity from process ancestry" >&2
  exit 2
fi
if [ -f "$LOCK" ]; then
  old=$(cat "$LOCK")
  if [ "$old" != "$me" ]; then
    holder_alive "$old"
    holder_rc=$?
    if [ "$holder_rc" -eq 0 ]; then
      echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved" >&2
      exit 1
    elif [ "$holder_rc" -eq 2 ]; then
      echo "error: cannot determine whether lock holder pid $old is live: Cygwin process identity is unavailable" >&2
      exit 2
    fi
  fi
fi
echo "$me" > "$LOCK"
echo "lock acquired: harness pid $me"
