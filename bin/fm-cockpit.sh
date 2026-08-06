#!/usr/bin/env bash
# Adopt or inspect the current home's orchestration cockpit frame.
#
# Usage: fm-cockpit.sh adopt|new|status|panel [--watch [interval]]
#        fm-cockpit.sh switch <FM_HOME>
#
# The enhanced cockpit exists only when the supervisor itself runs natively in
# Herdr. Herdr's own sidebar is the cross-home display surface, while this
# command records only the current home's pinned head frame. Every non-Herdr
# runtime exits successfully with an explicit fallback to the read-only fleet
# panel; it never builds an emulation or changes task placement.
#
# adopt is the locked session-start path. Initial adoption and conservative
# version-1 migration add the fleet split to the exact injected Herdr frame.
# A supervisor restart re-adopts the complete binding without replacing,
# creating, closing, moving, or splitting any pane.
#
# new is the explicit clean-context recovery path for a supervisor started in a
# different pane. It replaces the record only when the old head is positively
# dead or agent-free, and it leaves that old pane untouched.
#
# status is read-only and reports whether the current home's recorded head is
# live. panel renders that frame together with the read-only whole-fleet view;
# --watch refreshes it every five seconds by default. bin/backends/herdr.sh owns
# the exact eight-line record format and atomic publication mechanics.
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
  panel) ACTION=$1 ;;
  switch) ACTION=$1 ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

PANEL_WATCH=0
PANEL_INTERVAL=5
if [ "$ACTION" = panel ]; then
  shift
  case "${1:-}" in
    '') ;;
    --watch)
      PANEL_WATCH=1
      shift
      if [ "$#" -gt 0 ]; then
        PANEL_INTERVAL=$1
        shift
      fi
      ;;
    --watch=*)
      PANEL_WATCH=1
      PANEL_INTERVAL=${1#--watch=}
      shift
      ;;
    *) usage >&2; exit 2 ;;
  esac
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  if [ "$PANEL_WATCH" = 1 ]; then
    if ! [[ $PANEL_INTERVAL =~ ^[0-9]+([.][0-9]+)?$ ]] \
       || [[ $PANEL_INTERVAL =~ ^0+([.]0+)?$ ]]; then
      echo "fm-cockpit: watch interval must be a positive number" >&2
      exit 2
    fi
  fi
elif [ "$ACTION" = switch ]; then
  [ "$#" -eq 2 ] || { usage >&2; exit 2; }
  SWITCH_HOME=$2
else
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
fi

if ! FM_HOME=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P); then
  echo "COCKPIT: FM_HOME cannot be resolved; preserving any recorded frame." >&2
  exit 1
fi
[ -n "${FM_STATE_OVERRIDE:-}" ] || STATE="$FM_HOME/state"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-terminal-frame-lib.sh
. "$SCRIPT_DIR/fm-terminal-frame-lib.sh"

RUNTIME=none
if fm_backend_detect >/dev/null; then
  RUNTIME=$FM_BACKEND_DETECTED
fi
if [ "$RUNTIME" != herdr ]; then
  if [ "$ACTION" != panel ]; then
    printf 'COCKPIT: unavailable on runtime backend %s; use bin/fm-fleet-view.sh --watch with unchanged peer endpoints.\n' "$RUNTIME"
    exit 0
  fi
else
  fm_backend_source herdr || exit 1
fi

SESSION=${HERDR_SESSION:-default}

if [ "$ACTION" = switch ]; then
  if ! SWITCH_HOME=$(CDPATH='' cd -- "$SWITCH_HOME" 2>/dev/null && pwd -P); then
    echo "COCKPIT: target FM_HOME cannot be resolved." >&2
    exit 1
  fi
  case "$SWITCH_HOME/" in
    "$FM_HOME/"*) echo "COCKPIT: nested cockpit homes are not supported." >&2; exit 1 ;;
  esac
  case "$FM_HOME/" in
    "$SWITCH_HOME/"*) echo "COCKPIT: nested cockpit homes are not supported." >&2; exit 1 ;;
  esac
  SWITCH_STATE="$SWITCH_HOME/state"
  if ! fm_backend_herdr_cockpit_binding_live "$SWITCH_STATE" "$SWITCH_HOME" "$SESSION"; then
    echo "COCKPIT: target home has no live complete frame; space switch refused." >&2
    exit 1
  fi
  fm_backend_herdr_cli "$SESSION" workspace focus \
    "$FM_BACKEND_HERDR_COCKPIT_WORKSPACE_ID" >/dev/null || exit 1
  printf 'COCKPIT: switched complete frame home=%s workspace=%s\n' \
    "$SWITCH_HOME" "$FM_BACKEND_HERDR_COCKPIT_WORKSPACE_ID"
  exit 0
fi

