#!/usr/bin/env bash
# Own guarded backlog lifecycle writes and repair interrupted lifecycle edges.
# Usage: fm-backlog-integrity.sh check-start <id>
#        fm-backlog-integrity.sh check-row <id> [--allow-absent]
#        fm-backlog-integrity.sh start <id>
#        fm-backlog-integrity.sh done <id> [--pr <url>|--report <path>|--note <text>]
#        fm-backlog-integrity.sh landed <id> <pr-merge|local-merge> [done flags]
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
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

fail() { printf 'fm-backlog-integrity: %s\n' "$*" >&2; exit 1; }
tasks_axi() { (cd "$FM_HOME" && tasks-axi "$@"); }

backend_enabled() {
  fm_tasks_axi_backend_available "$CONFIG"
}

check_row() {
  local id=$1 allow_absent=${2:-} rows
  if [ ! -e "$DATA/backlog.md" ] && [ ! -L "$DATA/backlog.md" ]; then
    [ "$allow_absent" = --allow-absent ] && return 0
    fail "backlog is absent; refusing lifecycle start for $id"
  fi
  [ -f "$DATA/backlog.md" ] && [ ! -L "$DATA/backlog.md" ] \
    || fail "could not verify the backlog record for $id"
  if backend_enabled && tasks_axi show "$id" --full >/dev/null 2>&1; then
    return 0
  fi
  rows=$("$SCRIPT_DIR/fm-backlog-tsv.sh" "$DATA/backlog.md") \
    || fail "could not verify the backlog record for $id"
  printf '%s\n' "$rows" \
    | awk -F '\t' -v id="$id" '$2 == id { found = 1 } END { exit(found ? 0 : 1) }' \
    || fail "task $id is absent from the backlog"
}

show_field() {
  printf '%s\n' "$1" | sed -n "s/^  $2: //p" | head -1
}

guarded_start() {
  local id=$1 show state spawned_at binding tmp transitioned=0
  check_row "$id"
  backend_enabled || return 0
  show=$(tasks_axi show "$id" --full 2>/dev/null) || fail "task $id is absent from the backlog"
  state=$(show_field "$show" state)
  case "$state" in
    done) fail "refusing to start completed task $id" ;;
    queued|in_flight)
      spawned_at=$(sed -n 's/^spawned_at=//p' "$STATE/$id.meta" 2>/dev/null | tail -1)
      valid_timestamp "$spawned_at" || fail "task $id has no valid launch identity"
      if [ "$state" = queued ]; then
        tasks_axi start "$id" >/dev/null || fail "could not start task $id"
        transitioned=1
      fi
      binding="$STATE/$id.launch-receipt"
      if [ -e "$binding" ] || [ -L "$binding" ]; then
        if [ "$transitioned" = 1 ]; then
          rm -f "$binding" 2>/dev/null || true
        fi
        if [ -e "$binding" ] || [ -L "$binding" ]; then
          [ -f "$binding" ] && [ ! -L "$binding" ] \
          && [ "$(grep -c '^schema=fm-task-launch.v1$' "$binding" 2>/dev/null || true)" -eq 1 ] \
          && [ "$(grep -c "^task_id=$id$" "$binding" 2>/dev/null || true)" -eq 1 ] \
          && [ "$(grep -c "^spawned_at=$spawned_at$" "$binding" 2>/dev/null || true)" -eq 1 ] \
          || {
            [ "$transitioned" = 0 ] || tasks_axi reopen "$id" >/dev/null \
              || fail "task $id launch binding conflicted and its start could not be rolled back"
            fail "task $id launch identity conflicts with its durable binding"
          }
        fi
      fi
      if [ ! -e "$binding" ] && [ ! -L "$binding" ]; then
        umask 077
        tmp=$(mktemp "$STATE/.$id.launch-receipt.XXXXXX") || {
          [ "$transitioned" = 0 ] || tasks_axi reopen "$id" >/dev/null \
            || fail "task $id launch binding failed and its start could not be rolled back"
          fail "could not prepare launch binding for $id"
        }
        if ! { printf '%s\n' 'schema=fm-task-launch.v1' "task_id=$id" "spawned_at=$spawned_at" > "$tmp" \
          && chmod 600 "$tmp" && mv "$tmp" "$binding"; }; then
            rm -f "$tmp"
            [ "$transitioned" = 0 ] || tasks_axi reopen "$id" >/dev/null \
              || fail "task $id launch binding failed and its start could not be rolled back"
            fail "could not record launch binding for $id"
        fi
      fi
      ;;
    *) fail "refusing to start task $id from state $state" ;;
  esac
}

