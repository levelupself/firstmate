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
# Visible work is grouped under compact project headers in every live section.
# Each project receives the same row cap for the available pane height, and its
# header reports that project's hidden count instead of one global list tail.
# An authoritative drawn rectangle bounds the frame together with the pane's own
# pty rather than instead of it: the drawn rectangle is what the operator can
# see and the pty is where text wraps, so the frame honours whichever is
# smaller.
# Watch mode uses only bash, jq, terminal control sequences, and sleep. A failed
# snapshot or render prints an explicit degraded panel. Drawn-geometry failures
# recover within three transient reads or evict the exact bound pane once.
#
# A watched banner inside an adopted cockpit frame paints only while that home's
# frame record still names ITS pane, and only one such banner paints a pane at a
# time. The frame record written by bin/backends/herdr.sh is the sole authority
# for both questions - this file reads it through that adapter's own reader
# rather than keeping a second registry of who is painting what. Everywhere else
# the banner is the operator's own panel and nothing here constrains it.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAPSHOT_CMD="$SCRIPT_DIR/fm-fleet-snapshot.sh"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
PAINTER_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PAINTER_STATE="${FM_STATE_OVERRIDE:-$PAINTER_HOME/state}"

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
the pane pty. The frame is bounded by the smaller of that rectangle and the
pane's own measurable size, because exceeding either one wraps and scrolls it.
Use --section to render a subset of: waiting, ready, in-flight, blocked,
finished, failed. The flag may be repeated and accepts a comma-separated list;
the sections are always rendered in that priority order, whatever order they
were asked for. Without --section the panel renders its default banner:
a heading followed by waiting, ready, in-flight, and blocked.

READY holds every queued task with no open dependency and no active hold. Rows
that can be handed to a worker now are listed with a bullet; rows the backlog
cannot confirm are listed with a "?" and the reason, and the heading counts the
two apart.

Inside a Herdr cockpit frame, --watch paints only while that home's frame
record still names this pane for these sections, and only one banner paints a
recorded pane at a time; a banner the frame stops naming retires and leaves the
pane alone. Anywhere else --watch is unconstrained, including as the fallback
panel every cockpit-unavailable message points at.

Live sections group rows by project and divide limited row capacity evenly
between those projects. A project header reports its own hidden-row count.
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

# normalize_sections: one comma-separated section list rebuilt in the priority
# order above, so a repeated or out-of-order request still renders exactly once
# and in the same place. Publishes NORMALIZED_SECTIONS and returns 0, or returns
# non-zero with UNKNOWN_SECTION naming the section this view does not have (or
# empty when the list held no names at all). Both results are published rather
# than printed: a command substitution would run this in a subshell and discard
# whichever of the two the caller did not capture.
#
# The requested list and the frame record's own recorded --section argument are
# both read through this, so "the sections this banner renders" and "the
# sections the frame recorded for this pane" are compared as the same value
# rather than as two spellings that happen to agree today.
NORMALIZED_SECTIONS=
UNKNOWN_SECTION=
normalize_sections() {  # <comma-separated names>
  local raw=$1 name known candidate selected='' normalized=''
  NORMALIZED_SECTIONS=
  UNKNOWN_SECTION=
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    known=0
    for candidate in $SECTION_ORDER; do
      [ "$candidate" != "$name" ] || known=1
    done
    if [ "$known" != 1 ]; then
      UNKNOWN_SECTION=$name
      return 1
    fi
    selected="$selected $name"
  done <<EOF
$(printf '%s' "$raw" | tr -d '[:space:]' | tr ',' '\n')
EOF
  [ -n "$selected" ] || return 1
  for candidate in $SECTION_ORDER; do
    case " $selected " in
      *" $candidate "*) normalized="$normalized $candidate" ;;
    esac
  done
  NORMALIZED_SECTIONS=${normalized# }
}

