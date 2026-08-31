#!/usr/bin/env bash
# Print the authoritative drawn "<columns> <lines>" for this exact Herdr pane.
# Herdr 0.7.3 can leave the pane pty winsize stale after a split or redraw, so
# the fleet painter calls this before every frame instead of trusting the pty.
# Exit 64 means the exact pane or its authoritative foreground cwd is gone and
# retry cannot recover it. Exit 75 means the pane is still authoritative but
# its drawn layout could not be read yet, so the caller may retry briefly.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION=${HERDR_SESSION:-}
PANE=${HERDR_PANE_ID:-}
case "$SESSION:$PANE" in
  :*|*:) exit 1 ;;
esac

herdr_call() {
  (
    cd "$SCRIPT_DIR/.." || exit 75
    if [ -n "${FM_HERDR_LAB_HELPER:-}" ]; then
      [ -n "${FM_HERDR_LAB_SESSION:-}" ] || exit 75
      "$FM_HERDR_LAB_HELPER" run "$FM_HERDR_LAB_SESSION" "$@"
    else
      HERDR_SESSION="$SESSION" herdr "$@" --session "$SESSION"
    fi
  )
}

PANE_OUT=$(herdr_call pane get "$PANE" 2>&1)
PANE_STATUS=$?
if [ "$PANE_STATUS" -ne 0 ]; then
  PANE_CODE=$(printf '%s' "$PANE_OUT" | jq -r '.error.code // empty' 2>/dev/null) || PANE_CODE=
  [ "$PANE_CODE" != pane_not_found ] || exit 64
  exit 75
fi
printf '%s' "$PANE_OUT" | jq -e --arg pane "$PANE" '
  .result.pane as $record
  | ($record | type) == "object"
    and $record.pane_id == $pane
    and ($record | has("foreground_cwd"))
    and (($record.foreground_cwd | type) == "string" or $record.foreground_cwd == null)
' >/dev/null 2>&1 || exit 75
PANE_CWD=$(printf '%s' "$PANE_OUT" | jq -r --arg pane "$PANE" '
  .result.pane.foreground_cwd // empty
') || exit 75
[ -n "$PANE_CWD" ] || exit 64
[ -d "$PANE_CWD" ] || exit 64

OUT=$(herdr_call pane layout --pane "$PANE") || exit 75

printf '%s' "$OUT" | jq -e '
  .result.layout.panes
  | type == "array"
    and all(.[ ];
      type == "object"
      and (.pane_id | type) == "string"
      and (.pane_id | length) > 0
      and (.rect | type) == "object"
      and (.rect.x | type) == "number"
      and (.rect.y | type) == "number"
      and (.rect.width | type) == "number"
      and (.rect.height | type) == "number"
      and .rect.width > 0
      and .rect.height > 0)
' >/dev/null 2>&1 || exit 75
printf '%s' "$OUT" | jq -e --arg pane "$PANE" '
  any(.result.layout.panes[]; .pane_id == $pane)
' >/dev/null 2>&1 || exit 64

printf '%s' "$OUT" | jq -er --arg pane "$PANE" '
  [.result.layout.panes[]? | select(.pane_id == $pane) | .rect]
  | if length == 1
    and .[0].width > 0 and .[0].height > 0
    then "\(.[0].width) \(.[0].height)"
    else error("authoritative pane rectangle unavailable")
    end
' || exit 75
