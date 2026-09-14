#!/usr/bin/env bash
# Show or persist session-stamped codeburn usage for one task.
# Usage: fm-task-usage.sh <task-id> [--json|--snapshot]
# See fm-task-session.mjs for write-once launch identities and fm-task-usage.mjs
# for the snapshot schema, bounded report query, and session-ID join.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in -h|--help) sed -n '2,5s/^# //p' "$0"; exit 0 ;; esac
if [ "${2:-}" != --snapshot ]; then
  exec node "$SCRIPT_DIR/fm-task-usage.mjs" "$@"
fi
# Serialize measurements so an older query cannot overwrite a newer snapshot.
# This is a write lock only; ordinary live reads remain read-only.
case "${1:-}" in ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) echo 'fm-task-usage: invalid task id' >&2; exit 1 ;; esac
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
TASK_DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}/$1"
[ -d "$TASK_DATA" ] || { echo "fm-task-usage: cannot read $TASK_DATA" >&2; exit 1; }
USAGE_LOCK="$TASK_DATA/.usage.lock"
fm_lock_acquire_wait "$USAGE_LOCK" || exit 1
trap 'fm_lock_release "$USAGE_LOCK"' EXIT
node "$SCRIPT_DIR/fm-task-usage.mjs" "$@"
fm_lock_release "$USAGE_LOCK"
trap - EXIT
# shellcheck source=bin/fm-task-meta-lock-lib.sh
. "$SCRIPT_DIR/fm-task-meta-lock-lib.sh"
fm_task_effort_capture_best_effort "$FM_ROOT" "$1"
