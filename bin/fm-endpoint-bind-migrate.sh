#!/usr/bin/env bash
# Migrate one legacy non-tmux task record that predates endpoint_task_id=.
#
# This is an explicit, read-only-evidence migration, never part of ordinary
# cleanup or bootstrap.  The only currently supported proof is a Herdr agent
# inventory read scoped to the recorded session.  Exactly one live agent entry
# must have foreground_cwd equal byte-for-byte to the recorded worktree, and
# that entry's pane/workspace/tab identity must equal the recorded endpoint.
# Zero matches, multiple matches, unreadable inventory, contradictory endpoint
# identity, already-bound metadata, and unsupported backends all refuse without
# changing the task metadata.
#
# On success, the command atomically replaces state/<id>.meta with the same
# record plus endpoint_task_id= and migration provenance fields.  It also saves
# the exact matching live inventory entry in
# data/<id>/endpoint-binding-migration.json so the evidence survives teardown.
#
# Usage: fm-endpoint-bind-migrate.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-task-meta-lock-lib.sh
. "$SCRIPT_DIR/fm-task-meta-lock-lib.sh"

usage() {
  echo "usage: fm-endpoint-bind-migrate.sh <task-id>" >&2
  exit 2
}

[ "$#" -eq 1 ] || usage
ID=$1
case "$ID" in
  ''|.*|*[!A-Za-z0-9._-]*) usage ;;
esac

fm_refuse_if_gate_agent

META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || {
  echo "REFUSED: task $ID has no regular endpoint metadata at $META; metadata unchanged." >&2
  exit 1
}

binding_count=$(grep -c '^endpoint_task_id=' "$META" 2>/dev/null || true)
if [ "$binding_count" -ne 0 ]; then
  echo "REFUSED: task $ID does not have legacy unbound endpoint metadata; metadata unchanged." >&2
  exit 1
fi

for field in endpoint_binding_migration endpoint_binding_verified_at endpoint_binding_audit; do
  if grep -q "^$field=" "$META" 2>/dev/null; then
    echo "REFUSED: task $ID already has endpoint-binding migration provenance; metadata unchanged." >&2
    exit 1
  fi
done

backend=$(fm_backend_meta_exact_value "$META" backend) || backend=
if [ "$backend" != herdr ]; then
  echo "REFUSED: legacy endpoint binding migration supports only backend=herdr; task $ID records '${backend:-no exact backend}'; metadata unchanged." >&2
  exit 1
fi

META_TMP=
AUDIT_TMP=
cleanup() {
  fm_task_meta_lock_release || true
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
  [ -z "$AUDIT_TMP" ] || rm -f -- "$AUDIT_TMP"
}
trap cleanup EXIT
umask 077

META_TMP=$(mktemp "$STATE/.fm-endpoint-bind.$ID.meta.XXXXXX") || {
  echo "REFUSED: could not create a private metadata candidate for task $ID; metadata unchanged." >&2
  exit 1
}
cp -p -- "$META" "$META_TMP" || {
  echo "REFUSED: could not snapshot endpoint metadata for task $ID; metadata unchanged." >&2
  exit 1
}
printf 'endpoint_task_id=%s\n' "$ID" >> "$META_TMP"

validation_error=
if ! validation_error=$(fm_backend_validate_task_endpoint "$META_TMP" "$ID" 2>&1); then
  [ -z "$validation_error" ] || printf '%s\n' "$validation_error" >&2
  echo "REFUSED: legacy Herdr metadata for task $ID is not a valid cleanup endpoint even with a proven binding; metadata unchanged." >&2
  exit 1
fi

worktree=$(fm_backend_meta_exact_value "$META" worktree)
session=$(fm_backend_meta_exact_value "$META" herdr_session)
workspace=$(fm_backend_meta_exact_value "$META" herdr_workspace_id)
tab=$(fm_backend_meta_exact_value "$META" herdr_tab_id)
pane=$(fm_backend_meta_exact_value "$META" herdr_pane_id)
window=$(fm_backend_meta_exact_value "$META" window)

fm_backend_source herdr || {
  echo "REFUSED: Herdr adapter is unavailable for task $ID; metadata unchanged." >&2
  exit 1
}
fm_backend_herdr_tool_check || {
  echo "REFUSED: Herdr inventory prerequisites are unavailable for task $ID; metadata unchanged." >&2
  exit 1
}

inventory=
if ! inventory=$(fm_backend_herdr_cli "$session" agent list 2>/dev/null); then
  echo "REFUSED: Herdr live agent inventory for session $session is unreadable for task $ID; metadata unchanged." >&2
  exit 1
fi
if ! printf '%s\n' "$inventory" | jq -e '
  ((.result.agents | type) == "array")
  and all(.result.agents[];
    (type == "object")
    and ((.foreground_cwd | type) == "string")
    and ((.pane_id | type) == "string")
    and ((.workspace_id | type) == "string")
    and ((.tab_id | type) == "string"))
' >/dev/null 2>&1; then
  echo "REFUSED: Herdr live agent inventory for session $session is unreadable or malformed for task $ID; metadata unchanged." >&2
  exit 1
fi

matches=$(printf '%s\n' "$inventory" | jq -c --arg worktree "$worktree" \
  '[.result.agents[] | select(.foreground_cwd == $worktree)]')