check_start() {
  local id=$1 show state
  check_row "$id"
  backend_enabled || return 0
  show=$(tasks_axi show "$id" --full 2>/dev/null) || fail "task $id is absent from the backlog"
  state=$(show_field "$show" state)
  [ "$state" != "done" ] || fail "refusing to start completed task $id"
}

record_done() {
  local id=$1 show state
  shift
  check_row "$id"
  backend_enabled || return 0
  show=$(tasks_axi show "$id" --full 2>/dev/null) || fail "task $id is absent from the backlog"
  state=$(show_field "$show" state)
  [ "$state" != "done" ] || return 0
  tasks_axi "done" "$id" "$@" >/dev/null || fail "could not close task $id"
}

record_landed() {
  local id=$1 context=$2
  shift 2
  if [ ! -f "$DATA/backlog.md" ]; then
    printf 'Backlog: %s for %s proceeded with no backlog present; there was no lifecycle row to update.\n' \
      "$context" "$id"
    return 0
  fi
  record_done "$id" "$@"
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

receipt_has_one() {
  [ "$(grep -c "^$2=" "$1" 2>/dev/null || true)" -eq 1 ]
}

valid_timestamp() {
  printf '%s\n' "$1" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
}

receipt_matches_launch() {
  local receipt=$1 id=$2 spawned_at
  local binding="$STATE/$id.launch-receipt"
  [ -f "$binding" ] && [ ! -L "$binding" ] || return 1
  [ "$(grep -c '^schema=fm-task-launch.v1$' "$binding" 2>/dev/null || true)" -eq 1 ] || return 1
  [ "$(grep -c "^task_id=$id$" "$binding" 2>/dev/null || true)" -eq 1 ] || return 1
  spawned_at=$(receipt_value "$receipt" spawned_at)
  [ "$(grep -c "^spawned_at=$spawned_at$" "$binding" 2>/dev/null || true)" -eq 1 ]
}

valid_pr_receipt() {
  local receipt=$1 id=$2 key schema authorization prepared_epoch merged_at pr project repository receipt_repository forge_default receipt_default merge_commit compare_query compare_status default_query
  [ -f "$receipt" ] && [ ! -L "$receipt" ] || return 1
  for key in schema task_id pr spawned_at phase authorization prepared_epoch; do
    receipt_has_one "$receipt" "$key" || return 1
  done
  schema=$(receipt_value "$receipt" schema)
  [ "$schema" = fm-pr-merge.v3 ] || [ "$schema" = fm-pr-merge.v4 ] || return 1
  for key in repository default_branch merge_commit; do
    receipt_has_one "$receipt" "$key" || return 1
  done
  if [ "$schema" = fm-pr-merge.v4 ]; then
    receipt_has_one "$receipt" project || return 1
    project=$(receipt_value "$receipt" project)
    [ -n "$project" ] || return 1
  fi
  [ "$(receipt_value "$receipt" task_id)" = "$id" ] || return 1
  pr=$(receipt_value "$receipt" pr)
  fm_pr_url_parse "$pr" || return 1
  [ "$FM_PR_PROVIDER" = github ] || return 1
  repository="$FM_PR_OWNER/$FM_PR_REPO"
  valid_timestamp "$(receipt_value "$receipt" spawned_at)" || return 1
  receipt_matches_launch "$receipt" "$id" || return 1
  [ "$(receipt_value "$receipt" phase)" = merged ] || return 1
  authorization=$(receipt_value "$receipt" authorization)
  [ "$authorization" = live-meta ] || [ "$authorization" = done-record ] || return 1
  prepared_epoch=$(receipt_value "$receipt" prepared_epoch)
  case "$prepared_epoch" in ''|*[!0-9]*) return 1 ;; esac
  receipt_has_one "$receipt" merged_at || return 1
  [ "$(grep -c '^merged_epoch=' "$receipt" 2>/dev/null || true)" -eq 0 ] || return 1
  merged_at=$(receipt_value "$receipt" merged_at)
  [ -z "$merged_at" ] || valid_timestamp "$merged_at" || return 1
  receipt_repository=$(receipt_value "$receipt" repository)
  [ "$receipt_repository" = "$repository" ] || return 1
  default_query=$(gh-axi api "/repos/$repository" \
    --jq '{default_branch: .default_branch}' 2>/dev/null) || return 1
  forge_default=$(printf '%s\n' "$default_query" | sed -n 's/^default_branch: \([^[:space:]].*\)$/\1/p' | tail -1)
  git check-ref-format --branch "$forge_default" >/dev/null 2>&1 || return 1
  receipt_default=$(receipt_value "$receipt" default_branch)
  [ "$receipt_default" = "$forge_default" ] || return 1
  merge_commit=$(receipt_value "$receipt" merge_commit)
  printf '%s\n' "$merge_commit" | grep -Eq '^[0-9a-f]{40}$' || return 1
  compare_query=$(gh-axi api "/repos/$repository/compare/$merge_commit...$forge_default" \
    --jq '{status: .status}' 2>/dev/null) || return 1
  compare_status=$(printf '%s\n' "$compare_query" | sed -n 's/^status: \([^[:space:]].*\)$/\1/p' | tail -1)
  [ "$compare_status" = ahead ] || [ "$compare_status" = identical ]
}

