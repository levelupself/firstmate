#!/usr/bin/env bash
# Portable process inspection for procps/POSIX ps and Cygwin ps 3.x.

fm_process_is_cygwin_ps() {
  if [ -z "${FM_PROCESS_PS_FLAVOR:-}" ]; then
    case "$(ps --version 2>&1 || true)" in
      *[Cc]ygwin*) FM_PROCESS_PS_FLAVOR=cygwin ;;
      *) FM_PROCESS_PS_FLAVOR=formatted ;;
    esac
  fi
  [ "$FM_PROCESS_PS_FLAVOR" = cygwin ]
}

fm_process_cygwin_row() {  # <l|f> <pid>
  local format=$1 pid=$2 pid_field=1
  [ "$format" = f ] && pid_field=2
  LC_ALL=C ps "-$format" -p "$pid" 2>/dev/null \
    | awk -v pid="$pid" -v field="$pid_field" 'NR > 1 && $field == pid { print; exit }'
}

fm_process_comm() {
  local pid=$1 row
  if fm_process_is_cygwin_ps; then
    row=$(fm_process_cygwin_row l "$pid") || return 1
    [ -n "$row" ] || return 1
    printf '%s\n' "$row" | awk '{ print $8 }'
  else
    ps -o comm= -p "$pid" 2>/dev/null
  fi
}

fm_process_args() {
  local pid=$1 row
  if fm_process_is_cygwin_ps; then
    row=$(fm_process_cygwin_row f "$pid") || return 1
    [ -n "$row" ] || return 1
    printf '%s\n' "$row" | awk '{ for (i = 6; i <= NF; i++) printf "%s%s", (i == 6 ? "" : " "), $i; print "" }'
  else
    ps -o args= -p "$pid" 2>/dev/null
  fi
}

fm_process_ppid() {
  local pid=$1 row
  if fm_process_is_cygwin_ps; then
    row=$(fm_process_cygwin_row l "$pid") || return 1
    [ -n "$row" ] || return 1
    printf '%s\n' "$row" | awk '{ print $2 }'
  else
    ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]'
  fi
}

fm_process_identity() {
  local pid=$1 row args winpid stime out
  if fm_process_is_cygwin_ps; then
    row=$(fm_process_cygwin_row l "$pid") || return 1
    [ -n "$row" ] || return 1
    winpid=$(printf '%s\n' "$row" | awk '{ print $4 }')
    stime=$(printf '%s\n' "$row" | awk '{ print $7 }')
    args=$(fm_process_args "$pid") || return 1
    [ -n "$winpid" ] && [ -n "$stime" ] && [ -n "$args" ] || return 1
    printf 'cygwin:%s:%s:%s:%s\n' "$pid" "$winpid" "$stime" "$args"
  else
    out=$(LC_ALL=C ps -p "$pid" -o lstart= -o command= 2>/dev/null) || return 1
    [ -n "$out" ] || return 1
    printf '%s\n' "$out" | sed 's/^[[:space:]]*//'
  fi
}
