#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward the
# project's default branch to the crewmate's fm/<id> branch.
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-only tasks, only after the captain approves (or yolo=on
# auto-approves), and only as a clean fast-forward - it refuses a diverged branch
# and tells you to have the crewmate rebase. See AGENTS.md prime directives,
# project management, and task lifecycle.
# Usage: fm-merge-local.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-task-meta-lock-lib.sh
. "$SCRIPT_DIR/fm-task-meta-lock-lib.sh"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=${1:?usage: fm-merge-local.sh <task-id>}
fm_pr_task_id_valid "$ID" || { echo "error: invalid local merge request" >&2; exit 2; }
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }

PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ "$MODE" = local-only ] || { echo "error: task $ID is mode=$MODE, not local-only; merge PR tasks with bin/fm-pr-merge.sh <id> <PR url> after approval" >&2; exit 1; }

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

BRANCH="fm/$ID"
git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || { echo "error: branch $BRANCH does not exist in $PROJ" >&2; exit 1; }

DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }

# The project's main checkout must be on its default branch and clean, so the
# fast-forward lands predictably (firstmate never writes here otherwise).
cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
[ "$cur" = "$DEFAULT" ] || { echo "error: $PROJ is on '$cur', expected default branch '$DEFAULT'; cannot merge safely" >&2; exit 1; }
if [ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ]; then
  echo "error: $PROJ has a dirty working tree; refusing to merge into it" >&2
  exit 1
fi

# Clean fast-forward only: DEFAULT must be an ancestor of BRANCH.
if ! git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$BRANCH"; then
  echo "REFUSED: $BRANCH is not a fast-forward of $DEFAULT (it has diverged)." >&2
  echo "Have the crewmate rebase $BRANCH onto $DEFAULT, then retry." >&2
  exit 1
fi

before=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
BEFORE_SHA=$(git -C "$PROJ" rev-parse "$DEFAULT")
LANDED_SHA=$(git -C "$PROJ" rev-parse "$BRANCH")
SPAWNED_AT=$(sed -n 's/^spawned_at=//p' "$META" | tail -1)
printf '%s\n' "$SPAWNED_AT" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
  || { echo "error: task launch identity is unavailable" >&2; exit 1; }
RECEIPT_DIR="$DATA/local-landings"
RECEIPT="$RECEIPT_DIR/$ID.receipt"
LANDING_LOCK="$STATE/.local-landing-$ID.lock"
LANDING_LOCK_HELD=0

landing_cleanup() {
  if [ "$LANDING_LOCK_HELD" = 1 ]; then
    fm_lock_release "$LANDING_LOCK" || true
    LANDING_LOCK_HELD=0
  fi
}

trap landing_cleanup EXIT
trap 'exit 1' HUP INT TERM
fm_lock_acquire_wait "$LANDING_LOCK"
LANDING_LOCK_HELD=1

receipt_value() {
  sed -n "s/^$1=//p" "$RECEIPT" 2>/dev/null | tail -1
}

receipt_matches_request() {
  local key phase
  [ -f "$RECEIPT" ] && [ ! -L "$RECEIPT" ] || return 1
  for key in schema task_id spawned_at project branch default_branch before_sha landed_sha phase event_at; do
    [ "$(grep -c "^${key}=" "$RECEIPT" 2>/dev/null || true)" -eq 1 ] || return 1
  done
  [ "$(receipt_value schema)" = fm-local-landing.v1 ] || return 1
  [ "$(receipt_value task_id)" = "$ID" ] || return 1
  [ "$(receipt_value spawned_at)" = "$SPAWNED_AT" ] || return 1
  [ "$(receipt_value project)" = "$PROJ" ] || return 1
  [ "$(receipt_value branch)" = "$BRANCH" ] || return 1
  [ "$(receipt_value default_branch)" = "$DEFAULT" ] || return 1
  [ "$(receipt_value landed_sha)" = "$LANDED_SHA" ] || return 1
  printf '%s\n' "$(receipt_value event_at)" \
    | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' || return 1
  phase=$(receipt_value phase)
  [ "$phase" = prepared ] || [ "$phase" = landed ]
}