SECTIONS=$DEFAULT_SECTIONS
if [ "$SECTION_SET" = 1 ]; then
  if ! normalize_sections "${REQUESTED#,}"; then
    if [ -n "$UNKNOWN_SECTION" ]; then
      echo "fm-fleet-view: unknown section: $UNKNOWN_SECTION" >&2
    else
      echo "fm-fleet-view: --section needs at least one section name" >&2
    fi
    usage >&2
    exit 2
  fi
  SECTIONS=$NORMALIZED_SECTIONS
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
  local geometry width height extra status
  [ -n "$GEOMETRY_COMMAND" ] || return 1
  [ -x "$GEOMETRY_COMMAND" ] || return 1
  geometry=$("$GEOMETRY_COMMAND")
  status=$?
  if [ "$status" -ne 0 ]; then
    [ "$status" -ne 64 ] || return 64
    return 75
  fi
  read -r width height extra <<EOF
$geometry
EOF
  [ -z "${extra:-}" ] || return 75
  case "$width:$height" in
    *[!0-9:]*|:*|*:) return 75 ;;
  esac
  [ "$width" -gt 0 ] && [ "$height" -gt 0 ] || return 75
  printf '%s %s\n' "$width" "$height"
}

# The drawn rectangle and the pty are two different boundaries, and a frame has
# to respect both. The drawn rectangle says how much of the pane is actually
# shown, so it wins when the pty reports a larger size - that is the Herdr
# defect --geometry-command exists for. But WRAPPING happens at the pty, so a
# drawn rectangle wider or taller than the pty (measured live on herdr 0.8.0: a
# 54-column drawn rectangle over a 53-column pty) would wrap every full-width
# row, multiply the frame's physical height, scroll the pane, and leave
# fragments of consecutive redraws on screen at once. Taking the smaller of the
# two is correct in both directions: over-clipping only narrows the content,
# while exceeding either boundary destroys the frame.
#
# Only a real measurement clamps. fm_terminal_dimension fails rather than
# guessing when it cannot read the pane, and a built-in default must never
# override the authoritative drawn budget.
clamp_to_pty() {  # <drawn> <lines|cols> -> the value to paint to
  local drawn=$1 pty
  if pty=$(fm_terminal_dimension "$2") && [ "$pty" -gt 0 ] && [ "$pty" -lt "$drawn" ]; then
    printf '%s\n' "$pty"
  else
    printf '%s\n' "$drawn"
  fi
}

