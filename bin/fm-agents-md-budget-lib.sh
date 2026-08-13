# shellcheck shell=bash
# AGENTS.md budget primitives built on the startup-memory budget contract.
# Usage: source bin/fm-startup-memory-budget-lib.sh, then source this file.

FM_AGENTS_MD_BUDGET_FILE="agents-md-budget"
FM_AGENTS_MD_BUDGET_DEFAULT="25000"
FM_AGENTS_MD_BUDGET_ERROR=""
FM_AGENTS_MD_BUDGET_VALUE=""

fm_agents_md_budget_call_shared() {
  local saved_file=$FM_STARTUP_MEMORY_BUDGET_FILE
  local saved_default=$FM_STARTUP_MEMORY_BUDGET_DEFAULT
  local saved_error=$FM_STARTUP_MEMORY_BUDGET_ERROR
  local saved_value=$FM_STARTUP_MEMORY_BUDGET_VALUE
  local rc
  FM_STARTUP_MEMORY_BUDGET_FILE=$FM_AGENTS_MD_BUDGET_FILE
  FM_STARTUP_MEMORY_BUDGET_DEFAULT=$FM_AGENTS_MD_BUDGET_DEFAULT
  if "$@"; then
    rc=0
  else
    rc=$?
  fi
  FM_AGENTS_MD_BUDGET_ERROR=$FM_STARTUP_MEMORY_BUDGET_ERROR
  FM_AGENTS_MD_BUDGET_VALUE=$FM_STARTUP_MEMORY_BUDGET_VALUE
  FM_STARTUP_MEMORY_BUDGET_FILE=$saved_file
  FM_STARTUP_MEMORY_BUDGET_DEFAULT=$saved_default
  FM_STARTUP_MEMORY_BUDGET_ERROR=$saved_error
  FM_STARTUP_MEMORY_BUDGET_VALUE=$saved_value
  return "$rc"
}

fm_agents_md_budget_read() {
  fm_agents_md_budget_call_shared fm_startup_memory_budget_read "$1"
}

fm_agents_md_budget_materialize() {
  fm_agents_md_budget_call_shared fm_startup_memory_budget_materialize "$1"
}
