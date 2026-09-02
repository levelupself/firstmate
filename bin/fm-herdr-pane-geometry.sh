#!/usr/bin/env bash
# Print the authoritative drawn "<columns> <lines>" for this exact Herdr pane.
# Herdr 0.7.3 can leave the pane pty winsize stale after a split or redraw, so
# the fleet painter calls this before every frame instead of trusting the pty.
# Exit 64 means the exact pane or its authoritative foreground cwd is gone, or
# no pane identity could be resolved at all, and retry cannot recover any of
# those. Exit 75 means the pane is still authoritative but its drawn layout
# could not be read yet, so the caller may retry briefly. Exit 2 is a caller
# error in the arguments themselves.
#
# usage: fm-herdr-pane-geometry.sh [--session <session>] [--pane <pane-id>]
#
# --session and --pane are the identity channel bin/backends/herdr.sh owns: the
# adapter created and recorded the pane, so it is the only party that knows
# which one this probe is for, and it states that on the command line. Both
# must be given together and neither may be empty or carry whitespace; a
# half-given or malformed pair is a caller error rather than a quiet fallback
# to whatever the environment happens to hold.
#
# Without those arguments the probe falls back to the HERDR_SESSION and
# HERDR_PANE_ID a Herdr pane publishes, which is the only identity a hand-run
# probe has. That fallback is ambient and unverifiable: nothing in this repo
# sets those variables, any caller can spell them freely, and which of them a
# given Herdr build injects is the vendor's choice. It stays supported for
# running this probe by hand, and it is deliberately not what a painter the
# adapter launched relies on.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '11,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# A usable identity is one this probe can hand back to the server verbatim.
# Empty, whitespace-bearing, and option-shaped values are all rejected here so a
# swallowed flag or an unset variable can never be sent as a pane id.
identity_is_usable() {  # <value>
  case "$1" in
    ''|*[[:space:]]*|-*) return 1 ;;
  esac
  return 0
}

SESSION=
PANE=
EXPLICIT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --session)
      [ $# -gt 1 ] || { usage >&2; exit 2; }
      shift
      SESSION=$1
      EXPLICIT=1
      ;;
    --session=*) SESSION=${1#--session=}; EXPLICIT=1 ;;
    --pane)
      [ $# -gt 1 ] || { usage >&2; exit 2; }
      shift
      PANE=$1
      EXPLICIT=1
      ;;
    --pane=*) PANE=${1#--pane=}; EXPLICIT=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

if [ "$EXPLICIT" = 1 ]; then
  if ! identity_is_usable "$SESSION" || ! identity_is_usable "$PANE"; then
    usage >&2
    exit 2
  fi
else
  SESSION=${HERDR_SESSION:-}
  PANE=${HERDR_PANE_ID:-}
  # No identity, or one that cannot be sent to the server, is permanent: a
  # retry cannot invent the pane this probe was never told about.
  if ! identity_is_usable "$SESSION" || ! identity_is_usable "$PANE"; then
    exit 64
  fi
fi

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
