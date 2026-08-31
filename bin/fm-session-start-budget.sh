#!/usr/bin/env bash
# Read and account for the local session-start briefing budget.
# Usage:
#   fm-session-start-budget.sh read
#   fm-session-start-budget.sh report <captured-briefing-file>
#
# `read` prints the validated effective config/session-start-budget value.
# `report` measures one captured briefing with the shared conservative estimator.
# Bootstrap owns default materialization; this command never creates or repairs
# configuration, and it refuses absent or non-ordinary briefing captures.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-startup-memory-budget-lib.sh
. "$SCRIPT_DIR/fm-startup-memory-budget-lib.sh"
# shellcheck source=bin/fm-session-start-budget-lib.sh
. "$SCRIPT_DIR/fm-session-start-budget-lib.sh"

usage() {
  sed -n '2,11{s/^# \{0,1\}//;p;}' "$0"
}

print_error() {
  printf 'session-start-budget: %s\n' "$1" >&2
}

read_budget() {
  if ! fm_session_start_budget_read "$CONFIG" >/dev/null; then
    print_error "invalid config/$FM_SESSION_START_BUDGET_FILE - $FM_SESSION_START_BUDGET_ERROR"
    return 1
  fi
  printf '%s\n' "$FM_SESSION_START_BUDGET_VALUE"
}

report() {
  local briefing=$1 budget bytes tokens additional_bytes total_bytes total_tokens label
  if ! budget=$(read_budget); then
    return 2
  fi
  if [ ! -e "$briefing" ] && [ ! -L "$briefing" ]; then
    print_error "briefing file is absent: $briefing"
    return 2
  fi
  if [ -L "$briefing" ] || [ ! -f "$briefing" ]; then
    print_error "briefing file is not an ordinary regular file: $briefing"
    return 2
  fi
  if ! fm_startup_memory_measure_file "$briefing" >/dev/null; then
    print_error "$FM_STARTUP_MEMORY_BUDGET_ERROR"
    return 2
  fi
  bytes=$FM_STARTUP_MEMORY_MEASURE_BYTES
  tokens=$FM_STARTUP_MEMORY_MEASURE_TOKENS
  additional_bytes=${FM_SESSION_START_BUDGET_ADDITIONAL_BYTES:-0}
  case "$additional_bytes" in
    ''|*[!0-9]*)
      print_error "invalid additional-byte accounting value: $additional_bytes"
      return 2
      ;;
  esac
  total_bytes=$((bytes + additional_bytes))
  if ! total_tokens=$(fm_startup_memory_estimated_tokens_for_bytes "$total_bytes"); then
    print_error "could not estimate the complete briefing"
    return 2
  fi
  printf 'estimator=ceil(UTF-8 bytes / 3) conservative-local-estimate\n'
  printf 'effective_budget_tokens=%s\n' "$budget"
  label=${FM_SESSION_START_BUDGET_LABEL:-}
  if [ -n "$label" ]; then
    printf 'surface=%s bytes=%s estimated_tokens=%s status=present\n' \
      "$label" "$bytes" "$tokens"
  else
    printf 'file=%s bytes=%s estimated_tokens=%s status=present\n' \
      "$briefing" "$bytes" "$tokens"
  fi
  printf 'accounted_additional_bytes=%s\n' "$additional_bytes"
  printf 'total_bytes=%s\n' "$total_bytes"
  printf 'total_estimated_tokens=%s\n' "$total_tokens"
  if fm_startup_memory_decimal_le "$total_tokens" "$budget"; then
    printf 'budget_status=within-budget\n'
  else
    printf 'budget_status=over-budget\n'
    printf 'budget_overage_tokens=%s\n' "$((total_tokens - budget))"
    printf 'budget_remedy=trim fleet detail or raise config/%s above %s estimated tokens\n' \
      "$FM_SESSION_START_BUDGET_FILE" "$total_tokens"
  fi
}

case "${1:-}" in
  read)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    read_budget
    ;;
  report)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    report "$2"
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