render_frame() {
  local label panes rows head_state fleet_state
  printf '%s\n' 'ORCHESTRATION COCKPIT'
  if [ "$RUNTIME" != herdr ]; then
    printf 'NAVIGATOR plain fleet panel (Herdr sidebar unavailable on %s)\n' "$RUNTIME"
    printf 'PINNED unavailable; %s keeps its existing peer-endpoint layout\n' "$RUNTIME"
    printf '%s\n' 'VIEWPORT unavailable'
    printf 'BOUNDARY display=all-homes steer=current-home backend=%s\n' "$RUNTIME"
    return 0
  fi

  if ! fm_backend_herdr_cockpit_binding_live "$STATE" "$FM_HOME" "$SESSION"; then
    printf '%s\n' 'NAVIGATOR Herdr sidebar (all spaces and agents)'
    if fm_backend_herdr_cockpit_record_snapshot "$STATE" "$FM_HOME" \
       && [ "$FM_BACKEND_HERDR_COCKPIT_SESSION" = "$SESSION" ]; then
      head_state=$(fm_backend_herdr_cockpit_head_state \
        "$FM_BACKEND_HERDR_COCKPIT_SESSION" \
        "$FM_BACKEND_HERDR_COCKPIT_HEAD_PANE_ID")
      if [ "$head_state" = dead ]; then
        printf 'PINNED DEAD PANE %s; [r] resume old; [n] new clean context\n' \
          "$FM_BACKEND_HERDR_COCKPIT_HEAD_PANE_ID"
        printf '%s\n' 'VIEWPORT preserved; never auto-filled or re-split'
      elif [ "$head_state" = live ] && [ "$FM_BACKEND_HERDR_COCKPIT_VERSION" = 2 ]; then
        fleet_state=$(fm_backend_herdr_cockpit_fleet_state \
          "$FM_BACKEND_HERDR_COCKPIT_SESSION" \
          "$FM_BACKEND_HERDR_COCKPIT_FLEET_PANE_ID")
        printf 'PINNED head=%s [live]\n' "$FM_BACKEND_HERDR_COCKPIT_HEAD_PANE_ID"
        printf 'VIEWPORT tab=%s [preserved]\n' "$FM_BACKEND_HERDR_COCKPIT_TAB_ID"
        printf 'FLEET column=%s [%s]; frame preserved without rebuild\n' \
          "$FM_BACKEND_HERDR_COCKPIT_FLEET_PANE_ID" "$fleet_state"
      else
        printf '%s\n' 'PINNED unavailable; frame absent, invalid, or unreadable'
        printf '%s\n' 'VIEWPORT ordinary peer-endpoint layout remains active'
      fi
    else
      printf '%s\n' 'PINNED unavailable; frame absent, invalid, or unreadable'
      printf '%s\n' 'VIEWPORT ordinary peer-endpoint layout remains active'
    fi
    printf '%s\n' 'BOUNDARY display=all-homes steer=current-home backend=herdr'
    return 0
  fi

  label=$(FM_HOME="$FM_HOME" fm_backend_herdr_workspace_label 2>/dev/null || printf unknown)
  panes=$(fm_backend_herdr_cli "$SESSION" pane list \
    --workspace "$FM_BACKEND_HERDR_COCKPIT_WORKSPACE_ID" 2>/dev/null || printf '{}')
  rows=$(printf '%s' "$panes" | jq -r \
    --arg tab "$FM_BACKEND_HERDR_COCKPIT_TAB_ID" \
    --arg head "$FM_BACKEND_HERDR_COCKPIT_HEAD_PANE_ID" '
      [.result.panes[]?
       | select(.tab_id == $tab and .pane_id != $head and (.label // "") != "firstmate-fleet")
       | "  " + ((.label // "") | if . == "" then .pane_id else . end)
         + " [" + (.agent_status // "unknown") + "]"]
      | if length == 0 then "  empty; next worker splits right from the pinned head"
        else join("\n") end
    ' 2>/dev/null || printf '  unreadable')
  printf '%s\n' 'NAVIGATOR Herdr sidebar (all spaces and agents)'
  printf 'PINNED %s head=%s [live]\n' "$label" "$FM_BACKEND_HERDR_COCKPIT_HEAD_PANE_ID"
  printf 'VIEWPORT tab=%s\n%s\n' "$FM_BACKEND_HERDR_COCKPIT_TAB_ID" "$rows"
  printf 'FLEET column=%s [live]\n' "$FM_BACKEND_HERDR_COCKPIT_FLEET_PANE_ID"
  printf '%s\n' 'BOUNDARY display=all-homes steer=current-home backend=herdr'
}

render_panel() {
  render_frame
  printf '\n'
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-fleet-view.sh"
}

if [ "$ACTION" = panel ]; then
  if [ "$PANEL_WATCH" = 1 ]; then
    trap 'fm_terminal_watch_reset; exit 0' INT TERM HUP
    while :; do
      frame=$(render_panel) || true
      fm_terminal_paint_frame "$frame"
      sleep "$PANEL_INTERVAL"
    done
  fi
  render_panel
  exit 0
fi

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
  if fm_backend_herdr_cockpit_record_snapshot "$STATE" "$FM_HOME" \
     && [ "$FM_BACKEND_HERDR_COCKPIT_SESSION" = "$SESSION" ]; then
    HEAD_STATE=$(fm_backend_herdr_cockpit_head_state \
      "$FM_BACKEND_HERDR_COCKPIT_SESSION" \
      "$FM_BACKEND_HERDR_COCKPIT_HEAD_PANE_ID")
    if [ "$HEAD_STATE" = dead ]; then
      printf 'COCKPIT: DEAD PANE %s; frame preserved and never auto-filled or re-split.\n' \
        "$FM_BACKEND_HERDR_COCKPIT_HEAD_PANE_ID" >&2
      echo "COCKPIT: [r] resume old in the recorded pane; [n] run bin/fm-cockpit.sh new here for clean context." >&2
      exit 1
    fi
  fi
  echo "COCKPIT: unavailable because this home's recorded Herdr frame is absent, invalid, or dead; use bin/fm-fleet-view.sh --watch." >&2
  exit 1
fi

MODE=adopt
[ "$ACTION" != new ] || MODE=new
fm_backend_herdr_cockpit_adopt "$STATE" "$FM_HOME" "$SESSION" "$MODE"
