#!/usr/bin/env bash
# Adopt or inspect the current home's orchestration cockpit frame.
#
# Usage: fm-cockpit.sh adopt|new|status|panel [--watch [interval]]
#        fm-cockpit.sh switch <FM_HOME>
#        fm-cockpit.sh show <task-id>
#        fm-cockpit.sh next|prev
#        fm-cockpit.sh focus-listen [--once]
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
#
# show places one of this home's workers in the viewport slot as its sole
# occupant, parking whoever was there onto its own labelled tab. It is the
# whole feature without any listener, so it stays usable when focus-listen is
# not running at all.
#
# next and prev step the viewport along this home's workers ordered by task id,
# wrapping at both ends, and are meant to sit on a key. They resolve a worker
# and then hand it to the same single-occupancy placement a sidebar selection
# uses, so a key and a click can never disagree. The pinned supervisor and the
# fleet column are not tasks and are never rotation targets.
#
# Bind them with Herdr's own custom-command keys, which take a chord directly
# (Herdr 0.8.0 plugin manifest actions carry id, title, command, contexts,
# description, and platforms - no key - and no config entry binds a plugin
# action to a chord, so a plugin cannot deliver this). Firstmate never rewrites
# the operator's Herdr configuration, so add this to ~/.config/herdr/config.toml
# by hand and reload with `herdr server reload-config`:
#
#   [[keys.command]]
#   key = "prefix+alt+n"
#   type = "shell"
#   command = "env FM_HOME=<your home> <firstmate>/bin/fm-cockpit.sh next"
#
#   [[keys.command]]
#   key = "prefix+alt+p"
#   type = "shell"
#   command = "env FM_HOME=<your home> <firstmate>/bin/fm-cockpit.sh prev"
#
# focus-listen reacts to Herdr's own focus events so that selecting an agent in
# the sidebar places it in the viewport instead of leaving the view on that
# agent's tab. It holds a single-flight lock per home, moves only panes this
# home's own task records claim, and exits when the frame stops being live.
# Nothing depends on it: every worker it is not running for stays on an ordinary
# labelled tab, exactly as on a home that never adopted a cockpit. --once
# handles a single subscription window and returns, for tests and for a
# caller that prefers to re-arm it itself. Adoption starts it detached and
# best-effort under that same stale-owner-recovering lock. A dead listener only
# costs the automatic return click because every parked pane remains reachable
# on its ordinary labelled tab, and parking moves rather than closes the pane.
# A listener exits when its recorded frame dies, while session-start adoption
# re-arms a replacement without changing that frame or any pane.
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
  show) ACTION=$1 ;;
  next|prev) ACTION=$1 ;;
  focus-listen) ACTION=$1 ;;
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
elif [ "$ACTION" = show ]; then
  [ "$#" -eq 2 ] || { usage >&2; exit 2; }
  SHOW_ID=$2
  case "$SHOW_ID" in
    ''|*[!A-Za-z0-9._-]*) echo "fm-cockpit: task id must be a plain identifier" >&2; exit 2 ;;
  esac
