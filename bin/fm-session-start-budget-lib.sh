# shellcheck shell=bash
# Session-start briefing budget primitives built on the startup-memory contract.
# Usage: source bin/fm-startup-memory-budget-lib.sh, then source this file.

FM_SESSION_START_BUDGET_FILE="session-start-budget"
FM_SESSION_START_BUDGET_DEFAULT="20000"
FM_SESSION_START_BUDGET_ERROR=""
FM_SESSION_START_BUDGET_VALUE=""

fm_session_start_budget_call_shared() {
  local saved_file=$FM_STARTUP_MEMORY_BUDGET_FILE
  local saved_default=$FM_STARTUP_MEMORY_BUDGET_DEFAULT
  local saved_error=$FM_STARTUP_MEMORY_BUDGET_ERROR
  local saved_value=$FM_STARTUP_MEMORY_BUDGET_VALUE
  local rc
  FM_STARTUP_MEMORY_BUDGET_FILE=$FM_SESSION_START_BUDGET_FILE
  FM_STARTUP_MEMORY_BUDGET_DEFAULT=$FM_SESSION_START_BUDGET_DEFAULT
  if "$@"; then
    rc=0
  else
    rc=$?
  fi
  # shellcheck disable=SC2034 # Public result consumed by callers after sourcing.
  FM_SESSION_START_BUDGET_ERROR=$FM_STARTUP_MEMORY_BUDGET_ERROR
  # shellcheck disable=SC2034 # Public result consumed by callers after sourcing.
  FM_SESSION_START_BUDGET_VALUE=$FM_STARTUP_MEMORY_BUDGET_VALUE
  FM_STARTUP_MEMORY_BUDGET_FILE=$saved_file
  FM_STARTUP_MEMORY_BUDGET_DEFAULT=$saved_default
  FM_STARTUP_MEMORY_BUDGET_ERROR=$saved_error
  FM_STARTUP_MEMORY_BUDGET_VALUE=$saved_value
  return "$rc"
}

fm_session_start_budget_read() {
  fm_session_start_budget_call_shared fm_startup_memory_budget_read "$1"
}

fm_session_start_budget_materialize() {
  fm_session_start_budget_call_shared fm_startup_memory_budget_materialize "$1"
}
