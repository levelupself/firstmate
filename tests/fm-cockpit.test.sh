#!/usr/bin/env bash
# Behavior tests for the Herdr-only orchestration cockpit frame.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

COCKPIT="$ROOT/bin/fm-cockpit.sh"
TMP_ROOT=$(fm_test_tmproot fm-cockpit)
HOME_DIR="$TMP_ROOT/home"
SECOND_HOME="$TMP_ROOT/second-home"
FAKE_DIR="$TMP_ROOT/fake"
FAKEBIN=$(fm_fakebin "$FAKE_DIR")
HERDR_STATE="$FAKE_DIR/herdr-state"
HERDR_LOG="$FAKE_DIR/herdr.log"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$HOME_DIR/projects" \
  "$SECOND_HOME/state" "$HERDR_STATE"
printf 'w1:p1\tfirstmate-head\tw1:t1\tw1\tlive\n' > "$HERDR_STATE/panes.tsv"
printf '1\n' > "$HERDR_STATE/counter"
: > "$HERDR_LOG"
# The shared primary fixture asks for one fleet pane holding the whole default
# banner, so the placement, rotation, and focus tests below keep talking about
# the same frame they always did. The dedicated layout home further down is
# where the several-pane arrangement itself is exercised.
printf 'waiting,ready,in-flight,blocked\n' > "$HOME_DIR/config/cockpit-sections"

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
state=${FM_FAKE_HERDR_STATE:?}
log=${FM_FAKE_HERDR_LOG:?}
args=()
while [ "$#" -gt 0 ]; do
  if [ "$1" = --session ]; then
    shift 2
    continue
  fi
  args+=("$1")
  shift
done
set -- "${args[@]}"
printf '%s\n' "$*" >> "$log"

pane_row() {
  awk -F '\t' -v id="$1" '$1 == id { print; exit }' "$state/panes.tsv"
}

# fail_after <verb>: succeed for the first N calls of this verb and fail from
# then on, where N is the number in "$state/fail-<verb>-after". A whole-region
# build makes several calls of the same kind, so a test needs to break the third
# split or the second close specifically, not every one of them.
fail_after() {  # <verb>
  local marker="$state/fail-$1-after" seen
  [ -f "$marker" ] || return 0
  seen=$(cat "$state/count-$1" 2>/dev/null || printf 0)
  seen=$((seen + 1))
  printf '%s\n' "$seen" > "$state/count-$1"
  [ "$seen" -gt "$(cat "$marker")" ] && exit 1
  return 0
}

# Field-wise, never `IFS=$'\t' read`: tab is IFS whitespace, so that collapses
# the empty label a freshly split pane carries and shifts every later field.
pane_field() {  # <row> <field-number>
  printf '%s' "$1" | awk -F '\t' -v n="$2" '{print $n}'
}

case "${1:-} ${2:-}" in
  "status --json")
    printf '%s\n' '{"client":{"protocol":16,"version":"0.7.3"},"server":{"running":true}}'
    ;;
  "workspace list")
    printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"},{"workspace_id":"w2","label":"2ndmate-domain"},{"workspace_id":"w3","label":"2ndmate-layout"}]}}'
    ;;
  "session list")
    printf '%s\n' '{"sessions":[{"name":"fmtest","running":true,"socket_path":"/tmp/fm-cockpit-test.sock"}]}'
    ;;
  "tab list")
    printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"cockpit"}]}}'
    ;;
  "tab create")
    workspace=
    label=
    shift 2
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --workspace) workspace=$2; shift 2 ;;
        --label) label=$2; shift 2 ;;
        --cwd) shift 2 ;;
        --no-focus) shift ;;
        *) shift ;;
      esac
    done
    [ -n "$workspace" ] && [ -n "$label" ] || exit 1
    counter=$(cat "$state/counter")
    counter=$((counter + 1))
    printf '%s\n' "$counter" > "$state/counter"
    tab="w1:t$counter"
    id="w1:p$counter"
    printf '%s\t%s\t%s\t%s\tno-agent\n' "$id" "$label" "$tab" "$workspace" >> "$state/panes.tsv"
    root_tab=${FM_FAKE_HERDR_ROOT_TAB:-$tab}
    root_workspace=${FM_FAKE_HERDR_ROOT_WORKSPACE:-$workspace}
    jq -n --arg id "$id" --arg tab "$tab" --arg workspace "$workspace" --arg label "$label" \
      --arg root_tab "$root_tab" --arg root_workspace "$root_workspace" \
      '{result:{tab:{tab_id:$tab,workspace_id:$workspace,label:$label},
        root_pane:{pane_id:$id,tab_id:$root_tab,workspace_id:$root_workspace,label:$label}}}'
    ;;
  "tab get")
    tab=$3
    workspace=${tab%%:*}
    jq -n --arg tab "$tab" --arg workspace "$workspace" \
      '{result:{tab:{tab_id:$tab,workspace_id:$workspace,label:"cockpit"}}}'
    ;;
  "pane list")
    jq -Rn '
      [inputs | split("\t")
       | .[4] as $status
       | {pane_id:.[0],label:.[1],tab_id:.[2],workspace_id:.[3],
          agent_status:(if $status == "live" then "idle"
                        elif (["working","idle","blocked"] | index($status)) != null then $status
                        else "unknown" end)}]
      | {result:{panes:.}}
    ' < "$state/panes.tsv"
    ;;
  "pane get")
    row=$(pane_row "$3")
    if [ -z "$row" ]; then
      printf '%s\n' '{"error":{"code":"pane_not_found"}}'
    else
      workspace=$(pane_field "$row" 4)
      cwd=${FM_FAKE_FLEET_CWD:-}
      if [ -z "$cwd" ]; then
        fixture_root=$(dirname "$(dirname "$state")")
        case "$workspace" in
          w1) cwd="$fixture_root/home" ;;
          w2) cwd="$fixture_root/second-home" ;;
          w3) cwd="$fixture_root/layout-home" ;;
        esac
      fi
      jq -n --arg id "$(pane_field "$row" 1)" --arg label "$(pane_field "$row" 2)" \
        --arg tab "$(pane_field "$row" 3)" --arg workspace "$workspace" --arg cwd "$cwd" \
        '{result:{pane:{pane_id:$id,label:$label,tab_id:$tab,workspace_id:$workspace,
          foreground_cwd:$cwd}}}'
    fi
    ;;
  "agent get")
    row=$(pane_row "$3")
    agent=$(printf '%s' "$row" | awk -F '\t' '{print $5}')
    if [ "$agent" = live ]; then
      printf '%s\n' '{"result":{"agent":{"agent_status":"idle"}}}'
    else
      printf '%s\n' '{"error":{"code":"agent_not_found"}}'
    fi
    ;;
  "pane split")
    fail_after split
    row=$(pane_row "$3")
    [ -n "$row" ] || exit 1
    source_id=$(pane_field "$row" 1)
    tab=$(pane_field "$row" 3)
    workspace=$(pane_field "$row" 4)
    counter=$(cat "$state/counter")
    counter=$((counter + 1))
    printf '%s\n' "$counter" > "$state/counter"
    id="$workspace:p$counter"
    # Row order models visual order within the tab: herdr places the new pane
    # immediately after the pane it split away from.
    awk -F '\t' -v OFS='\t' -v src="$source_id" -v id="$id" -v tab="$tab" \
      -v workspace="$workspace" '
      {print}
      $1 == src {print id, "", tab, workspace, "no-agent"}
    ' "$state/panes.tsv" > "$state/panes.next"
    mv "$state/panes.next" "$state/panes.tsv"
    jq -n --arg id "$id" --arg tab "$tab" --arg workspace "$workspace" \
      '{result:{pane:{pane_id:$id,tab_id:$tab,workspace_id:$workspace}}}'
    ;;
  "pane swap")
    shift
    source_pane=
    target_pane=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --source-pane) source_pane=$2; shift 2 ;;
        --target-pane) target_pane=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    [ -n "$source_pane" ] && [ -n "$target_pane" ] || exit 1
    [ -n "$(pane_row "$source_pane")" ] && [ -n "$(pane_row "$target_pane")" ] || exit 1
    if [ -e "$state/fail-swap" ]; then
      jq -n --arg source "$source_pane" --arg target "$target_pane" \
        '{result:{swap:{changed:false,reason:"refused",
          source_pane_id:$source,target_pane_id:$target}}}'
      exit 0
    fi
    # Exchange the two rows' positions, keeping every other field with its own
    # pane exactly as herdr does.
    awk -F '\t' -v OFS='\t' -v a="$source_pane" -v b="$target_pane" '
      { line[NR] = $0; id[NR] = $1; if ($1 == a) ai = NR; if ($1 == b) bi = NR }
      END {
        tmp = line[ai]; line[ai] = line[bi]; line[bi] = tmp
        for (i = 1; i <= NR; i++) print line[i]
      }
    ' "$state/panes.tsv" > "$state/panes.next"
    mv "$state/panes.next" "$state/panes.tsv"
    jq -n --arg source "$source_pane" --arg target "$target_pane" \
      '{result:{swap:{changed:true,source_pane_id:$source,target_pane_id:$target}}}'
    ;;
  "pane zoom")
    id=$3
    mode=${4#--}
    printf '%s %s\n' "$id" "$mode" >> "$state/zoom.log"
    if [ "$mode" = off ]; then
      zoomed=false
    else
      zoomed=true
    fi
    jq -n --arg id "$id" --argjson zoomed "$zoomed" \
      '{result:{type:"pane_zoom",zoom:{changed:true,pane_id:$id,zoomed:$zoomed}}}'
    ;;
  "pane run")
    id=$3
    [ ! -e "$state/fail-run" ] || exit 1
    fail_after run
    # The launched --section argument is kept with the pane, so process-info
    # reports back exactly what this pane was started with rather than a
    # constant the adapter would always agree with.
    run_section=
    shift 3
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --section) run_section=${2:-}; shift 2 ;;
        *) shift ;;
      esac
    done
    awk -F '\t' -v OFS='\t' -v id="$id" -v section="$run_section" \
      '$1 == id {$5="fleet-live"; $6=section} {print}' \
      "$state/panes.tsv" > "$state/panes.next"
    mv "$state/panes.next" "$state/panes.tsv"
    printf '%s\n' '{"result":{"type":"command_started"}}'
    ;;
  "pane process-info")
    info_pane=$4
    row=$(pane_row "$info_pane")
    [ -n "$row" ] || exit 1
    status=$(printf '%s' "$row" | awk -F '\t' '{print $5}')
    pane_section=$(printf '%s' "$row" | awk -F '\t' '{print $6}')
    section_argv() {  # extra argv words for whatever this pane was launched with
      if [ -n "$pane_section" ]; then
        jq -cn --arg s "$pane_section" '["--section",$s]'
      else
        printf '[]'
      fi
    }
    emit_processes() {  # <argv-json>
      jq -n --arg pane "$info_pane" --argjson argv "$1" \
        '{result:{type:"pane_process_info",process_info:{pane_id:$pane,shell_pid:100,
          foreground_process_group_id:101,foreground_processes:[
            {pid:101,name:"bash",argv:$argv}]}}}'
    }
    case "$status" in
      fleet-live)
        emit_processes "$(jq -cn --arg s "$FM_COCKPIT_ROOT/bin/fm-fleet-view.sh" \
          --arg g "$FM_COCKPIT_ROOT/bin/fm-herdr-pane-geometry.sh" \
          --arg session "${FM_FAKE_HERDR_SESSION:-fmtest}" --arg pane "$info_pane" \
          --argjson extra "$(section_argv)" \
          '["bash",$s,"--geometry-command",$g,
            "--herdr-session",$session,"--herdr-pane",$pane,"--watch"] + $extra')"
        ;;
      fleet-no-pane-identity)
        # Every other check passes: the exact executable, the exact home, the
        # recorded sections, and the geometry binding. The one thing missing is
        # the pane identity that binding needs to resolve a rectangle at all.
        emit_processes "$(jq -cn --arg s "$FM_COCKPIT_ROOT/bin/fm-fleet-view.sh" \
          --arg g "$FM_COCKPIT_ROOT/bin/fm-herdr-pane-geometry.sh" \
          --argjson extra "$(section_argv)" \
          '["bash",$s,"--geometry-command",$g,"--watch"] + $extra')"
        ;;
      fleet-foreign-pane-identity)
        # Bound, but to a pane that is not this one. An identity a caller can
        # spell freely is worth nothing unless it is checked against the pane
        # the frame actually recorded.
        emit_processes "$(jq -cn --arg s "$FM_COCKPIT_ROOT/bin/fm-fleet-view.sh" \
          --arg g "$FM_COCKPIT_ROOT/bin/fm-herdr-pane-geometry.sh" \
          --arg session "${FM_FAKE_HERDR_SESSION:-fmtest}" \
          --argjson extra "$(section_argv)" \
          '["bash",$s,"--geometry-command",$g,
            "--herdr-session",$session,"--herdr-pane","w9:p9","--watch"] + $extra')"
        ;;
      fleet-foreign-session-identity)
        emit_processes "$(jq -cn --arg s "$FM_COCKPIT_ROOT/bin/fm-fleet-view.sh" \
          --arg g "$FM_COCKPIT_ROOT/bin/fm-herdr-pane-geometry.sh" \
          --arg pane "$info_pane" --argjson extra "$(section_argv)" \
          '["bash",$s,"--geometry-command",$g,
            "--herdr-session","another-session","--herdr-pane",$pane,"--watch"] + $extra')"
        ;;
      fleet-relative)
        # The same watcher, started by hand from the checkout through a
        # relative path rather than the adapter's absolute invocation.
        emit_processes "$(jq -cn --arg g "bin/fm-herdr-pane-geometry.sh" \
          --argjson extra "$(section_argv)" \
          '["bash","bin/fm-fleet-view.sh","--geometry-command",$g,"--watch"] + $extra')"
        ;;
      fleet-env-home)
        emit_processes "$(jq -cn --arg s "$FM_COCKPIT_ROOT/bin/fm-fleet-view.sh" \
          --arg g "$FM_COCKPIT_ROOT/bin/fm-herdr-pane-geometry.sh" \
          --arg session "${FM_FAKE_HERDR_SESSION:-fmtest}" --arg pane "$info_pane" \
          --arg h "FM_HOME=${FM_FAKE_FLEET_HOME:-}" --argjson extra "$(section_argv)" \
          '["env",$h,$s,"--geometry-command",$g,
            "--herdr-session",$session,"--herdr-pane",$pane,"--watch"] + $extra')"
        ;;
      fleet-other-sections)
        # A fleet view for this home, watching, but not the part of the fleet
        # the frame recorded for this pane.
        emit_processes "$(jq -cn --arg s "$FM_COCKPIT_ROOT/bin/fm-fleet-view.sh" \
          --arg g "$FM_COCKPIT_ROOT/bin/fm-herdr-pane-geometry.sh" \
          --arg session "${FM_FAKE_HERDR_SESSION:-fmtest}" --arg pane "$info_pane" \
          '["bash",$s,"--geometry-command",$g,
            "--herdr-session",$session,"--herdr-pane",$pane,
            "--watch","--section","failed"]')"
        ;;
      fleet-stale-painter)
        # A fleet view for the right home, watching, showing exactly the
        # recorded sections - but launched before --geometry-command existed,
        # so it paints to the pane's own pty instead of the drawn rectangle.
        emit_processes "$(jq -cn --arg s "$FM_COCKPIT_ROOT/bin/fm-fleet-view.sh" \
          --argjson extra "$(section_argv)" '["bash",$s,"--watch"] + $extra')"
        ;;
      fleet-split-evidence)
        jq -n --arg pane "$info_pane" \
          --arg exact "$FM_COCKPIT_ROOT/bin/fm-fleet-view.sh" \
          --arg other "/wrong/checkout/bin/fm-fleet-view.sh" \
          --arg geometry "$FM_COCKPIT_ROOT/bin/fm-herdr-pane-geometry.sh" \
          --arg section "$pane_section" \
          '{result:{type:"pane_process_info",process_info:{pane_id:$pane,shell_pid:100,
            foreground_process_group_id:101,foreground_processes:[
              {pid:101,name:"bash",argv:["bash",$exact,"--watch","--section",$section]},
              {pid:102,name:"bash",argv:["bash",$other,"--geometry-command",$geometry,
                "--watch","--section",$section]}]}}}'
        ;;
      fleet-no-watch)
        emit_processes "$(jq -cn --arg s "$FM_COCKPIT_ROOT/bin/fm-fleet-view.sh" \
          --arg g "$FM_COCKPIT_ROOT/bin/fm-herdr-pane-geometry.sh" \
          '["bash",$s,"--geometry-command",$g]')"
        ;;
      fleet-unreadable)
        printf '%s\n' '{"result":{"type":"something_else"}}'
        ;;
      fleet-gone)
        exit 1
        ;;
      *)
        emit_processes '["bash"]'
        ;;
    esac
    ;;
  "pane rename")
    id=$3
    label=$4
    [ ! -e "$state/fail-rename" ] || exit 1
    awk -F '\t' -v OFS='\t' -v id="$id" -v label="$label" '$1 == id {$2=label} {print}' \
      "$state/panes.tsv" > "$state/panes.next"
    mv "$state/panes.next" "$state/panes.tsv"
    row=$(pane_row "$id")
    jq -n --arg id "$(pane_field "$row" 1)" --arg label "$(pane_field "$row" 2)" \
      --arg tab "$(pane_field "$row" 3)" --arg workspace "$(pane_field "$row" 4)" \
      '{result:{pane:{pane_id:$id,label:$label,tab_id:$tab,workspace_id:$workspace}}}'
    ;;
  "pane close")
    id=$3
    [ ! -e "$state/fail-close" ] || exit 1
    fail_after close
    awk -F '\t' -v id="$id" '$1 != id {print}' "$state/panes.tsv" > "$state/panes.next"
    mv "$state/panes.next" "$state/panes.tsv"
    printf '%s\n' '{"result":{"type":"pane_closed"}}'
    ;;
  "pane move")
    id=$3
    shift 3
    new_tab=0
    target_tab=
    move_label=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --new-tab) new_tab=1; shift ;;
        --label) move_label=$2; shift 2 ;;
        --tab) target_tab=$2; shift 2 ;;
        --split|--target-pane|--ratio) shift 2 ;;
        *) shift ;;
      esac
    done
    row=$(pane_row "$id")
    [ -n "$row" ] || exit 1
    pane_id=$(pane_field "$row" 1)
    pane_label=$(pane_field "$row" 2)
    cur_tab=$(pane_field "$row" 3)
    if [ "$new_tab" = 1 ]; then
      counter=$(cat "$state/counter")
      counter=$((counter + 1))
      printf '%s\n' "$counter" > "$state/counter"
      target_tab="w1:t$counter"
      printf '%s\t%s\n' "$target_tab" "${move_label:-$pane_label}" >> "$state/parked-tabs.tsv"
    fi
    [ -n "$target_tab" ] || exit 1
    if [ "$target_tab" = "$cur_tab" ]; then
      jq -n --arg id "$pane_id" --arg tab "$cur_tab" \
        '{result:{move_result:{changed:false,reason:"same_tab",
          pane:{pane_id:$id,tab_id:$tab}}}}'
      exit 0
    fi
    awk -F '\t' -v OFS='\t' -v id="$id" -v tab="$target_tab" '$1 == id {$3=tab} {print}' \
      "$state/panes.tsv" > "$state/panes.next"
    mv "$state/panes.next" "$state/panes.tsv"
    jq -n --arg id "$pane_id" --arg tab "$target_tab" \
      '{result:{move_result:{changed:true,pane:{pane_id:$id,tab_id:$tab}}}}'
    ;;
  "pane report-metadata")
    printf '%s\n' "$*" >> "$state/metadata.log"
    printf '%s\n' '{"result":{"type":"pane_metadata_reported"}}'
    ;;
  "tab focus")
    printf '%s\n' '{"result":{"type":"tab_focused"}}'
    ;;
  "workspace focus")
    printf '%s\n' '{"result":{"type":"workspace_focused"}}'
    ;;
  *)
    printf 'unexpected fake herdr call: %s\n' "$*" >&2
    exit 1
    ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

