#!/usr/bin/env bash
# Own guarded backlog lifecycle writes and repair interrupted lifecycle edges.
# Usage: fm-backlog-integrity.sh check-start <id>
#        fm-backlog-integrity.sh start <id>
#        fm-backlog-integrity.sh done <id> [--pr <url>|--report <path>|--note <text>]
#        fm-backlog-integrity.sh failed <id>
#        fm-backlog-integrity.sh reconcile
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME=${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
DATA=${FM_DATA_OVERRIDE:-$FM_HOME/data}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}

# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

fail() { printf 'fm-backlog-integrity: %s\n' "$*" >&2; exit 1; }
tasks_axi() { (cd "$FM_HOME" && tasks-axi "$@"); }

backend_enabled() {
  [ -f "$DATA/backlog.md" ] || return 1
  fm_tasks_axi_backend_available "$CONFIG"
}

show_field() {
  printf '%s\n' "$1" | sed -n "s/^  $2: //p" | head -1
}

guarded_start() {
  local id=$1 show state
  backend_enabled || return 0
  show=$(tasks_axi show "$id" --full 2>/dev/null) || fail "task $id is absent from the backlog"
  state=$(show_field "$show" state)
  case "$state" in
    done) fail "refusing to start completed task $id" ;;
    in_flight) return 0 ;;
    queued) tasks_axi start "$id" >/dev/null || fail "could not start task $id" ;;
    *) fail "refusing to start task $id from state $state" ;;
  esac
}

check_start() {
  local id=$1 show state
  backend_enabled || return 0
  show=$(tasks_axi show "$id" --full 2>/dev/null) || fail "task $id is absent from the backlog"
  state=$(show_field "$show" state)
  [ "$state" != "done" ] || fail "refusing to start completed task $id"
}

record_done() {
  local id=$1
  shift
  backend_enabled || return 0
  tasks_axi done "$id" "$@" >/dev/null || fail "could not close task $id"
}

record_failed() {
  local id=$1
  backend_enabled || return 0
  # tasks-axi 0.2.x has no failed state. Reopen preserves unfinished work instead
  # of falsely closing it as Done; the terminal status stream remains the owner
  # of the failed outcome until the backlog schema grows a failed state.
  tasks_axi reopen "$id" >/dev/null || fail "could not reopen failed task $id"
}

row_id() {
  local row=$1 id
  id=${row%%,*}
  id=${id// /}
  case "$id" in ''|id|in_flight*|queued*|help*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  printf '%s' "$id"
}

receipt_value() {
  sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1
}

reconcile_orphan() {
  local id=$1 receipt pr report
  [ ! -f "$STATE/$id.meta" ] || return 0
  report="$DATA/$id/report.md"
  if [ -s "$report" ]; then
    tasks_axi done "$id" --report "data/$id/report.md" >/dev/null
    printf 'closed=%s evidence=scout-report\n' "$id"
    return 0
  fi
  receipt="$DATA/pr-merges/$id.receipt"
  if [ "$(receipt_value "$receipt" phase)" = merged ]; then
    pr=$(receipt_value "$receipt" pr)
    [ -n "$pr" ] || fail "merged receipt for $id has no PR URL"
    tasks_axi done "$id" --pr "$pr" >/dev/null
    printf 'closed=%s evidence=merged-pr\n' "$id"
    return 0
  fi
  receipt="$DATA/local-landings/$id.receipt"
  if [ "$(receipt_value "$receipt" phase)" = landed ]; then
    tasks_axi done "$id" --note "local main" >/dev/null
    printf 'closed=%s evidence=local-landing\n' "$id"
    return 0
  fi
  tasks_axi reopen "$id" >/dev/null
  printf 'reopened=%s evidence=work-not-landed\n' "$id"
}

reconcile_blockers() {
  local rows row id show blockers blocker blocker_show blocker_state
  rows=$(tasks_axi list --state queued --fields deps) \
    || fail "could not list queued backlog rows"
  while IFS= read -r row; do
    id=$(row_id "$row") || continue
    show=$(tasks_axi show "$id" --full 2>/dev/null) || continue
    blockers=$(show_field "$show" deps | tr -d '\"' | tr ' ' '\n' \
      | sed -n 's/^blocked-by://p' | paste -sd, -)
    [ -n "$blockers" ] || continue
    while IFS= read -r blocker; do
      [ -n "$blocker" ] || continue
      blocker_show=$(tasks_axi show "$blocker" --full 2>/dev/null || true)
      blocker_state=$(show_field "$blocker_show" state)
      case "$blocker_state" in
        queued|in_flight) ;;
        *)
          tasks_axi unblock "$id" --by "$blocker" >/dev/null \
            || fail "could not clear resolved blocker $blocker from $id"
          printf 'unblocked=%s blocker=%s state=%s\n' "$id" "$blocker" "${blocker_state:-absent}"
          ;;
      esac
    done <<EOF
$(printf '%s\n' "$blockers" | tr ',' '\n')
EOF
  done <<EOF
$rows
EOF
}

reconcile() {
  local rows row id detail='' line decision_repairs
  backend_enabled || { printf 'BACKLOG_INTEGRITY: skipped (tasks-axi backend unavailable)\n'; return 0; }
  rows=$(tasks_axi list --state in_flight) || fail "could not list in-flight backlog rows"
  while IFS= read -r row; do
    id=$(row_id "$row") || continue
    line=$(reconcile_orphan "$id") || exit 1
    [ -z "$line" ] || detail="${detail}${detail:+; }$line"
  done <<EOF
$rows
EOF
  while IFS= read -r line; do
    [ -z "$line" ] || detail="${detail}${detail:+; }$line"
  done <<EOF
$(reconcile_blockers)
EOF
  if [ -x "$SCRIPT_DIR/fm-decision-hold.sh" ]; then
    decision_repairs=$("$SCRIPT_DIR/fm-decision-hold.sh" reconcile-open) \
      || fail "could not reconcile answered decision files"
    while IFS= read -r line; do
      [ -z "$line" ] || detail="${detail}${detail:+; }$line"
    done <<EOF
$decision_repairs
EOF
  fi
  printf 'BACKLOG_INTEGRITY: %s\n' "${detail:-clean}"
}

case "${1:-}" in
  check-start) [ "$#" -eq 2 ] || exit 2; check_start "$2" ;;
  start) [ "$#" -eq 2 ] || exit 2; guarded_start "$2" ;;
  done) [ "$#" -ge 2 ] || exit 2; id=$2; shift 2; record_done "$id" "$@" ;;
  failed) [ "$#" -eq 2 ] || exit 2; record_failed "$2" ;;
  reconcile) [ "$#" -eq 1 ] || exit 2; reconcile ;;
  *) exit 2 ;;
esac
