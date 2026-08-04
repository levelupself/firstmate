#!/usr/bin/env bash
# Adopt or inspect the current home's orchestration cockpit frame.
#
# Usage: fm-cockpit.sh adopt|new|status
#
# The enhanced cockpit exists only when the supervisor itself runs natively in
# Herdr. Herdr's own sidebar is the cross-home display surface, while this
# command records only the current home's pinned head frame. Every non-Herdr
# runtime exits successfully with an explicit fallback to the read-only fleet
# panel; it never builds an emulation or changes task placement.
#
# adopt is the locked session-start path. It initializes an absent record from
# the exact injected Herdr pane or re-adopts the same binding after a supervisor
# restart. It never replaces, creates, closes, moves, or splits a pane.
#
# new is the explicit clean-context recovery path for a supervisor started in a
# different pane. It replaces the record only when the old head is positively
# dead or agent-free, and it leaves that old pane untouched.
#
# status is read-only and reports whether the current home's recorded head is
# live. bin/backends/herdr.sh owns the exact seven-line record format and atomic
# publication mechanics.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  adopt|new|status) ACTION=$1 ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
[ "$#" -eq 1 ] || { usage >&2; exit 2; }

if ! FM_HOME=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P); then
  echo "COCKPIT: FM_HOME cannot be resolved; preserving any recorded frame." >&2
  exit 1
fi

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

RUNTIME=none
if fm_backend_detect >/dev/null; then
  RUNTIME=$FM_BACKEND_DETECTED
fi
if [ "$RUNTIME" != herdr ]; then
  printf 'COCKPIT: unavailable on runtime backend %s; use bin/fm-fleet-view.sh --watch with unchanged peer endpoints.\n' "$RUNTIME"
  exit 0
fi

fm_backend_source herdr || exit 1
SESSION=${HERDR_SESSION:-default}

if [ "$ACTION" = status ]; then
  if fm_backend_herdr_cockpit_binding_live "$STATE" "$FM_HOME" "$SESSION"; then
    printf 'COCKPIT: live session=%s workspace=%s tab=%s head=%s viewport=%s display=all-homes steer=current-home\n' \
      "$FM_BACKEND_HERDR_COCKPIT_SESSION" \
      "$FM_BACKEND_HERDR_COCKPIT_WORKSPACE_ID" \
      "$FM_BACKEND_HERDR_COCKPIT_TAB_ID" \
      "$FM_BACKEND_HERDR_COCKPIT_HEAD_PANE_ID" \
      "${FM_BACKEND_HERDR_COCKPIT_VIEWPORT_PANE_ID:-none}"
    exit 0
  fi
  echo "COCKPIT: unavailable because this home's recorded Herdr frame is absent, invalid, or dead; use bin/fm-fleet-view.sh --watch." >&2
  exit 1
fi

if [ -z "${HERDR_WORKSPACE_ID:-}" ] \
   || [ -z "${HERDR_TAB_ID:-}" ] \
   || [ -z "${HERDR_PANE_ID:-}" ]; then
  echo "COCKPIT: native Herdr identity is incomplete; preserving any recorded frame." >&2
  exit 1
fi

MODE=adopt
[ "$ACTION" != new ] || MODE=new
fm_backend_herdr_cockpit_adopt "$STATE" "$FM_HOME" "$SESSION" \
  "$HERDR_WORKSPACE_ID" "$HERDR_TAB_ID" "$HERDR_PANE_ID" "$MODE"