write_receipt() {
  local phase=$1 event_at=$2 tmp
  if [ -e "$DATA" ] || [ -L "$DATA" ]; then
    [ -d "$DATA" ] && [ ! -L "$DATA" ] || return 1
  else
    mkdir -p "$DATA" || return 1
  fi
  if [ -e "$RECEIPT_DIR" ] || [ -L "$RECEIPT_DIR" ]; then
    [ -d "$RECEIPT_DIR" ] && [ ! -L "$RECEIPT_DIR" ] || return 1
  else
    mkdir "$RECEIPT_DIR" || return 1
  fi
  umask 077
  tmp=$(mktemp "$RECEIPT_DIR/.$ID.receipt.XXXXXX") || return 1
  printf '%s\n' \
    'schema=fm-local-landing.v1' \
    "task_id=$ID" \
    "spawned_at=$SPAWNED_AT" \
    "project=$PROJ" \
    "branch=$BRANCH" \
    "default_branch=$DEFAULT" \
    "before_sha=$BEFORE_SHA" \
    "landed_sha=$LANDED_SHA" \
    "phase=$phase" \
    "event_at=$event_at" > "$tmp" \
    && chmod 600 "$tmp" \
    && mv -f "$tmp" "$RECEIPT" \
    || { rm -f "$tmp"; return 1; }
}

if [ -e "$RECEIPT" ] || [ -L "$RECEIPT" ]; then
  if ! receipt_matches_request \
    && [ "$(receipt_value schema)" = fm-local-landing.v1 ] \
    && [ "$(receipt_value task_id)" = "$ID" ] \
    && [ "$(receipt_value phase)" = landed ] \
    && printf '%s\n' "$(receipt_value spawned_at)" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
    && printf '%s\n' "$(receipt_value event_at)" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
    && [ "$(receipt_value spawned_at)" != "$SPAWNED_AT" ]; then
    HISTORY_DIR="$RECEIPT_DIR/history"
    [ ! -e "$HISTORY_DIR" ] || { [ -d "$HISTORY_DIR" ] && [ ! -L "$HISTORY_DIR" ]; } \
      || { echo "error: local landing history is unavailable" >&2; exit 1; }
    mkdir -p "$HISTORY_DIR"
    OLD_SPAWNED_AT=$(receipt_value spawned_at)
    HISTORY_RECEIPT="$HISTORY_DIR/$ID.${OLD_SPAWNED_AT//:/-}.receipt"
    [ ! -e "$HISTORY_RECEIPT" ] || { echo "error: local landing history conflicts" >&2; exit 1; }
    mv "$RECEIPT" "$HISTORY_RECEIPT"
  fi
fi
if [ -e "$RECEIPT" ] || [ -L "$RECEIPT" ]; then
  receipt_matches_request || { echo "error: local landing provenance conflicts with this task" >&2; exit 1; }
  EVENT_AT=$(receipt_value event_at)
  BEFORE_SHA=$(receipt_value before_sha)
else
  EVENT_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  write_receipt prepared "$EVENT_AT" \
    || { echo "error: could not prepare local landing provenance" >&2; exit 1; }
fi
git -C "$PROJ" merge --ff-only "$BRANCH" >/dev/null
after=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
if [ "$(receipt_value phase)" != landed ]; then
  write_receipt landed "$EVENT_AT" \
    || { echo "error: local landing succeeded but its durable receipt could not be completed" >&2; exit 1; }
fi
fm_task_effort_capture_best_effort "$FM_ROOT" "$ID"
fm_task_meta_set_once "$META" local_landed_at "$EVENT_AT" || {
  echo "error: local landing succeeded but its lifecycle stamp could not be recorded" >&2
  exit 1
}
fm_task_effort_capture_best_effort "$FM_ROOT" "$ID"
echo "merged $BRANCH into local $DEFAULT ($before -> $after) in $PROJ"