cat > "$FAKEBIN/nohup" <<'SH'
#!/usr/bin/env bash
printf 'nohup %s\n' "$*" >> "${FM_FAKE_HERDR_LOG:?}"
[ "${FM_FAKE_NOHUP_RUN:-0}" = 1 ] || exit 0
exec /usr/bin/nohup "$@"
SH
chmod +x "$FAKEBIN/nohup"

cat > "$FAKEBIN/focus-reader" <<'SH'
#!/usr/bin/env bash
set -eu
[ "${1:-}" = --focus-once ] || exit 2
state=${FM_FAKE_FOCUS_STATE:?}
[ -z "${FM_FAKE_FOCUS_READER_PID_FILE:-}" ] \
  || printf '%s\n' "$$" > "$FM_FAKE_FOCUS_READER_PID_FILE"
count=$(cat "$state" 2>/dev/null || printf 0)
count=$((count + 1))
printf '%s\n' "$count" > "$state"
printf '%s\n' '@subscribed'
if [ "$count" = 1 ] && [ -n "${FM_FAKE_FOCUS_PANE:-}" ]; then
  printf '%s\t%s\n' "$FM_FAKE_FOCUS_PANE" w1
else
  sleep "${FM_FAKE_FOCUS_IDLE:-0}"
fi
SH
chmod +x "$FAKEBIN/focus-reader"

run_cockpit_at() {  # <pane> <socket> <action>
  PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_DIR" \
    FM_FAKE_HERDR_STATE="$HERDR_STATE" \
    FM_FAKE_HERDR_LOG="$HERDR_LOG" \
    FM_COCKPIT_ROOT="$ROOT" \
    HERDR_ENV=1 \
    HERDR_SESSION=fmtest \
    HERDR_SOCKET_PATH="$2" \
    HERDR_PANE_ID="$1" \
    "$COCKPIT" "$3"
}

run_cockpit() {
  run_cockpit_at w1:p1 /tmp/fm-cockpit-test.sock "$1"
}

focus_cockpit() {
  PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_DIR" \
    FM_FAKE_HERDR_STATE="$HERDR_STATE" \
    FM_FAKE_HERDR_LOG="$HERDR_LOG" \
    FM_COCKPIT_ROOT="$ROOT" \
    FM_BACKEND_HERDR_EVENT_READER="$FAKEBIN/focus-reader" \
    FM_FAKE_FOCUS_STATE="$HERDR_STATE/focus-reader-count" \
    FM_FAKE_FOCUS_READER_PID_FILE="$HERDR_STATE/focus-reader-pid" \
    HERDR_ENV=1 \
    HERDR_SESSION=fmtest \
    HERDR_SOCKET_PATH=/tmp/fm-cockpit-test.sock \
    HERDR_PANE_ID=w1:p1 \
    "$COCKPIT" "$@"
}