match_count=$(printf '%s\n' "$matches" | jq -r 'length')
case "$match_count" in
  0)
    echo "REFUSED: Herdr live agent inventory has zero exact foreground_cwd matches for task $ID worktree $worktree; metadata unchanged." >&2
    exit 1
    ;;
  1) ;;
  *)
    echo "REFUSED: Herdr live agent inventory has $match_count exact foreground_cwd matches for task $ID worktree $worktree; binding is ambiguous and metadata is unchanged." >&2
    exit 1
    ;;
esac

live_pane=$(printf '%s\n' "$matches" | jq -r '.[0].pane_id')
live_workspace=$(printf '%s\n' "$matches" | jq -r '.[0].workspace_id')
live_tab=$(printf '%s\n' "$matches" | jq -r '.[0].tab_id')
if [ "$live_pane" != "$pane" ] || [ "$live_workspace" != "$workspace" ] \
   || [ "$live_tab" != "$tab" ] || [ "$window" != "$session:$live_pane" ]; then
  echo "REFUSED: unique Herdr worktree match identifies $session:$live_pane ($live_workspace/$live_tab), not task $ID's recorded endpoint $window ($workspace/$tab); metadata unchanged." >&2
  exit 1
fi

verified_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || {
  echo "REFUSED: could not timestamp endpoint-binding evidence for task $ID; metadata unchanged." >&2
  exit 1
}
printf '%s\n' \
  'endpoint_binding_migration=herdr-agent-list-foreground-cwd-v1' \
  "endpoint_binding_verified_at=$verified_at" \
  "endpoint_binding_audit=data/$ID/endpoint-binding-migration.json" \
  >> "$META_TMP"

if ! fm_task_meta_lock_acquire "$META"; then
  echo "REFUSED: task metadata mutation lock for task $ID is unavailable; metadata unchanged." >&2
  exit 1
fi

if [ ! -f "$META" ] || [ -L "$META" ] || ! cmp -s -- "$META" <(sed '/^endpoint_task_id=/d; /^endpoint_binding_migration=/d; /^endpoint_binding_verified_at=/d; /^endpoint_binding_audit=/d' "$META_TMP"); then
  echo "REFUSED: endpoint metadata for task $ID changed during live verification; metadata unchanged by this migration." >&2
  exit 1
fi

if [ ! -d "$DATA" ] || [ -L "$DATA" ]; then
  echo "REFUSED: data directory $DATA is unavailable or unsafe; metadata unchanged." >&2
  exit 1
fi
TASK_DATA="$DATA/$ID"
if [ -e "$TASK_DATA" ] || [ -L "$TASK_DATA" ]; then
  if [ ! -d "$TASK_DATA" ] || [ -L "$TASK_DATA" ]; then
    echo "REFUSED: task data path $TASK_DATA is not a regular directory; metadata unchanged." >&2
    exit 1
  fi
else
  mkdir -- "$TASK_DATA" || {
    echo "REFUSED: could not create task data directory $TASK_DATA; metadata unchanged." >&2
    exit 1
  }
fi
AUDIT="$TASK_DATA/endpoint-binding-migration.json"
if [ -e "$AUDIT" ] || [ -L "$AUDIT" ]; then
  if [ ! -f "$AUDIT" ] || [ -L "$AUDIT" ]; then
    echo "REFUSED: endpoint-binding audit path $AUDIT is not a regular file; metadata unchanged." >&2
    exit 1
  fi
fi
AUDIT_TMP=$(mktemp "$TASK_DATA/.endpoint-binding-migration.XXXXXX") || {
  echo "REFUSED: could not create a private audit candidate for task $ID; metadata unchanged." >&2
  exit 1
}
printf '%s\n' "$matches" | jq --arg task_id "$ID" \
  --arg verified_at "$verified_at" --arg worktree "$worktree" \
  --arg session "$session" --arg window "$window" \
  --arg workspace_id "$workspace" --arg tab_id "$tab" --arg pane_id "$pane" '
  {
    version: 1,
    task_id: $task_id,
    backend: "herdr",
    verification: "herdr-agent-list-foreground-cwd-v1",
    verified_at: $verified_at,
    recorded: {
      worktree: $worktree,
      session: $session,
      window: $window,
      workspace_id: $workspace_id,
      tab_id: $tab_id,
      pane_id: $pane_id
    },
    live_match: .[0],
    inventory_match_count: length
  }
' > "$AUDIT_TMP" || {
  echo "REFUSED: could not serialize endpoint-binding evidence for task $ID; metadata unchanged." >&2
  exit 1
}

if [ ! -f "$META" ] || [ -L "$META" ] || ! cmp -s -- "$META" <(sed '/^endpoint_task_id=/d; /^endpoint_binding_migration=/d; /^endpoint_binding_verified_at=/d; /^endpoint_binding_audit=/d' "$META_TMP"); then
  echo "REFUSED: endpoint metadata for task $ID changed before publication; metadata unchanged by this migration." >&2
  exit 1
fi

mv -f -- "$AUDIT_TMP" "$AUDIT" || {
  echo "REFUSED: could not publish endpoint-binding audit for task $ID; metadata unchanged." >&2
  exit 1
}
AUDIT_TMP=
mv -f -- "$META_TMP" "$META" || {
  echo "REFUSED: could not publish endpoint binding for task $ID; task metadata remains unbound and the audit is retained at $AUDIT." >&2
  exit 1
}
META_TMP=
fm_task_meta_lock_release || {
  echo "REFUSED: endpoint binding was published for task $ID but its metadata mutation lock could not be released." >&2
  exit 1
}

echo "migrated endpoint binding for task $ID from one exact Herdr foreground_cwd match; audit: $AUDIT"
