#!/usr/bin/env bash
# fm-fleet-view.sh - narrow status side-panel over fm-fleet-snapshot.sh.
#
# The view is read-only and does not parse fleet files itself.
# The default view answers the three live questions in action order: captain
# decisions, dispatchable queued work, and dispatched work, followed by genuinely
# blocked queued work.
# Unreadable worker state stays under in-flight with a quiet qualifier.
# Finished and failed history is available only through --section.
# --section may be repeated and may carry a comma-separated list, so one render
# can hold any subset of sections. Whatever the caller asks for, the sections are
# emitted in this file's own priority order rather than the order they were
# requested: the reading order is a property of the view, not of its arguments,
# so a caller cannot demote decisions by listing them last.
# Queued readiness, dependency blockers, and active holds come from the snapshot's
# tasks-axi projection; the renderer does not derive backlog state itself.
# READY answers "hand this to a worker now", which is a narrower question than the
# dependency readiness tasks-axi measures. It therefore renders the snapshot's
# dispatch_clear rows plainly and the rest with a "?" marker and the snapshot's
# reason, and its heading counts the two apart whenever any row needs a check.
# No dependency-ready row is dropped: the captain sees the whole queue and the
# count never claims the backlog confirmed more clear work than it did.
# Watch mode uses only bash, jq, terminal control sequences, and sleep; a failed
# snapshot or render prints an explicit degraded panel and retries next redraw.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAPSHOT_CMD="$SCRIPT_DIR/fm-fleet-snapshot.sh"

# shellcheck source=bin/fm-terminal-frame-lib.sh
. "$SCRIPT_DIR/fm-terminal-frame-lib.sh"

usage() {
  cat <<'EOF'
usage: fm-fleet-view.sh [--json] [--watch [interval]] [--section <names>]...
                        [--geometry-command <executable>]

Render a narrow, prioritized fleet side panel from fm-fleet-snapshot.sh.
Use --json to print the complete underlying snapshot.
Use --watch to redraw every 5 seconds, or provide a positive interval in seconds.
Use --geometry-command to read "<columns> <lines>" from an executable before
every redraw when an embedding surface has geometry more authoritative than
the pane pty.
Use --section to render a subset of: waiting, ready, in-flight, blocked,
finished, failed. The flag may be repeated and accepts a comma-separated list;
the sections are always rendered in that priority order, whatever order they
were asked for. Without --section the panel renders its default banner:
a heading followed by waiting, ready, in-flight, and blocked.

READY holds every queued task with no open dependency and no active hold. Rows
that can be handed to a worker now are listed with a bullet; rows the backlog
cannot confirm are listed with a "?" and the reason, and the heading counts the
two apart.
EOF
}

# The one priority order every render obeys, and the order the checks below
# validate against.
SECTION_ORDER="waiting ready in-flight blocked finished failed"
DEFAULT_SECTIONS="waiting ready in-flight blocked"