render_once() {
  local width height snapshot rendered geometry status
  if [ -n "$GEOMETRY_COMMAND" ]; then
    if geometry=$(authoritative_geometry); then
      :
    else
      status=$?
      if [ "$status" -eq 64 ]; then
        printf '%s\n' "FLEET VIEW EVICTING" \
          "Authoritative pane geometry is permanently unavailable."
        return 64
      fi
      printf '%s\n' "FLEET VIEW DEGRADED" \
        "Drawn pane geometry is transiently unavailable."
      return 75
    fi
    width=$(clamp_to_pty "${geometry%% *}" cols)
    height=$(clamp_to_pty "${geometry#* }" lines)
  else
    width=$(terminal_width)
    height=$(terminal_height)
  fi
  if ! snapshot=$("$SNAPSHOT_CMD" --json); then
    printf '%s\n' "FLEET VIEW DEGRADED" "Snapshot unavailable; retrying on the next redraw."
    return 1
  fi

  if ! rendered=$(printf '%s\n' "$snapshot" | jq -r --argjson width "$width" \
    --argjson height "$height" \
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
    def middle_clip($n):
      clean
      | if length <= $n then .
        elif $n <= 1 then .[:$n]
        else (($n - 1) / 2 | floor) as $left
          | .[:$left] + "…" + .[-($n - $left - 1):]
        end;
    def project_label($repo; $project):
      if (($repo // "") | tostring | length) > 0 then
        (($repo | tostring | split("/") | last | sub("[.]git$"; "")) as $name
         | if ($name | ascii_downcase) == "firstmate" then "Firstmate" else $name end)
      else
        (($project // "") | tostring) as $name
        | if ($name == "firstmate" or ($name | endswith("/firstmate"))) then "Firstmate"
          elif ($name | contains("/projects/")) then ($name | split("/") | last)
          elif ($name != "" and ($name | contains("/") | not)) then $name
          else "No repository"
          end
      end;
    def task_project($t): project_label($t.backlog.repo; $t.project);
    def backlog_project($row): project_label($row.repo; null);
    def row_line($row):
      (($width - ($row.marker | length)) | if . < 1 then 1 else . end) as $available
      | ($row.joiner // " · ") as $joiner
      | ($row.id | middle_clip($available)) as $id
      | if (($row.id | clean | length) + ($joiner | length) + ($row.detail | clean | length)) <= $available then
          line($row.marker; ($row.id + $joiner + $row.detail))
        elif ($row.id | clean | length) <= (($available * 3 / 5) | floor) then
          line($row.marker; ($row.id + $joiner + $row.detail))
        else $row.marker + $id
        end;
    # A project header costs one row. The remaining rows are divided evenly
    # between projects, so every group gets one task before any group gets a
    # second. Unused capacity is intentionally not reassigned: the policy is
    # deterministic for the rendered group set, and one noisy project can never
    # consume the share of another project.
    def grouped_lines($rows; $cap):
      if ($rows | length) == 0 then []
      else
        ($rows | sort_by([.project_sort, .state_rank, .priority, .order, .id]) | group_by(.project)) as $groups
        | ($groups | length) as $group_count
        | [range(0; $group_count) as $index
           | ($groups[$index]) as $group
           | ([($group | length), $cap] | min) as $shown
           | (($group | length) - $shown) as $hidden
           | ("[" + $group[0].project + "]"
              + (if $hidden > 0 then " · +\($hidden) hidden" else "" end) | middle_clip($width)),
             ($group[:$shown][] | row_line(.))]
      end;
    def group_count($rows): [$rows[].project] | unique | length;
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
           summary:(.summary // "reason unavailable"),artifact:task_artifact($task),
           project:task_project($task),priority:($task.backlog.priority // 999999),
           order:($task.backlog.order // 999999)}]) as $decision_waiting
    | (($decision_waiting
       + [$captain_held[]
          | {id:(.id // "unknown"),verb:"needs-decision",
             summary:(.hold // .blocked_reason // .body_excerpt // .title // "reason unavailable"),artifact:null,
             project:backlog_project(.),priority:(.priority // 999999),order:(.order // 999999)}]
       + [$tasks[]
          | select(waiting_on_merge(.))
          | {id:(.id // "unknown"),verb:"merge",
             summary:"merge approval pending",
             artifact:task_artifact(.),project:task_project(.),
             priority:(.backlog.priority // 999999),order:(.backlog.order // 999999)}])
       | reduce .[] as $row ([];
           if ([.[].id] | index($row.id)) == null then . + [$row] else . end)
       | map(. + {marker:"! ",detail:(.summary + (if .artifact == null then "" else " · " + .artifact end)),
                  project_sort:(.project | ascii_downcase),
                  state_rank:(if .verb == "needs-decision" then 0 else 1 end)})
       | sort_by([.project_sort,.state_rank,.priority,.order,.id])) as $waiting
    | ([$waiting[].id] | unique) as $waiting_ids
    | ([$tasks[]
        | select((.current_state.state // "unknown") == "done" and (waiting_on_merge(.) | not))
        | {id:(.id // "unknown"),title:task_title(.),summary:task_step(.),artifact:task_artifact(.),
           repo:(.backlog.repo // null),project:(.project // null)}]) as $live_finished
    | ([.backlog.records[]?
        | select(.state == "done" and .structured == true
                 and ((.id as $id | $current_task_ids | index($id)) == null))
        | {id,title,summary:((.completion.verb // "done") + (if (.completion.date // "") == "" then "" else " " + .completion.date end)),
           artifact:(.pr_url // .report_path // .local_note // null),completion,repo,project:null}]
       + [(.secondmate_landed.records // [])[]?
          | select((.id as $id | $current_task_ids | index($id)) == null)
          | {id,title,summary:((.completion.verb // "done") + (if (.completion.date // "") == "" then "" else " " + .completion.date end)),
             artifact:(.pr_url // .report_path // .local_note // null),completion,repo:(.repo // null),project:(.project // null)}]
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
    | ([$ready_clear[] | {id:(.id // "unknown"),detail:(.title // "unknown"),marker:"• ",
                         project:backlog_project(.),project_sort:(backlog_project(.) | ascii_downcase),
                         state_rank:0,priority:(.priority // 999999),order:(.order // 999999)}]
       + [$ready_review[] | {id:(.id // "unknown"),detail:review_text,marker:"? ",
                            project:backlog_project(.),project_sort:(backlog_project(.) | ascii_downcase),
                            state_rank:1,priority:(.priority // 999999),order:(.order // 999999)}]) as $ready_rows
    | ([$in_flight[]
        | (.current_state.state // "unknown") as $state
        | {id:(.id // "unknown"),marker:"• ",project:task_project(.),
           project_sort:(task_project(.) | ascii_downcase),
           state_rank:(if $state == "working" then 0 elif $state == "unknown" then 2 else 1 end),
           priority:(.backlog.priority // 999999),order:(.backlog.order // 999999),
           detail:((if $state == "working" then ""
                    elif $state == "unknown" then "state unavailable · "
                    else $state + " · " end) + task_title(.))}]) as $in_flight_rows
    | ([$blocked[]
        | {id:(.id // "unknown"),marker:"• ",joiner:" ",project:backlog_project(.),
           project_sort:(backlog_project(.) | ascii_downcase),state_rank:0,
           priority:(.priority // 999999),order:(.order // 999999),
           detail:("← " + ((.unresolved_blocker_ids // []) | join(","))
                   + (if (.blocked_reason // "") == "" then "" else " · " + .blocked_reason end))}]) as $blocked_rows
    | ((if wanted("waiting") then group_count($waiting) else 0 end)
       + (if wanted("ready") then group_count($ready_rows) else 0 end)
       + (if wanted("in-flight") then group_count($in_flight_rows) else 0 end)
       + (if wanted("blocked") then group_count($blocked_rows) else 0 end)) as $group_count
    | (($sections | length) + (($sections | length) - 1)
       + (if $banner then 4 else 0 end)
       + (if wanted("waiting") and ($waiting | length) == 0 then 1 else 0 end)
       + (if wanted("ready") and ($ready | length) == 0 then 1 else 0 end)
       + (if wanted("in-flight") and ($in_flight | length) == 0 then 1 else 0 end)
       + (if wanted("blocked") and ($blocked | length) == 0 then 1 else 0 end)) as $active_fixed_rows
    | ($active_fixed_rows
       + (if wanted("finished") then
            if ($finished | length) == 0 then 1
            else [$finished[:5][] | 2 + (if .artifact == null then 0 else 1 end)] | add
            end
          else 0 end)
       + (if wanted("failed") then
            if ($failed | length) == 0 then 1 else 2 * ($failed | length) end
          else 0 end)) as $fixed_rows
    | (if $group_count == 0 then 0
       elif $height >= ($active_fixed_rows + (2 * $group_count)) then
         ([1, ((($height - $fixed_rows - $group_count) / $group_count) | floor)] | max)
       else 0
       end) as $group_cap
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
         grouped_lines($waiting; $group_cap)[]
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
          grouped_lines($ready_rows; $group_cap)[]
        end),
       gap("ready")
       else empty end),
      (if wanted("in-flight") then
       ("IN FLIGHT (\($in_flight | length))" | clip($width)),
        (if ($in_flight | length) == 0 then
          "  None."
        else
          grouped_lines($in_flight_rows; $group_cap)[]
        end),
       gap("in-flight")
       else empty end),
      (if wanted("blocked") then
       ("BLOCKED (\($blocked | length))" | clip($width)),
        (if ($blocked | length) == 0 then
          "  None."
        else
          grouped_lines($blocked_rows; $group_cap)[]
        end),
       gap("blocked")
       else empty end),
      (if wanted("finished") then
      ("FINISHED (showing \([($finished[:5])[]] | length) of \($finished | length))" | clip($width)),
      (if ($finished | length) == 0 then
         "  Nothing has finished successfully."
       else
         $finished[:5][]
         | line("• "; ("[" + project_label(.repo; .project) + "] " + (.id // "unknown") + " · " + (.title // "unknown"))),
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
         | line("• "; ("[" + task_project(.) + "] " + (.id // "unknown") + " · " + task_title(.))),
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

# --- painter ownership ------------------------------------------------------
#
# Only watch mode is constrained. A one-shot render is a read, and the cockpit
# panel embeds exactly that read from its own pinned head pane, which is
# deliberately not a fleet pane.

# painter_binding: how this watched banner relates to this home's adopted
# cockpit frame. Publishes PAINTER_BINDING as one of:
#
#   standalone  no frame record answers for this pane - the documented
#               fm-fleet-view.sh --watch fallback panel, an ordinary pane on
#               another tab, or any non-Herdr runtime. Nothing constrains it.
#   bound       the frame records THIS pane, for exactly the sections this
#               banner renders.
#   unbound     the frame is recorded for this home and session and this pane
#               sits inside it, but the frame does not record this pane as the
#               painter of these sections. A region rebuilt around new panes
#               leaves the previous generation here.
#
# Membership decides first and the tab only breaks the remaining tie, so a
# recorded fleet pane is bound whatever tab the record claims, and an
# unrecorded pane is judged only against the frame it actually sits in.
PAINTER_BINDING=standalone
PAINTER_BOUND_ONCE=0
painter_binding() {
  local recorded fleet_state index=0 pane
  if [ "$PAINTER_BOUND_ONCE" = 1 ]; then
    PAINTER_BINDING=unbound
  else
    PAINTER_BINDING=standalone
  fi
  [ -n "${HERDR_PANE_ID:-}" ] || return 0
  if ! declare -F fm_backend_herdr_cockpit_record_snapshot >/dev/null 2>&1; then
    # shellcheck source=bin/fm-backend.sh
    . "$SCRIPT_DIR/fm-backend.sh" 2>/dev/null || return 0
    fm_backend_source herdr 2>/dev/null || return 0
  fi
  fm_backend_herdr_cockpit_record_snapshot "$PAINTER_STATE" "$PAINTER_HOME" || return 0
  # A version-1 record predates the fleet region and records no painter at all.
  [ -n "$FM_BACKEND_HERDR_COCKPIT_FLEET_PANE_IDS" ] || return 0
  [ "$FM_BACKEND_HERDR_COCKPIT_SESSION" = "${HERDR_SESSION:-default}" ] || return 0
  while IFS= read -r pane; do
    [ -n "$pane" ] || continue
    index=$((index + 1))
    [ "$pane" = "$HERDR_PANE_ID" ] || continue
    if ! fm_backend_herdr_cockpit_pane_matches \
      "$FM_BACKEND_HERDR_COCKPIT_SESSION" "$HERDR_PANE_ID" \
      "$FM_BACKEND_HERDR_COCKPIT_WORKSPACE_ID" "$FM_BACKEND_HERDR_COCKPIT_TAB_ID"; then
      PAINTER_BINDING=unbound
      return 0
    fi
    recorded=$(fm_backend_herdr_cockpit_fleet_pane_section "$index")
    # No recorded argument is the version-2 shape: one pane, launched before the
    # flag existed, so there is no section to disagree with.
    if [ -z "$recorded" ]; then
      fleet_state=$(fm_backend_herdr_cockpit_fleet_state \
        "$FM_BACKEND_HERDR_COCKPIT_SESSION" "$HERDR_PANE_ID" "$PAINTER_HOME" '' strict)
    elif normalize_sections "$recorded" && [ "$NORMALIZED_SECTIONS" = "$SECTIONS" ]; then
      fleet_state=$(fm_backend_herdr_cockpit_fleet_state \
        "$FM_BACKEND_HERDR_COCKPIT_SESSION" "$HERDR_PANE_ID" "$PAINTER_HOME" "$recorded" strict)
    else
      PAINTER_BINDING=unbound
      return 0
    fi
    if [ "$fleet_state" = live ]; then
      PAINTER_BINDING=bound
      PAINTER_BOUND_ONCE=1
    else
      PAINTER_BINDING=unbound
    fi
    return 0
  done <<EOF
$(printf '%s' "$FM_BACKEND_HERDR_COCKPIT_FLEET_PANE_IDS" | tr ',' '\n')
EOF
  # Not recorded anywhere in the region. Inside the recorded frame that makes it
  # a stranded painter; anywhere else it is the operator's own panel.
  [ "${HERDR_TAB_ID:-}" = "$FM_BACKEND_HERDR_COCKPIT_TAB_ID" ] || return 0
  PAINTER_BINDING=unbound
}

painter_retire() {  # <reason>
  fm_terminal_watch_reset
  printf 'fm-fleet-view: %s is not this frame'"'"'s recorded painter for these sections; %s\n' \
    "$HERDR_PANE_ID" "$1" >&2
}

painter_evict() {  # <reason>
  local reason=$1
  fm_terminal_watch_reset
  printf 'fm-fleet-view: EVICTING fleet pane %s: %s\n' "$HERDR_PANE_ID" "$reason" >&2
  fm_terminal_paint_frame "FLEET VIEW EVICTING
$reason" || true
  if ! fm_backend_herdr_cli "${HERDR_SESSION:-default}" pane close "$HERDR_PANE_ID" >/dev/null 2>&1; then
    printf 'fm-fleet-view: exact pane eviction failed for %s; the painter is stopping without another close attempt.\n' \
      "$HERDR_PANE_ID" >&2
    return 1
  fi
}

painter_home_available() (
  [ -d "$PAINTER_HOME" ] || return 1
  CDPATH='' cd -- "$PAINTER_HOME" 2>/dev/null || return 1
)

PAINTER_LOCK=
painter_claim() {
  [ "$PAINTER_BINDING" = bound ] || return 0
  [ -z "$PAINTER_LOCK" ] || return 0
  if ! declare -F fm_lock_try_acquire >/dev/null 2>&1; then
    # shellcheck source=bin/fm-wake-lib.sh
    . "$SCRIPT_DIR/fm-wake-lib.sh"
  fi
  PAINTER_LOCK="$PAINTER_STATE/.fleet-painter-$HERDR_PANE_ID.lock"
  if ! fm_lock_try_acquire "$PAINTER_LOCK"; then
    printf 'fm-fleet-view: another fleet banner (pid %s) is already painting %s; refusing to paint over it.\n' \
      "${FM_LOCK_HELD_PID:-unknown}" "$HERDR_PANE_ID" >&2
    PAINTER_LOCK=
    return 1
  fi
  trap 'fm_lock_release "$PAINTER_LOCK" || true' EXIT
}

if [ "$WATCH" = 1 ]; then
  GEOMETRY_FAILURES=0
  GEOMETRY_RETRY_LIMIT=3
  painter_binding
  if [ "$PAINTER_BINDING" = unbound ]; then
    painter_retire 'leaving the frame to the panes it records'
    exit 0
  fi
  painter_claim || exit 1
  trap 'fm_terminal_watch_reset; exit 0' INT TERM HUP
  while :; do
    # Re-read the binding every redraw, so a banner whose pane the frame stops
    # recording retires here instead of painting a region it was replaced in.
    painter_binding
    if [ "$PAINTER_BINDING" = unbound ]; then
      if [ "$PAINTER_BOUND_ONCE" = 1 ] && ! painter_home_available; then
        painter_evict 'its operational home and authoritative cwd are permanently unavailable' || true
        exit 1
      fi
      painter_retire 'retiring rather than painting beside its replacement'
      exit 0
    fi
    painter_claim || exit 1
    if frame=$(render_once); then
      GEOMETRY_FAILURES=0
    else
      render_status=$?
      case "$render_status" in
        64)
          painter_evict 'authoritative pane state or cwd is permanently unavailable' || true
          exit 1
          ;;
        75)
          GEOMETRY_FAILURES=$((GEOMETRY_FAILURES + 1))
          if [ "$GEOMETRY_FAILURES" -ge "$GEOMETRY_RETRY_LIMIT" ]; then
            painter_evict "drawn geometry stayed unavailable after $GEOMETRY_RETRY_LIMIT consecutive attempts" || true
            exit 1
          fi
          frame="FLEET VIEW DEGRADED
Drawn pane geometry unavailable; transient attempt $GEOMETRY_FAILURES of $GEOMETRY_RETRY_LIMIT."
          ;;
      esac
    fi
    # A write that fails is a pane that has gone away underneath this loop:
    # stop rather than spin forever against a terminal nobody can read.
    fm_terminal_paint_frame "$frame" || exit 0
    sleep "$INTERVAL"
  done
fi

render_once