valid_local_receipt() {
  local receipt=$1 id=$2 key
  [ -f "$receipt" ] && [ ! -L "$receipt" ] || return 1
  for key in schema task_id spawned_at project branch default_branch before_sha landed_sha phase event_at; do
    receipt_has_one "$receipt" "$key" || return 1
  done
  [ "$(receipt_value "$receipt" schema)" = fm-local-landing.v1 ] || return 1
  [ "$(receipt_value "$receipt" task_id)" = "$id" ] || return 1
  valid_timestamp "$(receipt_value "$receipt" spawned_at)" || return 1
  receipt_matches_launch "$receipt" "$id" || return 1
  [ -n "$(receipt_value "$receipt" project)" ] || return 1
  [ -n "$(receipt_value "$receipt" branch)" ] || return 1
  [ -n "$(receipt_value "$receipt" default_branch)" ] || return 1
  printf '%s\n' "$(receipt_value "$receipt" before_sha)" | grep -Eq '^[0-9a-f]{40,64}$' || return 1
  printf '%s\n' "$(receipt_value "$receipt" landed_sha)" | grep -Eq '^[0-9a-f]{40,64}$' || return 1
  [ "$(receipt_value "$receipt" phase)" = landed ] || return 1
  valid_timestamp "$(receipt_value "$receipt" event_at)"
}

landed_work_evidence() {
  local id=$1 show=$2 kind report receipt project default_branch landed_sha terminal
  LANDED_EVIDENCE=
  kind=$(show_field "$show" kind)
  report="$DATA/$id/report.md"
  terminal=$(grep -E '^(done|failed):' "$STATE/$id.status" 2>/dev/null | tail -1 || true)
  if [ "$kind" = scout ] && [ -s "$report" ] && [ "${terminal%%:*}" = "done" ]; then
    LANDED_EVIDENCE=scout-report
    return 0
  fi
  receipt="$DATA/pr-merges/$id.receipt"
  if valid_pr_receipt "$receipt" "$id"; then
    LANDED_EVIDENCE=merged-pr
    return 0
  fi
  receipt="$DATA/local-landings/$id.receipt"
  if valid_local_receipt "$receipt" "$id"; then
    project=$(receipt_value "$receipt" project)
    default_branch=$(receipt_value "$receipt" default_branch)
    landed_sha=$(receipt_value "$receipt" landed_sha)
    if [ -d "$project" ] \
      && git -C "$project" merge-base --is-ancestor "$landed_sha" "$default_branch" 2>/dev/null; then
      LANDED_EVIDENCE=local-landing
      return 0
    fi
  fi
  return 1
}