FORMAT=panel
WATCH=0
INTERVAL=5
REQUESTED=
SECTION_SET=0
GEOMETRY_COMMAND=
while [ $# -gt 0 ]; do
  case "$1" in
    --json) FORMAT=json ;;
    --section)
      [ $# -gt 1 ] || { usage >&2; exit 2; }
      shift
      REQUESTED="$REQUESTED,$1"
      SECTION_SET=1
      ;;
    --section=*)
      REQUESTED="$REQUESTED,${1#--section=}"
      SECTION_SET=1
      ;;
    --watch)
      WATCH=1
      if [ $# -gt 1 ] && [[ $2 != -* ]]; then
        shift
        INTERVAL=$1
      fi
      ;;
    --watch=*) WATCH=1; INTERVAL=${1#--watch=} ;;
    --geometry-command)
      [ $# -gt 1 ] || { usage >&2; exit 2; }
      shift
      GEOMETRY_COMMAND=$1
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

SECTIONS=$DEFAULT_SECTIONS
if [ "$SECTION_SET" = 1 ]; then
  requested_name=
  known=
  selected=
  while IFS= read -r requested_name; do
    [ -n "$requested_name" ] || continue
    known=0
    for candidate in $SECTION_ORDER; do
      [ "$candidate" != "$requested_name" ] || known=1
    done
    if [ "$known" != 1 ]; then
      echo "fm-fleet-view: unknown section: $requested_name" >&2
      usage >&2
      exit 2
    fi
    selected="$selected $requested_name"
  done <<EOF
$(printf '%s' "${REQUESTED#,}" | tr -d '[:space:]' | tr ',' '\n')
EOF
  if [ -z "$selected" ]; then
    echo "fm-fleet-view: --section needs at least one section name" >&2
    usage >&2
    exit 2
  fi
  # Rebuilt from the priority order rather than kept as given, so a repeated or
  # out-of-order request still renders exactly once and in the same place.
  SECTIONS=
  for candidate in $SECTION_ORDER; do
    case " $selected " in
      *" $candidate "*) SECTIONS="$SECTIONS $candidate" ;;
    esac
  done
  SECTIONS=${SECTIONS# }
fi

if [ "$FORMAT" = json ] && [ "$WATCH" = 1 ]; then
  echo "fm-fleet-view: --json and --watch cannot be combined" >&2
  exit 2
fi
if [ "$WATCH" = 1 ]; then
  if ! [[ $INTERVAL =~ ^[0-9]+([.][0-9]+)?$ ]] || [[ $INTERVAL =~ ^0+([.]0+)?$ ]]; then
    echo "fm-fleet-view: watch interval must be a positive number" >&2
    exit 2
  fi
fi

if [ "$FORMAT" = json ]; then
  "$SNAPSHOT_CMD" --json
  exit $?
fi

command -v jq >/dev/null 2>&1 || { echo "fm-fleet-view: jq not found" >&2; exit 1; }

SECTIONS_JSON=$(printf '%s' "$SECTIONS" | tr ' ' '\n' | jq -Rn '[inputs | select(length > 0)]')
LAST_SECTION=${SECTIONS##* }
# The framed heading belongs to the whole-fleet panel. A caller asking for named
# sections is filling part of a larger frame and supplies its own.
BANNER=true
[ "$SECTION_SET" = 0 ] || BANNER=false

# COLUMNS and LINES stay the explicit override: an embedding caller that has
# already spent part of the frame states the budget it has left rather than
# re-measuring the whole pane.
terminal_width() {
  local width=${COLUMNS:-}
  case "$width" in
    ''|*[!0-9]*) width=$(fm_terminal_dimension cols || true) ;;
  esac
  case "$width" in ''|*[!0-9]*) width=60 ;; esac
  [ "$width" -ge 20 ] || width=20
  printf '%s\n' "$width"
}

terminal_height() {
  local height=${LINES:-}
  case "$height" in
    ''|*[!0-9]*) height=$(fm_terminal_dimension lines || true) ;;
  esac
  case "$height" in ''|*[!0-9]*) height=40 ;; esac
  [ "$height" -ge 2 ] || height=2
  printf '%s\n' "$height"
}

authoritative_geometry() {
  local geometry width height extra
  [ -n "$GEOMETRY_COMMAND" ] || return 1
  [ -x "$GEOMETRY_COMMAND" ] || return 1
  geometry=$("$GEOMETRY_COMMAND") || return 1
  read -r width height extra <<EOF
$geometry
EOF
  [ -z "${extra:-}" ] || return 1
  case "$width:$height" in
    *[!0-9:]*|:*|*:) return 1 ;;
  esac
  [ "$width" -gt 0 ] && [ "$height" -gt 0 ] || return 1
  printf '%s %s\n' "$width" "$height"
}

