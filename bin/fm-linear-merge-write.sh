#!/usr/bin/env bash
# Record a landed task in Linear: move its mirrored issue to Done and attach the
# pull request that shipped it.
#
# Called by fm-pr-merge.sh immediately AFTER a merge succeeds, and safe to run by
# hand afterwards. The merge is the one moment where the task id, the pull
# request, and a live backlog entry all exist together, so it is the only place
# the shipped outcome can be recorded without depending on the backlog still
# remembering the item later - data/backlog.md prunes Done to the configured
# recent few.
#
# Usage: fm-linear-merge-write.sh <task-id> <pr-url>
#
# CONTRACT: this NEVER fails a merge, and never runs before one. Every path -
# unconfigured, unreachable, unauthenticated, slow, no mirrored issue, a team
# with no completed status, a rejected mutation - prints one line saying what did
# happen and exits 0. The merge has already landed by the time this runs, so
# there is nothing here that a failure could usefully abort.
#
# Idempotent: an issue already in a completed status is not transitioned again,
# and a pull request already attached is not attached again, so a retried or
# repeated merge write converges instead of stacking duplicates.
#
# fm-linear-refresh.sh writes the same two facts when it reconciles the whole
# backlog. Both go through fm-linear-lib.sh's fml_set_state and fml_attach_url,
# so the Done transition and the attachment have one owner between them.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
export FM_HOME

if [ $# -lt 2 ]; then
  echo "usage: fm-linear-merge-write.sh <task-id> <pr-url>" >&2
  exit 2
fi
ID=$1
URL=$2

say() { printf 'linear: %s\n' "$1"; }

# The same kill switch fm-linear-pr-link.sh honours, for an operator who wants
# the merge without any Linear traffic at all.
case "${FM_LINEAR_DISABLE:-}" in
  ''|0|false|no|off) ;;
  *) say "disabled by FM_LINEAR_DISABLE; nothing recorded"; exit 0 ;;
esac

# shellcheck source=bin/fm-linear-lib.sh
. "$FM_ROOT/bin/fm-linear-lib.sh"
fml_load_config

# The merge path uses the same tightened deadline as the PR path: this runs in
# the operator's merge command, so a hanging Linear must not hold it open.
case "${FM_LINEAR_PR_TIMEOUT:-}" in
  ''|*[!0-9]*) merge_timeout=8 ;;
  *) merge_timeout=${FM_LINEAR_PR_TIMEOUT} ;;
esac
[ "$merge_timeout" -ge 1 ] 2>/dev/null || merge_timeout=8
[ "$merge_timeout" -le "$FML_TIMEOUT" ] || merge_timeout=$FML_TIMEOUT
FML_TIMEOUT=$merge_timeout

if ! fml_available; then
  say "$(fml_unavailable_reason); nothing recorded"
  exit 0
fi

set +e
row=$(fml_find_issue "$ID")
rc=$?
set -e
case "$rc" in
  0) ;;
  1) say "no mirrored issue for $ID; nothing recorded, merge unaffected"; exit 0 ;;
  *) say "lookup unavailable (Linear did not answer within ${merge_timeout}s or rejected the request); nothing recorded, merge unaffected"; exit 0 ;;
esac

IDENT=$(printf '%s' "$row" | cut -f1)
ISSUE_UUID=$(printf '%s' "$row" | cut -f2)
STATE_TYPE=$(printf '%s' "$row" | cut -f5)
TEAM_UUID=$(printf '%s' "$row" | cut -f6)
ATTACHED=$(printf '%s' "$row" | cut -f7 | base64 -d 2>/dev/null || true)
if [ -z "$ISSUE_UUID" ]; then
  say "lookup returned no issue for $ID; nothing recorded, merge unaffected"
  exit 0
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-linear-merge.XXXXXX") || {
  say "found $IDENT but could not create a temp dir; nothing recorded, merge unaffected"
  exit 0
}
trap 'rm -rf "$tmp"' EXIT
trap 'rm -rf "$tmp"; exit 143' HUP INT TERM

outcome=
problem=

# 1. Done. Only a not-yet-completed issue is transitioned, so a status the
#    captain set by hand on something already finished is never overwritten.
if [ "$STATE_TYPE" = completed ]; then
  outcome="already Done"
else
  set +e
  done_state=$(fml_done_state_id "$TEAM_UUID" "$tmp/team.json")
  set -e
  if [ -z "$done_state" ]; then
    problem="the team has no completed status to move it to"
  elif fml_set_state "$ISSUE_UUID" "$done_state" "$tmp/state.json"; then
    outcome="Done"
  else
    problem="Linear rejected the Done transition"
  fi
fi

# 2. The pull request, as a link attachment.
if printf '%s\n' "$ATTACHED" | grep -Fxq "$URL"; then
  outcome="$outcome, $URL already attached"
elif fml_attach_url "$ISSUE_UUID" "$URL" "Pull request" "$tmp/attach.json"; then
  outcome="$outcome with $URL attached"
else
  problem="${problem:+$problem; }Linear rejected the attachment of $URL"
fi

if [ -n "$problem" ]; then
  say "recorded $IDENT as ${outcome:-unchanged}, but $problem; merge unaffected"
else
  say "recorded $IDENT as $outcome"
fi