test_frame_re_adoption_is_idempotent() {
  local first second before after log
  first=$(run_cockpit adopt) || fail "first cockpit adoption failed"
  assert_contains "$first" "adopted Herdr frame" "first adoption did not report its frame"
  assert_grep 'fleet_pane_ids=w1:p2' "$HOME_DIR/state/.herdr-cockpit" \
    "first adoption did not bind the persistent fleet pane"
  assert_grep 'fleet_pane_sections=waiting,ready,in-flight,blocked' \
    "$HOME_DIR/state/.herdr-cockpit" \
    "first adoption did not record what its fleet pane shows"
  before=$(sha256sum "$HOME_DIR/state/.herdr-cockpit" | awk '{print $1}')
  : > "$HERDR_LOG"
  second=$(run_cockpit adopt) || fail "cockpit restart re-adoption failed"
  after=$(sha256sum "$HOME_DIR/state/.herdr-cockpit" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "re-adoption rewrote the durable frame"
  assert_contains "$second" "re-adopted Herdr frame" "restart did not re-adopt the recorded frame"
  log=$(cat "$HERDR_LOG")
  assert_contains "$log" "pane get w1:p1" "re-adoption did not validate the exact recorded head"
  assert_not_contains "$log" "pane split" "re-adoption rebuilt the frame"
  assert_not_contains "$log" "tab create" "re-adoption minted a replacement tab"
  assert_not_contains "$log" "nohup" "re-adoption silently armed focus placement"
  pass "cockpit restart re-adopts the durable frame without rebuilding it"
}

test_space_switch_focuses_one_complete_frame_and_rejects_nesting() {
  local out rc
  printf 'w2:p1\tsecondmate-head\tw2:t1\tw2\tlive\n' >> "$HERDR_STATE/panes.tsv"
  printf 'w2:p2\tfirstmate-fleet\tw2:t1\tw2\tfleet-live\n' >> "$HERDR_STATE/panes.tsv"
  cat > "$SECOND_HOME/state/.herdr-cockpit" <<EOF
version=2
home=$SECOND_HOME
session=fmtest
workspace_id=w2
tab_id=w2:t1
head_pane_id=w2:p1
viewport_pane_id=
fleet_pane_id=w2:p2
EOF
  : > "$HERDR_LOG"
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" \
    FM_FAKE_HERDR_STATE="$HERDR_STATE" FM_FAKE_HERDR_LOG="$HERDR_LOG" \
    FM_COCKPIT_ROOT="$ROOT" \
    HERDR_ENV=1 HERDR_SESSION=fmtest HERDR_SOCKET_PATH=/tmp/fm-cockpit-test.sock \
    HERDR_PANE_ID=w1:p1 "$COCKPIT" switch "$SECOND_HOME") \
    || fail "cockpit could not switch to a complete sibling-home frame"
  assert_contains "$out" "switched complete frame home=$SECOND_HOME workspace=w2" \
    "cockpit switch did not report the exact target frame"
  assert_contains "$(cat "$HERDR_LOG")" "workspace focus w2" \
    "cockpit switch did not focus the frame as one workspace operation"

  mkdir -p "$HOME_DIR/nested"
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" \
    FM_FAKE_HERDR_STATE="$HERDR_STATE" FM_FAKE_HERDR_LOG="$HERDR_LOG" \
    HERDR_ENV=1 HERDR_SESSION=fmtest "$COCKPIT" switch "$HOME_DIR/nested" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "cockpit accepted a nested home frame"
  assert_contains "$out" "nested cockpit homes are not supported" \
    "nested cockpit refusal was not explicit"
  pass "space switching focuses one complete frame and rejects nesting"
}

test_version_one_frame_migrates_and_failed_creation_cleans_up() {
  local out before after rc fleet record_hash
  printf 'domain\n' > "$SECOND_HOME/.fm-secondmate-home"
  awk -F '\t' '$1 != "w2:p2" {print}' "$HERDR_STATE/panes.tsv" > "$HERDR_STATE/panes.next"
  mv "$HERDR_STATE/panes.next" "$HERDR_STATE/panes.tsv"
  cat > "$SECOND_HOME/state/.herdr-cockpit" <<EOF
version=1
home=$SECOND_HOME
session=fmtest
workspace_id=w2
tab_id=w2:t1
head_pane_id=w2:p1
viewport_pane_id=
EOF
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$SECOND_HOME" \
    FM_FAKE_HERDR_STATE="$HERDR_STATE" FM_FAKE_HERDR_LOG="$HERDR_LOG" \
    FM_COCKPIT_ROOT="$ROOT" HERDR_ENV=1 HERDR_SESSION=fmtest \
    HERDR_SOCKET_PATH=/tmp/fm-cockpit-test.sock HERDR_PANE_ID=w2:p1 \
    "$COCKPIT" adopt) || fail "validated version-1 cockpit frame did not migrate"
  assert_contains "$out" "migrated and re-adopted Herdr frame" \
    "version-1 migration was not explicit"
  assert_grep 'version=3' "$SECOND_HOME/state/.herdr-cockpit" \
    "version-1 cockpit record did not advance atomically"

  fleet=$(grep '^fleet_pane_ids=' "$SECOND_HOME/state/.herdr-cockpit" | cut -d= -f2- | cut -d, -f1)
  awk -F '\t' -v OFS='\t' -v pane="$fleet" '$1 == pane {$5="no-agent"} {print}' \
    "$HERDR_STATE/panes.tsv" > "$HERDR_STATE/panes.next"
  mv "$HERDR_STATE/panes.next" "$HERDR_STATE/panes.tsv"
  record_hash=$(sha256sum "$SECOND_HOME/state/.herdr-cockpit" | awk '{print $1}')
  : > "$HERDR_LOG"
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$SECOND_HOME" \
    FM_FAKE_HERDR_STATE="$HERDR_STATE" FM_FAKE_HERDR_LOG="$HERDR_LOG" \
    FM_COCKPIT_ROOT="$ROOT" HERDR_ENV=1 HERDR_SESSION=fmtest \
    HERDR_SOCKET_PATH=/tmp/fm-cockpit-test.sock HERDR_PANE_ID=w2:p1 \
    LINES=40 COLUMNS=120 \
    "$COCKPIT" panel) || fail "dead fleet column could not be rendered read-only"
  # The panel clips every row to the measured terminal width, so assert the
  # stable cause here and leave the full diagnostic wording to `status` below.
  assert_contains "$out" "FLEET column=$fleet [no-fleet-process]" \
    "a fleet pane running no fleet view did not report that exact cause"
  assert_not_contains "$(cat "$HERDR_LOG")" "pane split" \
    "dead fleet command was silently rebuilt"
  [ "$record_hash" = "$(sha256sum "$SECOND_HOME/state/.herdr-cockpit" | awk '{print $1}')" ] \
    || fail "dead fleet rendering rewrote the frame record"

  rm "$SECOND_HOME/state/.herdr-cockpit"
  awk -F '\t' '$4 != "w2" || $1 == "w2:p1" {print}' \
    "$HERDR_STATE/panes.tsv" > "$HERDR_STATE/panes.next"
  mv "$HERDR_STATE/panes.next" "$HERDR_STATE/panes.tsv"
  touch "$HERDR_STATE/fail-run"
  before=$(wc -l < "$HERDR_STATE/panes.tsv")
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$SECOND_HOME" \
    FM_FAKE_HERDR_STATE="$HERDR_STATE" FM_FAKE_HERDR_LOG="$HERDR_LOG" \
    FM_COCKPIT_ROOT="$ROOT" HERDR_ENV=1 HERDR_SESSION=fmtest \
    HERDR_SOCKET_PATH=/tmp/fm-cockpit-test.sock HERDR_PANE_ID=w2:p1 \
    "$COCKPIT" adopt 2>&1)
  rc=$?
  rm "$HERDR_STATE/fail-run"
  after=$(wc -l < "$HERDR_STATE/panes.tsv")
  [ "$rc" -ne 0 ] || fail "cockpit adoption accepted a failed fleet command"
  [ "$before" = "$after" ] || fail "failed fleet command leaked its response-derived pane"
  [ ! -e "$SECOND_HOME/state/.herdr-cockpit" ] \
    || fail "failed fleet command published a cockpit record"
  printf '2\n' > "$HERDR_STATE/counter"
  pass "version-1 migration and failed fleet creation preserve frame ownership"
}

test_adoption_requires_the_native_session_socket() {
  local before out rc after
  before=$(sha256sum "$HOME_DIR/state/.herdr-cockpit" | awk '{print $1}')
  out=$(run_cockpit_at w1:p1 /tmp/wrong-cockpit.sock adopt 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "cockpit adopted a pane from an unverified session socket"
  assert_contains "$out" "belongs to the server" "cross-session cockpit refusal was not explicit"
  after=$(sha256sum "$HOME_DIR/state/.herdr-cockpit" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "cross-session cockpit refusal changed the durable frame"
  pass "cockpit adoption reuses the socket-verified native pane identity"
}

place_task() {
  PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_DIR" \
    FM_FAKE_HERDR_STATE="$HERDR_STATE" \
    FM_FAKE_HERDR_LOG="$HERDR_LOG" \
    FM_COCKPIT_ROOT="$ROOT" \
    HERDR_SESSION=fmtest \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_cockpit_create_task "$1/state" "$1" "$2" /tmp' \
      "$ROOT" "$HOME_DIR" "$1"
}

test_first_worker_lands_in_viewport_and_later_spawns_do_not_steal_it() {
  local first second log live out rc stranded
  : > "$HERDR_LOG"
  first=$(place_task fm-one) || fail "first cockpit task placement failed"
  [ "$first" = "w1:t1 w1:p3" ] || fail "first cockpit task returned unexpected ids: $first"
  log=$(cat "$HERDR_LOG")
  assert_contains "$log" "pane split w1:p1 --direction right --ratio 0.67" \
    "first child did not split right from the pinned head"
  assert_not_contains "$log" "tab create" "first child minted a peer tab"
  assert_grep 'viewport_pane_id=w1:p3' "$HOME_DIR/state/.herdr-cockpit" \
    "first child did not become the durable viewport anchor"

  : > "$HERDR_LOG"
  second=$(place_task fm-two) || fail "second cockpit task placement failed"
  [ "$second" = "w1:t4 w1:p4" ] || fail "second cockpit task returned unexpected ids: $second"
  log=$(cat "$HERDR_LOG")
  assert_contains "$log" "tab create --workspace w1 --cwd /tmp --label fm-two --no-focus" \
    "later child did not open on its own labelled peer tab"
  assert_contains "$log" "pane rename w1:p4 fm-two" \
    "later child labelled only its peer tab, not the peer root pane"
  assert_not_contains "$log" "pane move w1:p3" \
    "later child displaced the viewport occupant"
  assert_not_contains "$log" "pane split w1:p1" \
    "later child split the viewport while it was occupied"
  assert_grep 'viewport_pane_id=w1:p3' "$HOME_DIR/state/.herdr-cockpit" \
    "later child changed the viewport anchor"
  [ "$(pane_tab_of w1:p3)" = w1:t1 ] \
    || fail "later child moved the worker the operator was reading"

  live=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" \
    FM_FAKE_HERDR_STATE="$HERDR_STATE" FM_FAKE_HERDR_LOG="$HERDR_LOG" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_list_live fmtest' "$ROOT")
  assert_contains "$live" $'fmtest:w1:p3\tfm-one' "recovery inventory missed the first split-pane task"
  assert_contains "$live" $'fmtest:w1:p4\tfm-two' "recovery inventory missed the peer-tab task"

  : > "$HERDR_LOG"
  touch "$HERDR_STATE/fail-rename" "$HERDR_STATE/fail-close"
  out=$(place_task fm-rename-failure 2>&1)
  rc=$?
  rm -f "$HERDR_STATE/fail-rename" "$HERDR_STATE/fail-close"
  [ "$rc" -ne 0 ] || fail "peer spawn accepted a pane it could not label or remove"
  stranded=$(awk -F '\t' '$2 == "fm-rename-failure" {print $1}' "$HERDR_STATE/panes.tsv")
  [ -n "$stranded" ] || fail "peer rename regression did not leave the unconfirmed pane observable"
  assert_contains "$out" "NOT-RESTORED" \
    "peer rename failure suppressed its unconfirmed cleanup"
  assert_contains "$out" "added peer pane $stranded could not be removed" \
    "peer rename failure did not name the pane still on screen"
  assert_contains "$(cat "$HERDR_LOG")" "pane close $stranded" \
    "peer rename failure did not attempt a confirmed close"
  assert_not_contains "$(cat "$HERDR_LOG")" "pane report-metadata $stranded" \
    "peer rename failure published metadata for an unlabelled pane"
  awk -F '\t' -v id="$stranded" '$1 != id' "$HERDR_STATE/panes.tsv" > "$HERDR_STATE/panes.next"
  mv "$HERDR_STATE/panes.next" "$HERDR_STATE/panes.tsv"

  : > "$HERDR_LOG"
  out=$(FM_FAKE_HERDR_ROOT_TAB=w2:t5 place_task fm-cross 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "peer spawn accepted a root pane from another tab"
  assert_contains "$out" "incomplete or cross-frame pane identity" \
    "peer spawn did not explain its cross-frame root-pane refusal"
  assert_not_contains "$(cat "$HERDR_LOG")" "pane report-metadata w1:p5" \
    "peer spawn mutated a root pane before validating its frame identity"
  awk -F '\t' '$2 != "fm-cross"' "$HERDR_STATE/panes.tsv" > "$HERDR_STATE/panes.next"
  mv "$HERDR_STATE/panes.next" "$HERDR_STATE/panes.tsv"
  pass "the first worker fills an empty viewport and later spawns preserve its occupant"
}

cockpit_fn() {  # <function> <args...>
  PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_DIR" \
    FM_FAKE_HERDR_STATE="$HERDR_STATE" \
    FM_FAKE_HERDR_LOG="$HERDR_LOG" \
    FM_COCKPIT_ROOT="$ROOT" \
    HERDR_SESSION=fmtest \
    bash -c '. "$0/bin/backends/herdr.sh"; fn=$1; shift; "$fn" "$@"' "$ROOT" "$@"
}

write_task_record() {  # <id> <pane>
  cat > "$HOME_DIR/state/$1.meta" <<EOF
window=fmtest:$2
endpoint_task_id=$1
backend=herdr
herdr_session=fmtest
herdr_workspace_id=w1
herdr_tab_id=w1:t1
herdr_pane_id=$2
EOF
}

pane_tab_of() {  # <pane>
  awk -F '\t' -v id="$1" '$1 == id { print $3; exit }' "$HERDR_STATE/panes.tsv"
}

pane_id_by_label() {  # <label>
  awk -F '\t' -v label="$1" '$2 == label { print $1; exit }' "$HERDR_STATE/panes.tsv"
}

test_focus_never_moves_a_pane_this_home_does_not_own() {
  local foreign reserved log rc
  # A pane labelled like a task, but with no task record in THIS home - exactly
  # how another home's worker appears in the shared Herdr sidebar.
  foreign=$(cockpit_fn fm_backend_herdr_cli fmtest pane split w1:p1 \
    --direction right --ratio 0.5 | jq -r '.result.pane.pane_id')
  cockpit_fn fm_backend_herdr_cli fmtest pane rename "$foreign" fm-foreign >/dev/null
  rm -f "$HOME_DIR/state/foreign.meta"

  : > "$HERDR_LOG"
  cockpit_fn fm_backend_herdr_cockpit_focus_place \
    "$HOME_DIR/state" "$HOME_DIR" fmtest "$foreign" >/dev/null 2>&1
  rc=$?
  log=$(cat "$HERDR_LOG")
  [ "$rc" != 0 ] || fail "focus placement claimed a pane this home has no record of"
  assert_not_contains "$log" "pane move" "focus placement moved a pane owned by another home"
  assert_not_contains "$log" "pane close" "focus placement closed a pane owned by another home"

  # The pinned head and the live fleet column are not tasks either.
  for reserved in w1:p1 w1:p2; do
    : > "$HERDR_LOG"
    cockpit_fn fm_backend_herdr_cockpit_focus_place \
      "$HOME_DIR/state" "$HOME_DIR" fmtest "$reserved" >/dev/null 2>&1 \
      && fail "focus placement tried to move the supervisor or fleet pane"
    assert_not_contains "$(cat "$HERDR_LOG")" "pane move" \
      "focus placement moved the supervisor or fleet pane"
  done
  cockpit_fn fm_backend_herdr_cli fmtest pane close "$foreign" >/dev/null 2>&1 || true
  pass "focus placement moves only panes this home's own task records claim"
}

test_rotation_orders_by_task_id_wraps_and_shares_the_placement_path() {
  local alpha one two placed log
  one=$(pane_id_by_label fm-one)
  two=$(pane_id_by_label fm-two)
  placed=$(place_task fm-alpha) || fail "could not place the third rotation worker"
  alpha=${placed##* }
  write_task_record alpha "$alpha"
  write_task_record one "$one"
  write_task_record two "$two"

  # Ring order is task id, not spawn order. The background alpha spawn leaves
  # one in the viewport, so next advances to two in the alpha, one, two ring.
  : > "$HERDR_LOG"
  [ "$(cockpit_fn fm_backend_herdr_cockpit_rotate "$HOME_DIR/state" "$HOME_DIR" fmtest next)" = two ] \
    || fail "next did not advance to the id-ordered successor"
  log=$(cat "$HERDR_LOG")
  assert_contains "$log" "pane move $two --tab w1:t1 --split right --target-pane w1:p1 --ratio 0.67" \
    "rotation did not reuse the single-occupancy placement path"
  assert_not_contains "$log" "pane close" "rotation closed a pane"
  [ "$(pane_tab_of "$two")" = w1:t1 ] || fail "rotation did not place its target in the viewport slot"
  [ "$(pane_tab_of "$alpha")" != w1:t1 ] || fail "rotation left two workers in the viewport slot"

  [ "$(cockpit_fn fm_backend_herdr_cockpit_rotate "$HOME_DIR/state" "$HOME_DIR" fmtest next)" = alpha ] \
    || fail "next did not continue along the ring"
  [ "$(cockpit_fn fm_backend_herdr_cockpit_rotate "$HOME_DIR/state" "$HOME_DIR" fmtest next)" = one ] \
    || fail "next did not wrap from the last worker to the first"
  [ "$(cockpit_fn fm_backend_herdr_cockpit_rotate "$HOME_DIR/state" "$HOME_DIR" fmtest prev)" = alpha ] \
    || fail "prev did not wrap from the first worker to the last"
  [ "$(cockpit_fn fm_backend_herdr_cockpit_rotate "$HOME_DIR/state" "$HOME_DIR" fmtest prev)" = two ] \
    || fail "prev did not step backwards along the ring"
  [ "$(cockpit_fn fm_backend_herdr_cockpit_rotate "$HOME_DIR/state" "$HOME_DIR" fmtest prev)" = one ] \
    || fail "prev did not continue backwards to the starting worker"
  pass "rotation walks this home's workers by task id, wraps both ways, and places through the shared path"
}

test_focus_listener_converges_and_current_occupant_is_idempotent() {
  local current target log move_count reader_count out listener_pid attempt
  current=$(pane_id_by_label fm-one)
  target=$(pane_id_by_label fm-two)
  : > "$HERDR_LOG"
  rm -f "$HERDR_STATE/focus-reader-count"
  env \
    PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_DIR" \
    FM_FAKE_HERDR_STATE="$HERDR_STATE" \
    FM_FAKE_HERDR_LOG="$HERDR_LOG" \
    FM_COCKPIT_ROOT="$ROOT" \
    FM_BACKEND_HERDR_EVENT_READER="$FAKEBIN/focus-reader" \
    FM_FAKE_FOCUS_STATE="$HERDR_STATE/focus-reader-count" \
    FM_FAKE_FOCUS_PANE="$target" \
    FM_FAKE_FOCUS_IDLE=0.2 \
    HERDR_ENV=1 HERDR_SESSION=fmtest \
    HERDR_SOCKET_PATH=/tmp/fm-cockpit-test.sock HERDR_PANE_ID=w1:p1 \
    "$COCKPIT" focus-listen >/dev/null 2>&1 &
  listener_pid=$!
  attempt=0
  reader_count=0
  while [ "$reader_count" -lt 2 ] && kill -0 "$listener_pid" 2>/dev/null \
    && [ "$attempt" -lt 50 ]; do
    sleep 0.1
    reader_count=$(cat "$HERDR_STATE/focus-reader-count" 2>/dev/null || printf 0)
    case "$reader_count" in ''|*[!0-9]*) reader_count=0 ;; esac
    attempt=$((attempt + 1))
  done
  kill -TERM "$listener_pid" 2>/dev/null || true
  wait "$listener_pid" 2>/dev/null || true
  log=$(cat "$HERDR_LOG")
  move_count=$(grep -c '^pane move ' "$HERDR_LOG" || true)
  reader_count=$(cat "$HERDR_STATE/focus-reader-count" 2>/dev/null || printf 0)
  [ "$move_count" = 2 ] \
    || fail "one external focus event did not converge after its one placement: $log"
  [ "$reader_count" -ge 2 ] \
    || fail "convergence test never observed the listener waiting for new external input"
  assert_contains "$log" "pane move $current --new-tab --label fm-one --no-focus" \
    "focus listener did not park the previous occupant exactly once"
  assert_contains "$log" "pane move $target --tab w1:t1" \
    "focus listener did not place the externally focused pane exactly once"

  : > "$HERDR_LOG"
  rm -f "$HERDR_STATE/focus-reader-count"
  out=$(FM_FAKE_FOCUS_PANE="$target" focus_cockpit focus-listen --once) \
    || fail "single-generation listener rejected the current viewport occupant"
  log=$(cat "$HERDR_LOG")
  assert_not_contains "$log" "pane move" \
    "focusing the current viewport occupant emitted a pane move"
  assert_not_contains "$log" "tab focus" \
    "focusing the current viewport occupant emitted a focus restoration"
  [ -z "$out" ] || fail "idempotent focus listener emitted unexpected output: $out"
  cockpit_fn fm_backend_herdr_cockpit_focus_place \
    "$HOME_DIR/state" "$HOME_DIR" fmtest "$current" >/dev/null \
    || fail "focus convergence test could not restore its inherited viewport fixture"
  pass "one focus event converges without feedback and the current occupant is a no-op"
}

test_focus_listener_requires_explicit_start_and_stop_ends_supervisor_and_reader() {
  local out again stopped supervisor_pid reader_pid attempt
  : > "$HERDR_LOG"
  rm -f "$HERDR_STATE/focus-reader-count" "$HERDR_STATE/focus-reader-pid"
  out=$(FM_FAKE_NOHUP_RUN=1 FM_FAKE_FOCUS_IDLE=30 focus_cockpit focus-start) \
    || fail "explicit focus-start did not arm the listener"
  assert_contains "$out" "focus placement started" "focus-start did not confirm startup"
  supervisor_pid=$(cat "$HOME_DIR/state/.cockpit-focus.lock/pid" 2>/dev/null || true)
  attempt=0
  while [ ! -s "$HERDR_STATE/focus-reader-pid" ] && [ "$attempt" -lt 50 ]; do
    sleep 0.1
    attempt=$((attempt + 1))
  done
  reader_pid=$(cat "$HERDR_STATE/focus-reader-pid" 2>/dev/null || true)
  if [ -z "$supervisor_pid" ] || ! kill -0 "$supervisor_pid" 2>/dev/null; then
    fail "focus-start did not leave its identity-recorded supervisor running"
  fi
  if [ -z "$reader_pid" ] || ! kill -0 "$reader_pid" 2>/dev/null; then
    fail "focus-start did not leave its supervised event reader running"
  fi
  again=$(FM_FAKE_NOHUP_RUN=1 FM_FAKE_FOCUS_IDLE=30 focus_cockpit focus-start) \
    || fail "repeated focus-start was not idempotent"
  assert_contains "$again" "already running" "repeated focus-start did not report the live listener"
  stopped=$(focus_cockpit focus-stop) || fail "focus-stop could not reach the recorded supervisor"
  assert_contains "$stopped" "focus placement stopped" "focus-stop did not confirm shutdown"
  kill -0 "$supervisor_pid" 2>/dev/null && fail "focus-stop left the supervising shell running"
  kill -0 "$reader_pid" 2>/dev/null && fail "focus-stop left the supervised event reader running"
  [ ! -e "$HOME_DIR/state/.cockpit-focus.lock" ] \
    || fail "focus-stop left the listener lock behind"
  pass "adoption stays passive while explicit start and stop control the full listener tree"
}

test_rotation_ring_excludes_the_supervisor_and_fleet_panes() {
  local ring
  ring=$(cockpit_fn fm_backend_herdr_cockpit_ring "$HOME_DIR/state" fmtest)
  assert_not_contains "$ring" "w1:p1" "the rotation ring included the pinned supervisor pane"
  assert_not_contains "$ring" "w1:p2" "the rotation ring included the live fleet column"
  assert_contains "$ring" "w1:p3" "the rotation ring dropped a real worker"
  pass "rotation never targets the pinned supervisor or the fleet column"
}

test_displaced_workers_stay_reachable_without_a_listener() {
  local id pane tab log
  # Nothing above ran a listener, and every displaced worker still holds a live
  # pane on a tab of its own - the state a home that never adopted a cockpit is
  # already in, which is why losing the listener strands nothing.
  : > "$HERDR_LOG"
  for id in alpha one two; do
    pane=$(grep '^herdr_pane_id=' "$HOME_DIR/state/$id.meta" | cut -d= -f2-)
    tab=$(pane_tab_of "$pane")
    [ -n "$tab" ] || fail "worker $id lost its pane entirely"
    [ "$(cockpit_fn fm_backend_herdr_pane_agent_state fmtest "$pane")" != dead ] \
      || fail "worker $id was left with a dead pane"
  done
  log=$(cat "$HERDR_LOG")
  assert_not_contains "$log" "pane close" "reading placement state closed a worker pane"
  pass "every displaced worker keeps a live pane on its own tab with no listener running"
}

test_display_and_steer_boundary_remains_explicit() {
  local status out rc before
  status=$(run_cockpit status) || fail "cockpit status could not read the adopted frame"
  assert_contains "$status" "display=all-homes steer=current-home" \
    "cockpit did not disclose its display and steer boundary"
  before=$(wc -l < "$HERDR_LOG")
  out=$(env -u FM_HOME PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-send.sh" fm-two test 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "fm-send accepted a steer without explicit FM_HOME"
  assert_contains "$out" "FM_HOME is not set" "cross-home steer refusal was not explicit"
  [ "$(wc -l < "$HERDR_LOG")" = "$before" ] || fail "refused cross-home steer reached the backend"

  cat > "$SECOND_HOME/state/foreign.meta" <<EOF
window=fmtest:w2:p9
backend=herdr
herdr_session=fmtest
herdr_workspace_id=w2
herdr_tab_id=w2:t9
herdr_pane_id=w2:p9
kind=ship
EOF
  before=$(wc -l < "$HERDR_LOG")
  out=$(FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" \
    "$ROOT/bin/fm-send.sh" fm-foreign test 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "primary home reached into a second home to steer its child"
  assert_contains "$out" "no metadata for fm-foreign in $HOME_DIR/state" \
    "cross-home steer refusal did not stay scoped to the explicit home"
  [ "$(wc -l < "$HERDR_LOG")" = "$before" ] || fail "cross-home child steer reached the backend"

  out=$(env -u HERDR_ENV -u TMUX FM_HOME="$HOME_DIR" "$COCKPIT" status) \
    || fail "non-Herdr cockpit fallback should remain usable"
  assert_contains "$out" "unavailable on runtime backend none" "non-Herdr fallback was silent"
  assert_contains "$out" "fm-fleet-view.sh --watch" "non-Herdr fallback omitted the plain live panel"
  pass "whole-session display remains distinct from explicit home-scoped steering"
}

test_panel_renders_the_live_frame_and_fleet_view() {
  local out log err="$TMP_ROOT/panel.stderr"
  awk -F '\t' -v OFS='\t' '
    $1 == "w1:p3" {$2="fm-claude-pane"; $5="working"}
    $1 == "w1:p4" {$2="fm-codex-pane"; $5="blocked"}
    {print}
  ' "$HERDR_STATE/panes.tsv" > "$HERDR_STATE/panes.next"
  mv "$HERDR_STATE/panes.next" "$HERDR_STATE/panes.tsv"
  : > "$HERDR_LOG"
  # This fixture asserts the complete logical panel, independently of the CI
  # runner's controlling-terminal size. The real-pane smoke test exercises the
  # terminal measurement branch.
  out=$(LINES=40 COLUMNS=120 run_cockpit panel 2>"$err") \
    || fail "cockpit panel could not render the live frame"
  [ ! -s "$err" ] \
    || fail "cockpit panel leaked a terminal probe error without a controlling tty: $(cat "$err")"
  assert_contains "$out" "ORCHESTRATION COCKPIT" "cockpit panel omitted its heading"
  assert_contains "$out" "NAVIGATOR Herdr sidebar (all spaces and agents)" \
    "cockpit panel did not identify its live navigator"
  assert_contains "$out" "PINNED firstmate head=w1:p1 [live]" \
    "cockpit panel did not identify the pinned controller"
  assert_contains "$out" "VIEWPORT tab=w1:t1" \
    "cockpit panel did not identify the persistent viewport"
  assert_contains "$out" "fm-claude-pane [working]" \
    "cockpit panel omitted the Herdr status for the viewport worker"
  # The slot holds one worker, and the panel still accounts for the rest rather
  # than quietly dropping them from the operator's view.
  [ "$(printf '%s\n' "$out" | sed -n '/^VIEWPORT /,/^PARKED /p' | grep -c '^  fm-')" = 1 ] \
    || fail "cockpit panel reported more than one worker in the viewport slot"
  assert_contains "$out" "PARKED each on its own tab" \
    "cockpit panel omitted the workers parked outside the viewport"
  assert_contains "$out" "fm-codex-pane [blocked] tab=" \
    "cockpit panel lost the parked worker and its tab"
  assert_contains "$out" "FLEET column=w1:p2 [live]" \
    "cockpit panel omitted the persistent live fleet column"
  log=$(cat "$HERDR_LOG")
  assert_not_contains "$log" "pane read" \
    "cockpit panel derived status from harness-rendered pane chrome"
  assert_contains "$out" "BOUNDARY display=all-homes steer=current-home backend=herdr" \
    "cockpit panel did not expose its display and steer boundary"
  assert_contains "$out" "FLEET STATUS" \
    "cockpit panel did not render the existing read-only fleet view"
  pass "cockpit panel uses Herdr agent status, not harness-rendered pane chrome"
}

test_panel_degrades_visibly_outside_herdr() {
  local out
  out=$(env -u HERDR_ENV -u TMUX FM_HOME="$HOME_DIR" LINES=40 COLUMNS=120 \
    "$COCKPIT" panel) \
    || fail "plain cockpit panel fallback should remain usable"
  assert_contains "$out" "NAVIGATOR plain fleet panel (Herdr sidebar unavailable on none)" \
    "plain cockpit panel did not explain its navigator fallback"
  assert_contains "$out" "PINNED unavailable; none keeps its existing peer-endpoint layout" \
    "plain cockpit panel silently implied pinned placement"
  assert_contains "$out" "BOUNDARY display=all-homes steer=current-home backend=none" \
    "plain cockpit panel lost the cross-home display boundary"
  assert_contains "$out" "FLEET STATUS" \
    "plain cockpit panel omitted the usable fleet view"
  pass "non-Herdr cockpit renders an explicit plain-panel fallback"
}

test_dead_head_is_preserved_until_explicit_new_context() {
  local out rc log
  awk -F '\t' -v OFS='\t' '$1 == "w1:p1" {$5="no-agent"} {print}' \
    "$HERDR_STATE/panes.tsv" > "$HERDR_STATE/panes.next"
  mv "$HERDR_STATE/panes.next" "$HERDR_STATE/panes.tsv"
  out=$(run_cockpit status 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "dead cockpit head still reported live"
  assert_contains "$out" "DEAD PANE w1:p1" "dead cockpit head lost its visible placeholder"
  assert_contains "$out" "[r] resume old" "dead cockpit head omitted resume-old guidance"
  assert_contains "$out" "[n] run bin/fm-cockpit.sh new" "dead cockpit head omitted clean-context guidance"

  printf 'w1:p9\tnew-firstmate-head\tw1:t1\tw1\tlive\n' >> "$HERDR_STATE/panes.tsv"
  : > "$HERDR_LOG"
  out=$(run_cockpit_at w1:p9 /tmp/fm-cockpit-test.sock new) \
    || fail "explicit clean-context cockpit adoption failed"
  assert_contains "$out" "adopted new clean-context head=w1:p9" \
    "clean-context adoption did not identify the new head"
  assert_grep 'head_pane_id=w1:p9' "$HOME_DIR/state/.herdr-cockpit" \
    "clean-context adoption did not advance the durable head"
  assert_contains "$(cat "$HERDR_STATE/panes.tsv")" $'w1:p1\t' \
    "clean-context adoption removed the old dead pane"
  log=$(cat "$HERDR_LOG")
  assert_contains "$log" "pane split w1:p9 --direction down --ratio 0.28" \
    "explicit clean-context adoption did not establish its fleet banner"
  assert_not_contains "$log" "pane close" "clean-context adoption closed the prior head"
  pass "dead head stays visible until explicit clean-context re-adoption"
}

# --- fleet banner layout -----------------------------------------------------
# A dedicated secondmate home keeps its own workspace, so these tests can build
# and tear down whole frames without disturbing the shared primary fixture.
LAYOUT_HOME="$TMP_ROOT/layout-home"
mkdir -p "$LAYOUT_HOME/state" "$LAYOUT_HOME/config"
printf 'layout\n' > "$LAYOUT_HOME/.fm-secondmate-home"

reset_layout_frame() {
  rm -f "$LAYOUT_HOME/state/.herdr-cockpit" "$LAYOUT_HOME/config/cockpit-layout" \
    "$LAYOUT_HOME/config/cockpit-sections" "$HERDR_STATE/fail-swap" \
    "$HERDR_STATE"/fail-*-after "$HERDR_STATE"/count-*
  awk -F '\t' '$4 != "w3" {print}' "$HERDR_STATE/panes.tsv" > "$HERDR_STATE/panes.next"
  mv "$HERDR_STATE/panes.next" "$HERDR_STATE/panes.tsv"
  printf 'w3:p1\tlayout-head\tw3:t1\tw3\tlive\n' >> "$HERDR_STATE/panes.tsv"
  : > "$HERDR_LOG"
}

fleet_panes_of() {  # this frame's recorded fleet panes, one per line
  grep '^fleet_pane_ids=' "$LAYOUT_HOME/state/.herdr-cockpit" | cut -d= -f2- | tr ',' '\n'
}

fleet_pane_at() {  # <1-based position>
  fleet_panes_of | sed -n "$1p"
}

added_layout_panes() {  # every non-head pane the fake screen currently carries
  awk -F '\t' '$4 == "w3" && $1 != "w3:p1" { printf "%s ", $1 } END { print "" }' \
    "$HERDR_STATE/panes.tsv"
}

run_layout_cockpit() {  # <action> [<args...>]
  PATH="$FAKEBIN:$PATH" \
    FM_HOME="$LAYOUT_HOME" \
    FM_FAKE_HERDR_STATE="$HERDR_STATE" \
    FM_FAKE_HERDR_LOG="$HERDR_LOG" \
    FM_FAKE_FLEET_HOME="${FM_FAKE_FLEET_HOME:-}" \
    FM_FAKE_FLEET_CWD="${FM_FAKE_FLEET_CWD:-}" \
    FM_COCKPIT_ROOT="$ROOT" \
    HERDR_ENV=1 \
    HERDR_SESSION=fmtest \
    HERDR_SOCKET_PATH=/tmp/fm-cockpit-test.sock \
    HERDR_PANE_ID=w3:p1 \
    "$COCKPIT" "$@"
}

layout_rows() {  # visual order of this frame's panes, top first
  awk -F '\t' '$4 == "w3" { printf "%s ", $1 } END { print "" }' "$HERDR_STATE/panes.tsv"
}

test_default_layout_warns_before_it_changes_the_screen() {
  local timeline out first second third
  reset_layout_frame
  # The warning and the herdr calls share one append-mode file, so their
  # relative order in it is the real order they happened in.
  timeline="$TMP_ROOT/layout-timeline.log"
  : > "$timeline"
  # shellcheck disable=SC2094  # deliberate: the fake appends its calls to the
  # same append-mode file this command's warnings go to, which is what makes
  # their relative order meaningful.
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$LAYOUT_HOME" \
    FM_FAKE_HERDR_STATE="$HERDR_STATE" FM_FAKE_HERDR_LOG="$timeline" \
    FM_COCKPIT_ROOT="$ROOT" HERDR_ENV=1 HERDR_SESSION=fmtest \
    HERDR_SOCKET_PATH=/tmp/fm-cockpit-test.sock HERDR_PANE_ID=w3:p1 \
    "$COCKPIT" adopt 2>>"$timeline") || fail "default banner adoption failed"
  assert_contains "$out" "adopted Herdr frame" "default adoption did not report its frame"

  local body warn_line split_line warnings
  body=$(cat "$timeline")
  assert_contains "$body" "this screen is about to change" \
    "no warning was given before the screen changed"
  assert_contains "$body" "fleet banner above the supervisor at 28% of the frame (stacked, fleet-first)" \
    "the warning did not name the exact shape about to be applied"
  assert_contains "$body" "one pane per group: waiting | ready | in-flight,blocked" \
    "the warning did not name the panes the region is about to become"
  assert_contains "$body" "no existing pane is closed, replaced, or re-split" \
    "the warning did not state what it leaves alone"
  assert_contains "$body" "$LAYOUT_HOME/config/cockpit-layout" \
    "the warning did not name the file that changes the layout"
  assert_contains "$body" "$LAYOUT_HOME/config/cockpit-sections" \
    "the warning did not name the file that changes the arrangement"
  warnings=$(grep -c 'this screen is about to change' "$timeline")
  [ "$warnings" = 1 ] \
    || fail "a three-pane region warned $warnings times instead of announcing itself once"
  warn_line=$(grep -n 'this screen is about to change' "$timeline" | head -1 | cut -d: -f1)
  split_line=$(grep -n '^pane split' "$timeline" | head -1 | cut -d: -f1)
  [ -n "$warn_line" ] && [ -n "$split_line" ] && [ "$warn_line" -lt "$split_line" ] \
    || fail "the warning did not precede the pane split that changed the screen"

  first=$(fleet_pane_at 1)
  second=$(fleet_pane_at 2)
  third=$(fleet_pane_at 3)
  assert_contains "$body" "pane split w3:p1 --direction down --ratio 0.28" \
    "the default region did not split the frame as a 28% stacked band"
  assert_contains "$body" "pane swap --source-pane w3:p1 --target-pane $first" \
    "the default fleet-first order did not put the region ahead of the supervisor"
  # Equal thirds of a stacked band: each division leaves the pane it splits with
  # one third of the whole, so the shares are 1/3 and then 1/2 of the remainder.
  assert_contains "$body" "pane split $first --direction right --ratio 0.3333" \
    "the second pane did not take an equal share across the band"
  assert_contains "$body" "pane split $second --direction right --ratio 0.5000" \
    "the third pane did not take an equal share of what was left"
  assert_contains "$body" "pane run $first env FM_HOME=$LAYOUT_HOME" \
    "the first pane was not launched for this home"
  assert_contains "$body" "pane run $first env FM_HOME=$LAYOUT_HOME FM_HERDR_LAB_HELPER= FM_HERDR_LAB_SESSION= $ROOT/bin/fm-fleet-view.sh" \
    "the fleet pane command did not resolve through the tracked code root"
  assert_contains "$body" "--geometry-command $ROOT/bin/fm-herdr-pane-geometry.sh" \
    "the fleet pane did not re-read its authoritative drawn rectangle on redraw"
  # The adapter is the only party that knows which pane it just recorded, so it
  # states that identity on the command line instead of trusting the painter to
  # find it in an environment this repo never sets.
  assert_contains "$body" "--herdr-session fmtest --herdr-pane $first" \
    "the first fleet pane was not launched bound to its own recorded pane"
  assert_contains "$body" "--herdr-session fmtest --herdr-pane $second" \
    "the second fleet pane was not launched bound to its own recorded pane"
  assert_contains "$body" "--herdr-session fmtest --herdr-pane $third" \
    "the third fleet pane was not launched bound to its own recorded pane"
  assert_not_contains "$body" "$LAYOUT_HOME/bin/fm-fleet-view.sh" \
    "the fleet pane command incorrectly resolved code through the operational home"
  assert_contains "$body" "--watch --section waiting" \
    "the decisions pane was not launched as its own section"
  assert_contains "$body" "--watch --section ready" \
    "the ready pane was not launched as its own section"
  assert_contains "$body" "--watch --section in-flight,blocked" \
    "the running-work pane was not launched with its section group"
  [ "$(layout_rows)" = "$first $second $third w3:p1 " ] \
    || fail "the fleet panes did not end up above the supervisor in reading order: $(layout_rows)"
  pass "the default region is three equal decisions-first panes announced once before they are applied"
}

test_sections_config_sets_the_pane_arrangement() {
  local out body first second
  reset_layout_frame
  printf '# the queue, then everything else\nready,waiting\nin-flight, blocked\n' \
    > "$LAYOUT_HOME/config/cockpit-sections"
  out=$(run_layout_cockpit adopt 2>&1) || fail "configured arrangement adoption failed: $out"
  body=$(cat "$HERDR_LOG")
  first=$(fleet_pane_at 1)
  second=$(fleet_pane_at 2)
  [ -n "$second" ] || fail "the configured arrangement did not create a second pane"
  [ -z "$(fleet_pane_at 3)" ] || fail "the configured arrangement created a third pane"
  assert_contains "$body" "pane split $first --direction right --ratio 0.5000" \
    "two configured panes did not divide the band in half"
  assert_contains "$body" "--watch --section ready,waiting" \
    "the first configured pane did not carry its own section group"
  assert_contains "$body" "--watch --section in-flight,blocked" \
    "a section list written with a space was not accepted"
  assert_grep 'fleet_pane_sections=ready,waiting|in-flight,blocked' \
    "$LAYOUT_HOME/state/.herdr-cockpit" \
    "the frame did not record which sections each pane holds"
  [ "$(layout_rows)" = "$first $second w3:p1 " ] \
    || fail "the configured panes did not sit above the supervisor: $(layout_rows)"
  pass "config/cockpit-sections chooses how many fleet panes there are and what each one holds"
}

test_invalid_sections_config_refuses_without_changing_the_screen() {
  local out rc before
  reset_layout_frame
  before=$(layout_rows)
  printf 'waiting\nnonsense\n' > "$LAYOUT_HOME/config/cockpit-sections"
  out=$(run_layout_cockpit adopt 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "an unknown fleet section was accepted"
  assert_contains "$out" 'fleet section "nonsense" must be one of' \
    "the refusal did not name the invalid section"
  assert_not_contains "$(cat "$HERDR_LOG")" "pane split" \
    "an invalid arrangement still changed the screen"
  assert_not_contains "$out" "this screen is about to change" \
    "an invalid arrangement warned about a change it never made"
  [ "$(layout_rows)" = "$before" ] || fail "an invalid arrangement rearranged the frame"
  [ ! -e "$LAYOUT_HOME/state/.herdr-cockpit" ] \
    || fail "an invalid arrangement published a frame record"

  printf 'waiting,ready\nready\n' > "$LAYOUT_HOME/config/cockpit-sections"
  out=$(run_layout_cockpit adopt 2>&1) \
    && fail "a section claimed by two panes was accepted"
  assert_contains "$out" 'fleet section "ready" is listed more than once' \
    "the refusal did not name the duplicated section"

  printf 'waiting\nready\nin-flight\nblocked\nfinished\nfailed\nwaiting\n' \
    > "$LAYOUT_HOME/config/cockpit-sections"
  out=$(run_layout_cockpit adopt 2>&1) \
    && fail "an arrangement past the supported pane count was accepted"
  assert_contains "$out" "at most 6" "the refusal did not name the supported pane count"
  pass "an invalid arrangement refuses and leaves the screen exactly as it was"
}

test_layout_config_sets_direction_order_and_ratio() {
  local out first second third body
  reset_layout_frame
  printf 'side-by-side fleet-last 0.35\n' > "$LAYOUT_HOME/config/cockpit-layout"
  out=$(run_layout_cockpit adopt 2>&1) || fail "configured banner adoption failed"
  body=$(cat "$HERDR_LOG")
  first=$(fleet_pane_at 1)
  second=$(fleet_pane_at 2)
  third=$(fleet_pane_at 3)
  assert_contains "$body" "pane split w3:p1 --direction right --ratio 0.6500" \
    "a fleet-last side-by-side layout did not leave the supervisor the first 65%"
  assert_not_contains "$body" "pane swap" \
    "a fleet-last order still reordered the panes"
  # A column is divided the other way, so its panes stack instead of sitting
  # side by side; the band never divides along the axis it already spans.
  assert_contains "$body" "pane split $first --direction down --ratio 0.3333" \
    "a side-by-side region did not stack its panes down the column"
  assert_contains "$body" "pane split $second --direction down --ratio 0.5000" \
    "the third pane of a column did not stack under the second"
  [ "$(layout_rows)" = "w3:p1 $first $second $third " ] \
    || fail "the configured region did not follow the supervisor: $(layout_rows)"
  pass "config/cockpit-layout sets the region's direction, order, and ratio"
}

test_invalid_layout_config_refuses_without_changing_the_screen() {
  local out rc before
  reset_layout_frame
  before=$(layout_rows)
  printf 'stacked sideways\n' > "$LAYOUT_HOME/config/cockpit-layout"
  out=$(run_layout_cockpit adopt 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "an unreadable layout was accepted"
  assert_contains "$out" 'layout order "sideways" must be fleet-first or fleet-last' \
    "the refusal did not name the invalid setting"
  assert_not_contains "$(cat "$HERDR_LOG")" "pane split" \
    "an invalid layout still changed the screen"
  assert_not_contains "$out" "this screen is about to change" \
    "an invalid layout warned about a change it never made"
  [ "$(layout_rows)" = "$before" ] || fail "an invalid layout rearranged the frame"
  [ ! -e "$LAYOUT_HOME/state/.herdr-cockpit" ] \
    || fail "an invalid layout published a frame record"

  printf 'stacked fleet-first 0.99\n' > "$LAYOUT_HOME/config/cockpit-layout"
  out=$(run_layout_cockpit adopt 2>&1) \
    && fail "an out-of-range ratio was accepted"
  assert_contains "$out" "outside the supported 0.10-0.90 range" \
    "the refusal did not name the supported ratio range"
  pass "an invalid layout refuses and leaves the screen exactly as it was"
}

test_failed_reorder_restores_the_original_screen() {
  local out rc before
  reset_layout_frame
  before=$(layout_rows)
  touch "$HERDR_STATE/fail-swap"
  out=$(run_layout_cockpit adopt 2>&1)
  rc=$?
  rm -f "$HERDR_STATE/fail-swap"
  [ "$rc" -ne 0 ] || fail "adoption accepted a banner it could not order"
  assert_contains "$out" "the original screen was restored" \
    "a failed reorder did not say the screen was put back"
  [ "$(layout_rows)" = "$before" ] \
    || fail "a failed reorder left the frame changed: $(layout_rows)"
  [ ! -e "$LAYOUT_HOME/state/.herdr-cockpit" ] \
    || fail "a failed reorder published a frame record"
  pass "a banner that cannot be ordered as configured restores the original screen"
}

test_failed_reorder_reports_when_the_screen_cannot_be_restored() {
  local out rc fleet
  reset_layout_frame
  touch "$HERDR_STATE/fail-swap" "$HERDR_STATE/fail-close"
  out=$(run_layout_cockpit adopt 2>&1)
  rc=$?
  rm -f "$HERDR_STATE/fail-swap" "$HERDR_STATE/fail-close"
  [ "$rc" -ne 0 ] || fail "adoption accepted a banner it could neither order nor remove"
  fleet=$(awk -F '\t' '$4 == "w3" && $1 != "w3:p1" {print $1}' "$HERDR_STATE/panes.tsv")
  [ -n "$fleet" ] || fail "the failed close did not leave the added pane in the fake screen"
  assert_contains "$out" "NOT-RESTORED" \
    "a failed rollback did not report that the screen remained changed"
  assert_contains "$out" "added fleet pane $fleet could not be removed" \
    "a failed rollback did not name the pane still on screen"
  assert_contains "$out" "the screen still carries it" \
    "a failed rollback did not explain the remaining screen state"
  [ ! -e "$LAYOUT_HOME/state/.herdr-cockpit" ] \
    || fail "a failed rollback published a frame record"
  pass "a failed banner rollback reports the pane still on screen"
}

test_failed_record_publication_reports_when_the_screen_cannot_be_restored() {
  local out rc stranded
  reset_layout_frame
  rmdir "$LAYOUT_HOME/state"
  touch "$LAYOUT_HOME/state" "$HERDR_STATE/fail-close"
  out=$(run_layout_cockpit adopt 2>&1)
  rc=$?
  rm -f "$LAYOUT_HOME/state" "$HERDR_STATE/fail-close"
  mkdir "$LAYOUT_HOME/state"
  [ "$rc" -ne 0 ] || fail "adoption accepted a frame record it could not publish"
  stranded=$(added_layout_panes)
  [ "$(printf '%s' "$stranded" | wc -w)" = 3 ] \
    || fail "the failed record rollback did not leave every pane in the fake screen: $stranded"
  assert_contains "$out" "could not publish the cockpit frame record" \
    "a record-publication failure did not name its cause"
  assert_contains "$out" "NOT-RESTORED" \
    "a failed record rollback did not report that the screen remained changed"
  assert_contains "$out" "added fleet panes ${stranded% } could not be removed" \
    "a failed record rollback did not name every pane still on screen"
  [ ! -e "$LAYOUT_HOME/state/.herdr-cockpit" ] \
    || fail "failed record publication left a frame record"
  pass "a failed record rollback reports every unrecorded pane still on screen"
}

test_a_later_pane_failure_removes_every_pane_the_region_added() {
  local out rc before
  reset_layout_frame
  before=$(layout_rows)
  # The whole region is built before anything is launched, so failing the third
  # split is a failure with two panes already on screen.
  printf '2\n' > "$HERDR_STATE/fail-split-after"
  out=$(run_layout_cockpit adopt 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "adoption accepted a region it could not finish building"
  assert_contains "$out" "could not divide the fleet region into its configured panes" \
    "a failed later split did not name what went wrong"
  assert_contains "$out" "the original screen was restored" \
    "a failed later split did not say the screen was put back"
  [ -z "$(added_layout_panes)" ] \
    || fail "a failed later split left panes behind: $(added_layout_panes)"
  [ "$(layout_rows)" = "$before" ] \
    || fail "a failed later split left the frame changed: $(layout_rows)"
  [ ! -e "$LAYOUT_HOME/state/.herdr-cockpit" ] \
    || fail "a failed later split published a frame record"

  # The same guarantee once every pane exists and the last one will not start.
  reset_layout_frame
  printf '2\n' > "$HERDR_STATE/fail-run-after"
  out=$(run_layout_cockpit adopt 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "adoption accepted a region whose last pane never launched"
  assert_contains "$out" "could not launch the fleet banner" \
    "a failed later launch did not name what went wrong"
  assert_contains "$out" "the original screen was restored" \
    "a failed later launch did not say the screen was put back"
  [ -z "$(added_layout_panes)" ] \
    || fail "a failed later launch left panes behind: $(added_layout_panes)"
  pass "a failure on a later pane removes every pane the region added"
}

test_a_later_pane_cleanup_failure_reports_each_pane_still_on_screen() {
  local out rc stranded
  reset_layout_frame
  # Every pane is created, the last one will not launch, and only the first
  # removal succeeds: the report must distinguish what came off the screen from
  # what is still on it.
  printf '2\n' > "$HERDR_STATE/fail-run-after"
  printf '1\n' > "$HERDR_STATE/fail-close-after"
  out=$(run_layout_cockpit adopt 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "adoption accepted a region it could neither launch nor remove"
  stranded=$(added_layout_panes)
  [ "$(printf '%s' "$stranded" | wc -w)" = 2 ] \
    || fail "the one verified removal did not take exactly one pane off the screen: $stranded"
  assert_contains "$out" "NOT-RESTORED" \
    "a partial rollback did not report that the screen remained changed"
  assert_contains "$out" "added fleet panes ${stranded% } could not be removed" \
    "a partial rollback did not name exactly the panes still on screen"
  assert_not_contains "$out" "the original screen was restored" \
    "a partial rollback still claimed the screen was put back"
  [ ! -e "$LAYOUT_HOME/state/.herdr-cockpit" ] \
    || fail "a partial rollback published a frame record"
  pass "a rollback that cannot remove every pane reports exactly which ones remain"
}

test_re_adoption_neither_warns_nor_touches_the_screen() {
  local out before
  reset_layout_frame
  run_layout_cockpit adopt >/dev/null 2>&1 || fail "banner adoption failed"
  before=$(layout_rows)
  : > "$HERDR_LOG"
  out=$(run_layout_cockpit adopt 2>&1) || fail "banner re-adoption failed"
  assert_contains "$out" "re-adopted Herdr frame" "restart did not re-adopt the frame"
  assert_not_contains "$out" "this screen is about to change" \
    "re-adoption warned about a change it never made"
  assert_not_contains "$(cat "$HERDR_LOG")" "pane split" "re-adoption rebuilt the banner"
  assert_not_contains "$(cat "$HERDR_LOG")" "pane swap" "re-adoption reordered a live frame"
  [ "$(layout_rows)" = "$before" ] || fail "re-adoption rearranged the frame"
  pass "re-adopting a live frame changes nothing and announces nothing"
}

set_fleet_pane_status() {  # <status> [<1-based fleet pane, default 1>]
  local fleet
  fleet=$(fleet_pane_at "${2:-1}")
  awk -F '\t' -v OFS='\t' -v pane="$fleet" -v status="$1" \
    '$1 == pane {$5=status} {print}' "$HERDR_STATE/panes.tsv" > "$HERDR_STATE/panes.next"
  mv "$HERDR_STATE/panes.next" "$HERDR_STATE/panes.tsv"
  printf '%s' "$fleet"
}

test_cockpit_liveness_requires_exact_painter_ownership() {
  local fleet out
  reset_layout_frame
  run_layout_cockpit adopt >/dev/null 2>&1 || fail "banner adoption failed"
  fleet=$(set_fleet_pane_status fleet-relative)
  out=$(run_layout_cockpit status 2>&1) \
    && fail "a same-basename painter from another executable was accepted"
  assert_contains "$out" "(fleet-no-fleet-process)" \
    "the wrong executable did not fail painter identity"

  set_fleet_pane_status fleet-split-evidence >/dev/null
  out=$(run_layout_cockpit status 2>&1) \
    && fail "split ownership and geometry evidence was accepted"
  assert_contains "$out" "(fleet-no-geometry-binding)" \
    "geometry from another process satisfied the exact painter"

  set_fleet_pane_status fleet-live >/dev/null
  FM_FAKE_FLEET_CWD="$TMP_ROOT/other-home"
  out=$(run_layout_cockpit status 2>&1) \
    && fail "a painter running from another home was accepted"
  assert_contains "$out" "(fleet-no-fleet-process)" \
    "the wrong foreground cwd did not fail painter identity"

  FM_FAKE_FLEET_CWD=""
  run_layout_cockpit status >/dev/null 2>&1 \
    || fail "the exact painter executable and foreground cwd were rejected"
  pass "cockpit liveness requires the exact painter executable and foreground cwd"
}

test_an_unresolved_home_path_still_matches_the_live_banner() {
  local link out
  reset_layout_frame
  run_layout_cockpit adopt >/dev/null 2>&1 || fail "banner adoption failed"
  set_fleet_pane_status fleet-env-home >/dev/null
  FM_FAKE_FLEET_HOME="$LAYOUT_HOME"
  # bin/fm-spawn.sh reaches the same check with its own unresolved FM_HOME, so
  # a banner must not read as dead just because the caller spelled the home
  # through a symlink.
  link="$TMP_ROOT/layout-home-link"
  rm -f "$link"
  ln -s "$LAYOUT_HOME" "$link"
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$link" \
    FM_FAKE_HERDR_STATE="$HERDR_STATE" FM_FAKE_HERDR_LOG="$HERDR_LOG" \
    FM_FAKE_FLEET_HOME="$LAYOUT_HOME" FM_COCKPIT_ROOT="$ROOT" \
    HERDR_ENV=1 HERDR_SESSION=fmtest \
    HERDR_SOCKET_PATH=/tmp/fm-cockpit-test.sock HERDR_PANE_ID=w3:p1 \
    bash -c '. "$0/bin/backends/herdr.sh"
      fm_backend_herdr_cockpit_binding_diagnose "$1/state" "$1" fmtest' \
      "$ROOT" "$link")
  [ "$out" = ok ] || fail "an unresolved home path rejected its own live banner: $out"
  FM_FAKE_FLEET_HOME=""
  pass "a home spelled through a symlink still matches its own live banner"
}

# A fleet painter launched before --geometry-command existed keeps running
# forever: it satisfies every other liveness check, so the region is reported
# live and never rebuilt, while it paints to the pane's own pty instead of the
# drawn rectangle. On 2026-08-29 the captain's cockpit was still running
# painters started on 2026-08-13 for exactly that reason, and their frames
# wrapped, scrolled, and left fragments of several redraws on screen at once.
# A pane that cannot paint to the drawn rectangle is not live.
test_a_fleet_painter_without_the_geometry_binding_is_not_live() {
  local fleet out
  reset_layout_frame
  run_layout_cockpit adopt >/dev/null 2>&1 || fail "banner adoption failed"
  fleet=$(set_fleet_pane_status fleet-stale-painter)
  out=$(run_layout_cockpit status 2>&1) \
    && fail "status reported a live region for a painter with no geometry binding"
  assert_contains "$out" "(fleet-no-geometry-binding)" \
    "status did not name the missing geometry binding as the failing check"
  assert_contains "$out" "not painting to the pane's drawn size" \
    "the refusal did not explain the missing geometry binding in plain words"
  out=$(LINES=40 COLUMNS=120 run_layout_cockpit panel 2>&1) \
    || fail "panel did not render a region with a stale painter"
  assert_contains "$out" "FLEET column=$fleet [no-geometry-binding]" \
    "the panel did not name the pane whose painter cannot size itself"

  # Restoring a painter that IS bound to the drawn rectangle restores the region.
  set_fleet_pane_status fleet-live >/dev/null
  run_layout_cockpit status >/dev/null 2>&1 \
    || fail "a geometry-bound painter did not restore the region"
  pass "a fleet pane whose painter cannot size itself to the drawn rectangle is not live"
}

# A painter that is running, from the right executable and home, showing the
# recorded sections, and carrying --geometry-command still cannot draw anything
# unless it also knows WHICH pane it is. Without that identity the geometry read
# fails on every redraw, the pane shows a degraded panel, and the region is
# reported live the whole time - the frame is satisfied while nothing usable is
# on screen. Liveness has to mean the painter holds the identity its geometry
# binding needs, and that it is this pane's identity rather than any pane's.
test_a_fleet_painter_without_its_pane_identity_is_not_live() {
  local fleet out
  reset_layout_frame
  run_layout_cockpit adopt >/dev/null 2>&1 || fail "banner adoption failed"

  fleet=$(set_fleet_pane_status fleet-no-pane-identity)
  out=$(run_layout_cockpit status 2>&1) \
    && fail "status reported a live region for a painter with no pane identity"
  assert_contains "$out" "(fleet-no-pane-identity)" \
    "status did not name the missing pane identity as the failing check"
  assert_contains "$out" "which pane it is painting" \
    "the refusal did not explain the missing pane identity in plain words"
  out=$(LINES=40 COLUMNS=120 run_layout_cockpit panel 2>&1) \
    || fail "panel did not render a region with an unidentified painter"
  assert_contains "$out" "FLEET column=$fleet [no-pane-identity]" \
    "the panel did not name the pane whose painter has no identity"

  set_fleet_pane_status fleet-foreign-pane-identity >/dev/null
  out=$(run_layout_cockpit status 2>&1) \
    && fail "status accepted a painter bound to a different pane"
  assert_contains "$out" "(fleet-no-pane-identity)" \
    "a painter bound to another pane was not named as an identity failure"

  set_fleet_pane_status fleet-foreign-session-identity >/dev/null
  out=$(run_layout_cockpit status 2>&1) \
    && fail "status accepted a painter bound to a different session"
  assert_contains "$out" "(fleet-no-pane-identity)" \
    "a painter bound to another session was not named as an identity failure"

  set_fleet_pane_status fleet-live >/dev/null
  run_layout_cockpit status >/dev/null 2>&1 \
    || fail "a painter carrying its own recorded pane identity was rejected"
  pass "a fleet pane whose painter does not hold that pane's own identity is not live"
}

test_fleet_diagnostics_name_the_check_that_failed() {
  local fleet out
  reset_layout_frame
  run_layout_cockpit adopt >/dev/null 2>&1 || fail "banner adoption failed"
  fleet=$(set_fleet_pane_status fleet-gone)
  out=$(LINES=40 COLUMNS=120 run_layout_cockpit panel 2>&1) \
    || fail "panel did not render an unreachable banner"
  assert_contains "$out" "FLEET column=$fleet [no-process-info]" \
    "an unreachable banner pane did not report that cause"

  set_fleet_pane_status fleet-unreadable >/dev/null
  out=$(LINES=40 COLUMNS=120 run_layout_cockpit panel 2>&1) \
    || fail "panel did not render an untrusted response"
  assert_contains "$out" "FLEET column=$fleet [unreadable]" \
    "an untrusted process report did not report that cause"

  set_fleet_pane_status fleet-no-watch >/dev/null
  out=$(LINES=40 COLUMNS=120 run_layout_cockpit panel 2>&1) \
    || fail "panel did not render a non-watching banner"
  assert_contains "$out" "FLEET column=$fleet [no-fleet-process]" \
    "a pane running no fleet view did not report that cause"
  pass "each fleet-banner failure reports its own cause instead of one collapsed verdict"
}

test_every_fleet_pane_must_be_live_and_show_what_the_frame_recorded() {
  local out live third
  reset_layout_frame
  run_layout_cockpit adopt >/dev/null 2>&1 || fail "region adoption failed"
  live=$(LINES=40 COLUMNS=120 run_layout_cockpit panel 2>&1) \
    || fail "panel did not render the live region"
  assert_contains "$live" "FLEET panes=3 [live]" \
    "the panel did not report the region as its several panes"
  assert_contains "$live" "1 waiting $(fleet_pane_at 1)" \
    "the panel did not name the first pane by what it shows"
  assert_contains "$live" "3 in-flight,blocked $(fleet_pane_at 3)" \
    "the panel did not name the last pane by what it shows"

  # A pane other than the first is just as load-bearing: the region is live
  # only while every one of its panes is.
  third=$(set_fleet_pane_status fleet-gone 3)
  out=$(run_layout_cockpit status 2>&1) \
    && fail "status reported a live region with its third pane gone"
  assert_contains "$out" "(fleet-no-process-info)" \
    "status did not name the failing check for a later pane"
  out=$(LINES=40 COLUMNS=120 run_layout_cockpit panel 2>&1) \
    || fail "panel did not render a region with one dead pane"
  assert_contains "$out" "FLEET column=$third [no-process-info]" \
    "the panel did not name the exact pane that failed"

  # A pane running a fleet view for the right home, watching, but showing a
  # different part of the fleet than the record binds it to.
  set_fleet_pane_status fleet-live 3 >/dev/null
  out=$(run_layout_cockpit status 2>&1) || fail "restoring the third pane did not restore the region"
  set_fleet_pane_status fleet-other-sections 2 >/dev/null
  out=$(run_layout_cockpit status 2>&1) \
    && fail "status accepted a fleet pane showing sections the frame never recorded"
  assert_contains "$out" "(fleet-wrong-sections)" \
    "status did not distinguish a mismatched section list from a missing fleet view"
  assert_contains "$out" "showing different sections than the frame recorded" \
    "the refusal did not explain the section mismatch in plain words"
  pass "the region is live only while every pane is live and showing what the frame recorded"
}

test_a_version_two_frame_stays_live_as_its_single_pane_arrangement() {
  local out
  reset_layout_frame
  # A frame adopted before the region could hold more than one pane: one banner,
  # no recorded section argument. It stays usable, and re-adoption leaves it
  # alone rather than quietly rearranging a screen the operator already has.
  printf 'w3:p2\tfirstmate-fleet\tw3:t1\tw3\tfleet-live\n' >> "$HERDR_STATE/panes.tsv"
  cat > "$LAYOUT_HOME/state/.herdr-cockpit" <<EOF
version=2
home=$LAYOUT_HOME
session=fmtest
workspace_id=w3
tab_id=w3:t1
head_pane_id=w3:p1
viewport_pane_id=
fleet_pane_id=w3:p2
EOF
  : > "$HERDR_LOG"
  out=$(run_layout_cockpit status 2>&1) \
    || fail "a single-pane frame from before the arrangement was rejected: $out"
  assert_contains "$out" "COCKPIT: live session=fmtest" \
    "a single-pane frame did not report itself live"
  out=$(LINES=40 COLUMNS=120 run_layout_cockpit panel 2>&1) \
    || fail "a single-pane frame could not be rendered"
  assert_contains "$out" "FLEET column=w3:p2 [live]" \
    "a single-pane frame did not render as one banner"
  assert_contains "$out" "1 all w3:p2" \
    "a banner with no recorded sections was not shown as holding all of them"

  out=$(run_layout_cockpit adopt 2>&1) || fail "a single-pane frame could not be re-adopted: $out"
  assert_contains "$out" "re-adopted Herdr frame" "re-adoption did not report the preserved frame"
  assert_not_contains "$out" "this screen is about to change" \
    "re-adoption rearranged a frame the operator already had"
  assert_not_contains "$(cat "$HERDR_LOG")" "pane split" \
    "re-adoption rebuilt an existing frame into the configured arrangement"
  assert_grep 'version=2' "$LAYOUT_HOME/state/.herdr-cockpit" \
    "re-adoption rewrote a frame it was supposed to preserve"
  pass "a frame adopted as one banner stays live and is never rearranged behind the operator"
}

test_banner_zoom_is_reversible_and_moves_no_pane() {
  local fleet before out log
  reset_layout_frame
  run_layout_cockpit adopt >/dev/null 2>&1 || fail "banner adoption failed"
  fleet=$(fleet_pane_at 1)
  before=$(layout_rows)
  : > "$HERDR_LOG"
  out=$(run_layout_cockpit zoom on 2>&1) || fail "the banner could not be zoomed: $out"
  assert_contains "$out" "fleet banner $fleet fills the frame" \
    "zooming did not report the banner filling the frame"
  out=$(run_layout_cockpit zoom off 2>&1) || fail "the banner could not be unzoomed: $out"
  assert_contains "$out" "back to its configured size" \
    "unzooming did not report the banner restored"
  log=$(cat "$HERDR_LOG")
  assert_contains "$log" "pane zoom $fleet --on" "zoom on did not reach the banner pane"
  assert_contains "$log" "pane zoom $fleet --off" "zoom off did not reach the banner pane"
  assert_not_contains "$log" "pane split" "zooming re-split the frame"
  assert_not_contains "$log" "pane move" "zooming moved a pane"
  assert_not_contains "$log" "pane close" "zooming closed a pane"
  [ "$(layout_rows)" = "$before" ] || fail "zooming rearranged the frame"
  run_layout_cockpit zoom sideways >/dev/null 2>&1 \
    && fail "an unsupported zoom mode was accepted"

  # Every pane of the region is readable up close, not only the first one.
  : > "$HERDR_LOG"
  out=$(run_layout_cockpit zoom on 3 2>&1) || fail "a later fleet pane could not be zoomed: $out"
  assert_contains "$out" "fleet banner $(fleet_pane_at 3) fills the frame" \
    "zooming a later pane did not report that pane"
  assert_contains "$(cat "$HERDR_LOG")" "pane zoom $(fleet_pane_at 3) --on" \
    "zooming a later pane did not reach it"
  out=$(run_layout_cockpit zoom on 9 2>&1) \
    && fail "zoom accepted a fleet pane this frame does not have"
  assert_contains "$out" "this frame has no fleet pane 9" \
    "zoom did not explain which pane was missing"
  [ "$(layout_rows)" = "$before" ] || fail "a refused zoom rearranged the frame"
  pass "each fleet pane zooms and unzooms without splitting, moving, or closing a pane"
}

test_status_names_the_check_that_failed() {
  local out
  reset_layout_frame
  out=$(run_layout_cockpit status 2>&1) \
    && fail "status reported a live frame before one was adopted"
  assert_contains "$out" "no frame has been adopted for this home yet" \
    "status did not name the absent frame as the cause"
  assert_contains "$out" "(record-absent)" "status omitted the exact failing check"
  assert_not_contains "$out" "absent, invalid, or dead" \
    "status still collapsed every cause into one verdict"

  run_layout_cockpit adopt >/dev/null 2>&1 || fail "banner adoption failed"
  set_fleet_pane_status fleet-no-watch >/dev/null
  out=$(run_layout_cockpit status 2>&1) \
    && fail "status reported a live frame with no fleet view running"
  assert_contains "$out" "not running the fleet view" \
    "status did not name the idle banner pane as the cause"
  assert_contains "$out" "(fleet-no-fleet-process)" "status omitted the exact failing check"

  set_fleet_pane_status fleet-gone >/dev/null
  out=$(run_layout_cockpit status 2>&1) \
    && fail "status reported a live frame with an unreachable banner pane"
  assert_contains "$out" "(fleet-no-process-info)" \
    "status did not distinguish an unreachable pane from an idle one"
  pass "status names the exact check that failed instead of one collapsed verdict"
}

test_frame_re_adoption_is_idempotent
test_space_switch_focuses_one_complete_frame_and_rejects_nesting
test_version_one_frame_migrates_and_failed_creation_cleans_up
test_adoption_requires_the_native_session_socket
test_first_worker_lands_in_viewport_and_later_spawns_do_not_steal_it
test_focus_never_moves_a_pane_this_home_does_not_own
test_rotation_orders_by_task_id_wraps_and_shares_the_placement_path
test_focus_listener_converges_and_current_occupant_is_idempotent
test_focus_listener_requires_explicit_start_and_stop_ends_supervisor_and_reader
test_rotation_ring_excludes_the_supervisor_and_fleet_panes
test_displaced_workers_stay_reachable_without_a_listener
test_display_and_steer_boundary_remains_explicit
test_panel_renders_the_live_frame_and_fleet_view
test_panel_degrades_visibly_outside_herdr
test_dead_head_is_preserved_until_explicit_new_context
test_default_layout_warns_before_it_changes_the_screen
test_sections_config_sets_the_pane_arrangement
test_invalid_sections_config_refuses_without_changing_the_screen
test_layout_config_sets_direction_order_and_ratio
test_invalid_layout_config_refuses_without_changing_the_screen
test_failed_reorder_restores_the_original_screen
test_failed_reorder_reports_when_the_screen_cannot_be_restored
test_a_later_pane_failure_removes_every_pane_the_region_added
test_a_later_pane_cleanup_failure_reports_each_pane_still_on_screen
test_failed_record_publication_reports_when_the_screen_cannot_be_restored
test_re_adoption_neither_warns_nor_touches_the_screen
test_cockpit_liveness_requires_exact_painter_ownership
test_an_unresolved_home_path_still_matches_the_live_banner
test_fleet_diagnostics_name_the_check_that_failed
test_a_fleet_painter_without_the_geometry_binding_is_not_live
test_a_fleet_painter_without_its_pane_identity_is_not_live
test_every_fleet_pane_must_be_live_and_show_what_the_frame_recorded
test_a_version_two_frame_stays_live_as_its_single_pane_arrangement
test_banner_zoom_is_reversible_and_moves_no_pane
test_status_names_the_check_that_failed