elif [ "$ACTION" = next ] || [ "$ACTION" = prev ]; then
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
elif [ "$ACTION" = focus-listen ]; then
  shift
  FOCUS_ONCE=0
  case "${1:-}" in
    '') ;;
    --once) FOCUS_ONCE=1; shift ;;
    *) usage >&2; exit 2 ;;
  esac
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
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
  local label panes rows parked head_state fleet_state
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
  parked=$(printf '%s' "$panes" | jq -r \
    --arg tab "$FM_BACKEND_HERDR_COCKPIT_TAB_ID" '
      [.result.panes[]?
       | select(.tab_id != $tab and ((.label // "") | startswith("fm-")))
       | "  " + .label + " [" + (.agent_status // "unknown") + "] tab=" + .tab_id]
      | if length == 0 then "  none" else join("\n") end
    ' 2>/dev/null || printf '  unreadable')
  printf '%s\n' 'NAVIGATOR Herdr sidebar (all spaces and agents)'
  printf 'PINNED %s head=%s [live]\n' "$label" "$FM_BACKEND_HERDR_COCKPIT_HEAD_PANE_ID"
  printf 'VIEWPORT tab=%s\n%s\n' "$FM_BACKEND_HERDR_COCKPIT_TAB_ID" "$rows"
  printf 'PARKED each on its own tab\n%s\n' "$parked"
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

# Every pane move runs under the same per-session presentation lock that spawn
# and teardown take, so a placement can never interleave with a split or close.
with_presentation_lock() {  # <command...>
  local lock_path attempt=0 rc=1
  if ! declare -F fm_lock_try_acquire >/dev/null 2>&1; then
    # shellcheck source=bin/fm-wake-lib.sh
    . "$SCRIPT_DIR/fm-wake-lib.sh"
  fi
  lock_path=$(fm_backend_herdr_presentation_session_lock_path "$SESSION") || return 1
  while [ "$attempt" -lt 50 ]; do
    if fm_lock_try_acquire "$lock_path"; then
      "$@"
      rc=$?
      fm_lock_release "$lock_path" || true
      return "$rc"
    fi
    sleep 0.1
    attempt=$((attempt + 1))
  done
  echo "COCKPIT: another presentation change holds this session's lock; no pane was moved." >&2
  return 1
}

if [ "$ACTION" = show ]; then
  if ! fm_backend_herdr_cockpit_binding_live "$STATE" "$FM_HOME" "$SESSION"; then
    echo "COCKPIT: this home has no live complete frame; nothing was moved." >&2
    exit 1
  fi
  SHOW_PANE=$(fm_backend_herdr_cockpit_meta_field "$STATE/$SHOW_ID.meta" herdr_pane_id) || {
    printf 'COCKPIT: no herdr endpoint is recorded for %s.\n' "$SHOW_ID" >&2
    exit 1
  }
  fm_backend_herdr_cockpit_owned_task "$STATE" "$SESSION" "$SHOW_PANE" "fm-$SHOW_ID" >/dev/null || {
    printf 'COCKPIT: %s is not this home'"'"'s cockpit worker; refusing to move it.\n' "$SHOW_ID" >&2
    exit 1
  }
  with_presentation_lock fm_backend_herdr_cockpit_viewport_place \
    "$STATE" "$FM_HOME" "$SHOW_PANE" "fm-$SHOW_ID" || {
    printf 'COCKPIT: could not place %s in the viewport.\n' "$SHOW_ID" >&2
    exit 1
  }
  fm_backend_herdr_cli "$SESSION" tab focus "$FM_BACKEND_HERDR_COCKPIT_TAB_ID" >/dev/null 2>&1 || true
  printf 'COCKPIT: %s now occupies the viewport alone.\n' "$SHOW_ID"
  exit 0
fi

if [ "$ACTION" = next ] || [ "$ACTION" = prev ]; then
  if ! fm_backend_herdr_cockpit_binding_live "$STATE" "$FM_HOME" "$SESSION"; then
    echo "COCKPIT: this home has no live complete frame; nothing was moved." >&2
    exit 1
  fi
  ROTATED=$(with_presentation_lock fm_backend_herdr_cockpit_rotate \
    "$STATE" "$FM_HOME" "$SESSION" "$ACTION") || {
    echo "COCKPIT: no worker of this home is available to rotate to." >&2
    exit 1
  }
  printf 'COCKPIT: %s now occupies the viewport alone.\n' "$ROTATED"
  exit 0
fi

if [ "$ACTION" = focus-listen ]; then
  if ! fm_backend_herdr_cockpit_binding_live "$STATE" "$FM_HOME" "$SESSION"; then
    echo "COCKPIT: this home has no live complete frame; focus placement not started." >&2
    exit 1
  fi
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  FOCUS_LOCK="$STATE/.cockpit-focus.lock"
  if ! fm_lock_try_acquire "$FOCUS_LOCK"; then
    echo "COCKPIT: focus placement is already running for this home." >&2
    exit 1
  fi
  trap 'fm_lock_release "$FOCUS_LOCK" || true' EXIT INT TERM HUP
  FOCUS_WINDOW=${FM_COCKPIT_FOCUS_WINDOW:-300}
  while :; do
    if ! fm_backend_herdr_cockpit_binding_live "$STATE" "$FM_HOME" "$SESSION"; then
      echo "COCKPIT: frame is no longer live; focus placement stopped and every worker stays on its own tab." >&2
      exit 0
    fi
    SOCKET=$(fm_backend_herdr_socket_path "$SESSION")
    if [ -z "$SOCKET" ]; then
      echo "COCKPIT: this session exposes no control socket; focus placement stopped." >&2
      exit 1
    fi
    mapfile -t READER_CMD < <(fm_backend_herdr_event_reader_cmd)
    while IFS=$'\t' read -r EV_PANE _; do
      [ -n "$EV_PANE" ] || continue
      [ "$EV_PANE" != "@subscribed" ] || continue
      with_presentation_lock fm_backend_herdr_cockpit_focus_place \
        "$STATE" "$FM_HOME" "$SESSION" "$EV_PANE" >/dev/null 2>&1 || true
    done < <("${READER_CMD[@]}" --focus "$SOCKET" "$FOCUS_WINDOW" 2>/dev/null)
    [ "$FOCUS_ONCE" = 0 ] || exit 0
    sleep 1
  done
fi

MODE=adopt
[ "$ACTION" != new ] || MODE=new
fm_backend_herdr_cockpit_adopt "$STATE" "$FM_HOME" "$SESSION" "$MODE" || exit 1

# The subscription is session-wide, but ownership remains home-local: each
# detached listener has its own home's lock and frame record, and focus_place
# accepts only panes claimed by that home's task metadata. Starting is
# deliberately non-fatal because failure leaves every pane on a reachable tab.
# fm_lock_try_acquire recovers a lock whose recorded process is dead, so a
# restart can re-arm without a watchdog, pidfile, or second supervision loop.
nohup "$0" focus-listen </dev/null >/dev/null 2>&1 &
exit 0
