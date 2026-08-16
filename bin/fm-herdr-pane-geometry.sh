#!/usr/bin/env bash
# Print the authoritative drawn "<columns> <lines>" for this exact Herdr pane.
# Herdr 0.7.3 can leave the pane pty winsize stale after a split or redraw, so
# the fleet painter calls this before every frame instead of trusting the pty.
set -u

SESSION=${HERDR_SESSION:-}
PANE=${HERDR_PANE_ID:-}
case "$SESSION:$PANE" in
  :*|*:) exit 1 ;;
esac

if [ -n "${FM_HERDR_LAB_HELPER:-}" ]; then
  [ -n "${FM_HERDR_LAB_SESSION:-}" ] || exit 1
  OUT=$("$FM_HERDR_LAB_HELPER" run "$FM_HERDR_LAB_SESSION" pane layout --pane "$PANE") || exit 1
else
  OUT=$(HERDR_SESSION="$SESSION" herdr pane layout --pane "$PANE" --session "$SESSION") || exit 1
fi

printf '%s' "$OUT" | jq -r --arg pane "$PANE" '
  [.result.layout.panes[]? | select(.pane_id == $pane) | .rect]
  | if length == 1
    and .[0].width > 0 and .[0].height > 0
    then "\(.[0].width) \(.[0].height)"
    else error("authoritative pane rectangle unavailable")
    end
'
