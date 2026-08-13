#!/usr/bin/env bash
# Read and account for the local AGENTS.md budget.
# Usage:
#   fm-agents-md-budget.sh read
#   fm-agents-md-budget.sh report
#
# `read` prints the validated effective config/agents-md-budget value.
# `report` measures the tracked AGENTS.md with the startup-memory estimator and
# compares it with that visible budget.
# Bootstrap owns default materialization; this command never creates or repairs
# configuration, so an absent or invalid value is a concrete error.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-startup-memory-budget-lib.sh
. "$SCRIPT_DIR/fm-startup-memory-budget-lib.sh"
# shellcheck source=bin/fm-agents-md-budget-lib.sh
. "$SCRIPT_DIR/fm-agents-md-budget-lib.sh"

usage() {
  sed -n '2,10{s/^# \{0,1\}//;p;}' "$0"
}

print_error() {
  printf 'agents-md-budget: %s\n' "$1" >&2
}

read_budget() {
  if ! fm_agents_md_budget_read "$CONFIG" >/dev/null; then
    print_error "invalid config/$FM_AGENTS_MD_BUDGET_FILE - $FM_AGENTS_MD_BUDGET_ERROR"
    return 1
  fi
  printf '%s\n' "$FM_AGENTS_MD_BUDGET_VALUE"
}

report() {
  local budget bytes tokens presence
  if ! budget=$(read_budget); then
    return 2
  fi
  if ! fm_startup_memory_measure_file "$FM_ROOT/AGENTS.md" >/dev/null; then
    print_error "$FM_STARTUP_MEMORY_BUDGET_ERROR"
    return 2
  fi
  bytes=$FM_STARTUP_MEMORY_MEASURE_BYTES
  tokens=$FM_STARTUP_MEMORY_MEASURE_TOKENS
  presence=$FM_STARTUP_MEMORY_MEASURE_PRESENCE
  printf 'estimator=ceil(UTF-8 bytes / 3) conservative-local-estimate\n'
  printf 'effective_budget_tokens=%s\n' "$budget"
  printf 'file=AGENTS.md bytes=%s estimated_tokens=%s status=%s\n' \
    "$bytes" "$tokens" "$presence"
  printf 'total_estimated_tokens=%s\n' "$tokens"
  if fm_startup_memory_decimal_le "$tokens" "$budget"; then
    printf 'budget_status=within-budget\n'
  else
    printf 'budget_status=over-budget\n'
  fi
}

case "${1:-}" in
  read)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    read_budget
    ;;
  report)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    report
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