reconcile_orphan() {
  local id=$1 receipt pr show
  [ ! -f "$STATE/$id.meta" ] || return 0
  show=$(tasks_axi show "$id" --full 2>/dev/null) || fail "could not read orphan task $id"
  if landed_work_evidence "$id" "$show"; then
    case "$LANDED_EVIDENCE" in
      scout-report) tasks_axi "done" "$id" --report "data/$id/report.md" >/dev/null || fail "could not close orphan scout $id" ;;
      merged-pr)
        receipt="$DATA/pr-merges/$id.receipt"
        pr=$(receipt_value "$receipt" pr)
        tasks_axi "done" "$id" --pr "$pr" >/dev/null || fail "could not close merged orphan $id"
        ;;
      local-landing) tasks_axi "done" "$id" --note "local main" >/dev/null || fail "could not close locally landed orphan $id" ;;
    esac
    printf 'closed=%s evidence=%s\n' "$id" "$LANDED_EVIDENCE"
    return 0
  fi
  tasks_axi reopen "$id" >/dev/null || fail "could not reopen orphan $id"
  printf 'reopened=%s evidence=work-not-landed\n' "$id"
}

reconcile_blockers() {
  local rows row id show blockers blocker blocker_show blocker_error blocker_state
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
      blocker_error=$(mktemp "$STATE/.backlog-blocker-show.XXXXXX") \
        || fail "could not prepare blocker read for $blocker"
      if blocker_show=$(tasks_axi show "$blocker" --full 2>"$blocker_error"); then
        blocker_state=$(show_field "$blocker_show" state)
        rm -f "$blocker_error"
        case "$blocker_state" in
          queued|in_flight) continue ;;
          done) ;;
          *) fail "blocker $blocker has unreadable state" ;;
        esac
      elif { printf '%s\n' "$blocker_show"; cat "$blocker_error"; } | grep -Fq 'code: NOT_FOUND'; then
        blocker_state=absent
        rm -f "$blocker_error"
      else
        rm -f "$blocker_error"
        fail "could not read blocker $blocker"
      fi
      tasks_axi unblock "$id" --by "$blocker" >/dev/null \
        || fail "could not clear resolved blocker $blocker from $id"
      printf 'unblocked=%s blocker=%s state=%s\n' "$id" "$blocker" "$blocker_state"
    done <<EOF
$(printf '%s\n' "$blockers" | tr ',' '\n')
EOF
  done <<EOF
$rows
EOF
}

reconcile() {
  local rows row id detail='' line blocker_repairs decision_repairs
  backend_enabled || { printf 'BACKLOG_INTEGRITY: skipped (tasks-axi backend unavailable)\n'; return 0; }
  rows=$(tasks_axi list --state in_flight) || fail "could not list in-flight backlog rows"
  while IFS= read -r row; do
    id=$(row_id "$row") || continue
    line=$(reconcile_orphan "$id") || exit 1
    [ -z "$line" ] || detail="${detail}${detail:+; }$line"
  done <<EOF
$rows
EOF
  blocker_repairs=$(reconcile_blockers) || fail "could not reconcile backlog blockers"
  while IFS= read -r line; do
    [ -z "$line" ] || detail="${detail}${detail:+; }$line"
  done <<EOF
$blocker_repairs
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
  check-row) [ "$#" -ge 2 ] && [ "$#" -le 3 ] || exit 2; check_row "$2" "${3:-}" ;;
  start) [ "$#" -eq 2 ] || exit 2; guarded_start "$2" ;;
  done) [ "$#" -ge 2 ] || exit 2; id=$2; shift 2; record_done "$id" "$@" ;;
  landed) [ "$#" -ge 3 ] || exit 2; id=$2; context=$3; shift 3; record_landed "$id" "$context" "$@" ;;
  failed) [ "$#" -eq 2 ] || exit 2; record_failed "$2" ;;
  reconcile) [ "$#" -eq 1 ] || exit 2; reconcile ;;
  *) exit 2 ;;
esac
