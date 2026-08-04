#!/usr/bin/env bash
# Open a task's GitHub pull-request diff in Hunk with curated crewmate notes.
#
# Usage: fm-review.sh [<task-id>]
# With no id, the highest-impact checks-green task without an open captain
# decision is selected from the fleet snapshot. A sidecar at
# data/<id>/review-notes.json is optional, but --agent-notes is always enabled.
# Hunk is a comprehension aid only: its comments do not reach the pull request,
# and GitHub remains the review system of record.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

usage() {
  sed -n '2,/^set -euo pipefail$/s/^# \{0,1\}//p' "$0" | sed '$d'
}

case "${1:-}" in -h|--help) usage; exit 0 ;; esac
[ $# -le 1 ] || { usage >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "fm-review: curl not found" >&2; exit 1; }
command -v hunkdiff >/dev/null 2>&1 || { echo "fm-review: hunkdiff not found" >&2; exit 1; }

ID=${1:-}
if [ -z "$ID" ]; then
  command -v jq >/dev/null 2>&1 || { echo "fm-review: jq not found" >&2; exit 1; }
  SNAPSHOT=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    "$FM_ROOT/bin/fm-fleet-snapshot.sh" --json)
  ID=$(printf '%s\n' "$SNAPSHOT" | jq -r '
    . as $s | [.tasks[]
      | select(.pr.url != null and .current_state.state == "done")
      | select((.current_state.detail // "") | test("checks green"; "i"))
      | . as $task
      | select(any($s.backlog.records[]?;
          .state != "done" and .structured == true and .kind == "captain"
          and .hold_kind == "captain" and .hold_reason != null
          and .captain_decision.origin == $task.id) | not)
      | . + {unblocks: ([$s.backlog.records[]?
          | select(.state != "done")
          | select((.unresolved_blocker_ids // []) | index($task.id))
          | .id] | unique | length)}]
    | sort_by(-.unblocks, .backlog.order, .id) | first | .id // empty')
  [ -n "$ID" ] || {
    echo "fm-review: no pull request is ready; green alone is not ready when a captain decision is open" >&2
    exit 1
  }
fi

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "fm-review: task does not exist: $ID" >&2; exit 1; }
PR=$(sed -n 's/^pr=//p' "$META" | tail -1)
[ -n "$PR" ] || { echo "fm-review: task $ID has no pr= in $META" >&2; exit 1; }
PR=${PR%/}
if ! [[ $PR =~ ^https://github.com/[^/]+/[^/]+/pull/[0-9]+/?$ ]]; then
  echo "fm-review: unsupported pull-request URL in $META: $PR" >&2
  exit 1
fi

NOTES="$DATA/$ID/review-notes.json"
echo "Reviewing task $ID. Hunk comments stay local; record review decisions on GitHub."
if [ -f "$NOTES" ]; then
  curl -fsSL "${PR%.diff}.diff" | hunkdiff patch --agent-context "$NOTES" --agent-notes
else
  curl -fsSL "${PR%.diff}.diff" | hunkdiff patch --agent-notes
fi