render_once() {
  local width height snapshot rendered geometry
  if [ -n "$GEOMETRY_COMMAND" ]; then
    if ! geometry=$(authoritative_geometry); then
      printf '%s\n' "FLEET VIEW DEGRADED" \
        "Drawn pane geometry unavailable; retrying on the next redraw."
      return 1
    fi
    width=${geometry%% *}
    height=${geometry#* }
  else
    width=$(terminal_width)
    height=$(terminal_height)
  fi
  if ! snapshot=$("$SNAPSHOT_CMD" --json); then
    printf '%s\n' "FLEET VIEW DEGRADED" "Snapshot unavailable; retrying on the next redraw."
    return 1
  fi

  if ! rendered=$(printf '%s\n' "$snapshot" | jq -r --argjson width "$width" \
    --argjson sections "$SECTIONS_JSON" --arg last "$LAST_SECTION" \
    --argjson banner "$BANNER" '
    # One section is rendered when it was selected, and separated from the next
    # one only while another selected section still follows it.
    def wanted($name): ($sections | index($name)) != null;
    def gap($name): if $last == $name then empty else "" end;
    def clean: tostring | gsub("[[:space:]]+"; " ");
    def clip($n):
      clean
      | if length <= $n then .
        elif $n <= 1 then .[:$n]
        else .[:($n - 1)] + "…" end;
    def line($prefix; $value): $prefix + ($value | clip(($width - ($prefix | length)) | if . < 1 then 1 else . end));
    def task_title($t): ($t.backlog.title // $t.project // $t.id // "unknown");
    def task_step($t):
      (($t.current_state.detail // "") as $detail
       | if $detail != "" then $detail else ($t.hints.last_event_text // "unknown") end)
      | sub("^[a-z-]+( \\[[^]]+\\])?:[[:space:]]*"; "")
      | if . == "" then "unknown" else . end;
    # The snapshot decides which rows it cannot confirm and why; this turns each
    # structured reason into plain captain-facing wording. An unknown reason
    # still renders, so a newer snapshot never silently presents unconfirmed
    # work as dispatchable.
    def review_text:
      (.dispatch_review // [])
      | map(if .reason == "no_instructions" then "needs instructions"
            elif .reason == "unlisted_dependency" then
              "needs " + ((.ids // []) | join(",")) + ", not on the backlog"
            else "needs a check" end)
      | join("; ");
    def task_artifact($t):
      ($t.pr.url // $t.backlog.pr_url // (if $t.paths.report.present then $t.paths.report.path else null end));
    def waiting_on_merge($t):
      ($t.current_state.state // "") == "done"
      and ($t.backlog.state // "") == "in_flight"
      and (($t.pr.url // $t.backlog.pr_url // null) != null);

    . as $snapshot
    | ([.tasks[]?] | sort_by(.id)) as $tasks
    | ([$tasks[].id] | unique) as $current_task_ids
    | ([.backlog.records[]?
        | select(.state == "queued" and .structured == true and .captain_actionable == true)]) as $captain_held
    | ([.tasks[]? as $task
        | ($task.hints.open_decisions // [])[]?
        | {id:($task.id // "unknown"),verb:(.verb // "needs-decision"),
           summary:(.summary // "reason unavailable"),artifact:task_artifact($task)}]) as $decision_waiting
    | (($decision_waiting
       + [$captain_held[]
          | {id:(.id // "unknown"),verb:"needs-decision",
             summary:(.hold // .blocked_reason // .body_excerpt // .title // "reason unavailable"),artifact:null}]
       + [$tasks[]
          | select(waiting_on_merge(.))
          | {id:(.id // "unknown"),verb:"merge",
             summary:"merge approval pending",
             artifact:task_artifact(.)}])
       | reduce .[] as $row ([];
           if ([.[].id] | index($row.id)) == null then . + [$row] else . end)
       | sort_by([if .verb == "needs-decision" then 0 else 1 end, .id])) as $waiting
    | ([$waiting[].id] | unique) as $waiting_ids
    | ([$tasks[]
        | select((.current_state.state // "unknown") == "done" and (waiting_on_merge(.) | not))
        | {id:(.id // "unknown"),title:task_title(.),summary:task_step(.),artifact:task_artifact(.)}]) as $live_finished
    | ([.backlog.records[]?
        | select(.state == "done" and .structured == true
                 and ((.id as $id | $current_task_ids | index($id)) == null))
        | {id,title,summary:((.completion.verb // "done") + (if (.completion.date // "") == "" then "" else " " + .completion.date end)),
           artifact:(.pr_url // .report_path // .local_note // null),completion}]
       + [(.secondmate_landed.records // [])[]?
          | select((.id as $id | $current_task_ids | index($id)) == null)
          | {id,title,summary:((.completion.verb // "done") + (if (.completion.date // "") == "" then "" else " " + .completion.date end)),
             artifact:(.pr_url // .report_path // .local_note // null),completion}]
       | sort_by([(.completion.date // ""),(.id // "")]) | reverse) as $history_finished
    | (reduce ($live_finished + $history_finished)[] as $row
         ([]; if ([.[].id] | index($row.id)) == null then . + [$row] else . end)) as $finished
    | ([$tasks[] | select((.current_state.state // "unknown") == "failed")]) as $failed
    | ([$tasks[]
        | (.current_state.state // "unknown") as $state
        | select($state != "done" and $state != "failed")
        | select(.id as $id | $waiting_ids | index($id) | not)] | sort_by(.id)) as $in_flight
    | ([.backlog.records[]?
        | select(.state == "queued" and .structured == true and .dispatchable == true)]) as $ready
    | ([$ready[] | select(.dispatch_clear == true)]) as $ready_clear
    | ([$ready[] | select(.dispatch_clear != true)]) as $ready_review
    | ([.backlog.records[]?
        | select(.state == "queued" and .structured == true and .blocked == true)]) as $blocked
    | (if $banner then
         ("=" * $width),
         ("FLEET STATUS" | clip($width)),
         ("=" * $width),
         ""
       else empty end),
      (if wanted("waiting") then
      ("YOUR DECISIONS (\($waiting | length))" | clip($width)),
      (if ($waiting | length) == 0 then
         "  None."
       else
         $waiting[]
         | line("! "; (.id + " · " + .summary
                        + (if .artifact == null then "" else " · " + .artifact end)))
       end),
      gap("waiting")
       else empty end),
      (if wanted("ready") then
       ("READY (\(if ($ready_review | length) == 0 then ($ready_clear | length | tostring)
                  else "\($ready_clear | length) clear, \($ready_review | length) need a check"
                  end))" | clip($width)),
       (if ($ready | length) == 0 then
          "  None."
        else
          ($ready_clear[] | line("• "; ((.id // "unknown") + " · " + (.title // "unknown")))),
          # The reason replaces the title rather than following it: on a narrow
          # pane the title would push the reason out of the row, which is the
          # one thing this line exists to say. Firstmate ids read as titles.
          ($ready_review[] | line("? "; ((.id // "unknown") + " · " + review_text)))
        end),
       gap("ready")
       else empty end),
      (if wanted("in-flight") then
       ("IN FLIGHT (\($in_flight | length))" | clip($width)),
       (if ($in_flight | length) == 0 then
          "  None."
        else
          $in_flight[]
          | (.current_state.state // "unknown") as $state
          | line("• "; ((.id // "unknown")
                        + (if $state == "working" then ""
                           elif $state == "unknown" then " · state unavailable"
                           else " · " + $state end)
                        + " · " + task_title(.)))
        end),
       gap("in-flight")
       else empty end),
      (if wanted("blocked") then
       ("BLOCKED (\($blocked | length))" | clip($width)),
       (if ($blocked | length) == 0 then
          "  None."
        else
          $blocked[]
          | line("• "; ((.id // "unknown") + " ← " + ((.unresolved_blocker_ids // []) | join(","))
                        + (if (.blocked_reason // "") == "" then "" else " · " + .blocked_reason end)))
        end),
       gap("blocked")
       else empty end),
      (if wanted("finished") then
      ("FINISHED (showing \([($finished[:5])[]] | length) of \($finished | length))" | clip($width)),
      (if ($finished | length) == 0 then
         "  Nothing has finished successfully."
       else
         $finished[:5][]
         | line("• "; ((.id // "unknown") + " · " + (.title // "unknown"))),
           line("  "; (.summary // "done")),
           (if .artifact == null then empty else line("  "; .artifact) end)
       end),
      gap("finished")
       else empty end),
      (if wanted("failed") then
      ("FAILED (\($failed | length))" | clip($width)),
      (if ($failed | length) == 0 then
         "  No failed tasks."
       else
         $failed[]
         | line("• "; ((.id // "unknown") + " · " + task_title(.))),
           line("  "; task_step(.))
       end),
      gap("failed")
       else empty end),
      empty
  '); then
    echo "FLEET VIEW DEGRADED"
    echo "Snapshot data could not be rendered; retrying on the next redraw."
    return 1
  fi
  fm_terminal_fit_height "$height" "$rendered" "$width"
}

if [ "$WATCH" = 1 ]; then
  trap 'fm_terminal_watch_reset; exit 0' INT TERM HUP
  while :; do
    frame=$(render_once) || true
    fm_terminal_paint_frame "$frame"
    sleep "$INTERVAL"
  done
fi

render_once
