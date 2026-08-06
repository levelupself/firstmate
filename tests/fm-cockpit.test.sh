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
      jq -n --arg id "$(pane_field "$row" 1)" --arg label "$(pane_field "$row" 2)" \
        --arg tab "$(pane_field "$row" 3)" --arg workspace "$(pane_field "$row" 4)" \
        '{result:{pane:{pane_id:$id,label:$label,tab_id:$tab,workspace_id:$workspace}}}'
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
    awk -F '\t' -v OFS='\t' -v id="$id" '$1 == id {$5="fleet-live"} {print}' \
      "$state/panes.tsv" > "$state/panes.next"
    mv "$state/panes.next" "$state/panes.tsv"
    printf '%s\n' '{"result":{"type":"command_started"}}'
    ;;
  "pane process-info")
    info_pane=$4
    row=$(pane_row "$info_pane")
    [ -n "$row" ] || exit 1
    status=$(printf '%s' "$row" | awk -F '\t' '{print $5}')
    emit_processes() {  # <argv-json>
      jq -n --arg pane "$info_pane" --argjson argv "$1" \
        '{result:{type:"pane_process_info",process_info:{pane_id:$pane,shell_pid:100,
          foreground_process_group_id:101,foreground_processes:[
            {pid:101,name:"bash",argv:$argv}]}}}'
    }
    case "$status" in
      fleet-live)
        emit_processes "$(jq -cn --arg s "$FM_COCKPIT_ROOT/bin/fm-fleet-view.sh" \
          '["bash",$s,"--watch"]')"
        ;;
      fleet-relative)
        # The same watcher, started by hand from the checkout through a
        # relative path rather than the adapter's absolute invocation.
        emit_processes '["bash","bin/fm-fleet-view.sh","--watch"]'
        ;;
      fleet-env-home)
        emit_processes "$(jq -cn --arg s "$FM_COCKPIT_ROOT/bin/fm-fleet-view.sh" \
          --arg h "FM_HOME=${FM_FAKE_FLEET_HOME:-}" '["env",$h,$s,"--watch"]')"
        ;;
      fleet-no-watch)
        emit_processes "$(jq -cn --arg s "$FM_COCKPIT_ROOT/bin/fm-fleet-view.sh" \
          '["bash",$s]')"
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
  assert_grep 'fleet_pane_id=w1:p2' "$HOME_DIR/state/.herdr-cockpit" \
    "first adoption did not bind the persistent fleet pane"
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
  assert_grep 'version=2' "$SECOND_HOME/state/.herdr-cockpit" \
    "version-1 cockpit record did not advance atomically"

  fleet=$(grep '^fleet_pane_id=' "$SECOND_HOME/state/.herdr-cockpit" | cut -d= -f2-)
  awk -F '\t' -v OFS='\t' -v pane="$fleet" '$1 == pane {$5="no-agent"} {print}' \
    "$HERDR_STATE/panes.tsv" > "$HERDR_STATE/panes.next"
  mv "$HERDR_STATE/panes.next" "$HERDR_STATE/panes.tsv"
  record_hash=$(sha256sum "$SECOND_HOME/state/.herdr-cockpit" | awk '{print $1}')
  : > "$HERDR_LOG"
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$SECOND_HOME" \
    FM_FAKE_HERDR_STATE="$HERDR_STATE" FM_FAKE_HERDR_LOG="$HERDR_LOG" \
    FM_COCKPIT_ROOT="$ROOT" HERDR_ENV=1 HERDR_SESSION=fmtest \
    HERDR_SOCKET_PATH=/tmp/fm-cockpit-test.sock HERDR_PANE_ID=w2:p1 \
    "$COCKPIT" panel) || fail "dead fleet column could not be rendered read-only"
  assert_contains "$out" "FLEET column=$fleet [no-fleet-process]; frame preserved without rebuild" \
    "a fleet pane running no fleet view did not report that exact cause"
  assert_not_contains "$(cat "$HERDR_LOG")" "pane split" \
    "dead fleet command was silently rebuilt"
  [ "$record_hash" = "$(sha256sum "$SECOND_HOME/state/.herdr-cockpit" | awk '{print $1}')" ] \
    || fail "dead fleet rendering rewrote the frame record"

  rm "$SECOND_HOME/state/.herdr-cockpit"
  awk -F '\t' -v pane="$fleet" '$1 != pane {print}' \
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
  local first second log live out rc
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
  local current target log move_count reader_count out
  current=$(pane_id_by_label fm-one)
  target=$(pane_id_by_label fm-two)
  : > "$HERDR_LOG"
  rm -f "$HERDR_STATE/focus-reader-count"
  timeout 1 env \
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
    "$COCKPIT" focus-listen >/dev/null 2>&1 || true
  log=$(cat "$HERDR_LOG")
  move_count=$(grep -c '^pane move ' "$HERDR_LOG" || true)
  reader_count=$(cat "$HERDR_STATE/focus-reader-count")
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
  out=$(run_cockpit panel 2>"$err") || fail "cockpit panel could not render the live frame"
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
  out=$(env -u HERDR_ENV -u TMUX FM_HOME="$HOME_DIR" "$COCKPIT" panel) \
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
    "$HERDR_STATE/fail-swap"
  awk -F '\t' '$4 != "w3" {print}' "$HERDR_STATE/panes.tsv" > "$HERDR_STATE/panes.next"
  mv "$HERDR_STATE/panes.next" "$HERDR_STATE/panes.tsv"
  printf 'w3:p1\tlayout-head\tw3:t1\tw3\tlive\n' >> "$HERDR_STATE/panes.tsv"
  : > "$HERDR_LOG"
}

run_layout_cockpit() {  # <action> [<args...>]
  PATH="$FAKEBIN:$PATH" \
    FM_HOME="$LAYOUT_HOME" \
    FM_FAKE_HERDR_STATE="$HERDR_STATE" \
    FM_FAKE_HERDR_LOG="$HERDR_LOG" \
    FM_FAKE_FLEET_HOME="${FM_FAKE_FLEET_HOME:-}" \
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
  local timeline out fleet
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

  local body warn_line split_line
  body=$(cat "$timeline")
  assert_contains "$body" "this screen is about to change" \
    "no warning was given before the screen changed"
  assert_contains "$body" "fleet banner above the supervisor at 28% of the frame (stacked, fleet-first)" \
    "the warning did not name the exact shape about to be applied"
  assert_contains "$body" "no existing pane is closed, replaced, or re-split" \
    "the warning did not state what it leaves alone"
  assert_contains "$body" "$LAYOUT_HOME/config/cockpit-layout" \
    "the warning did not name the file that changes the layout"
  warn_line=$(grep -n 'this screen is about to change' "$timeline" | head -1 | cut -d: -f1)
  split_line=$(grep -n '^pane split' "$timeline" | head -1 | cut -d: -f1)
  [ -n "$warn_line" ] && [ -n "$split_line" ] && [ "$warn_line" -lt "$split_line" ] \
    || fail "the warning did not precede the pane split that changed the screen"

  fleet=$(grep '^fleet_pane_id=' "$LAYOUT_HOME/state/.herdr-cockpit" | cut -d= -f2-)
  assert_contains "$body" "pane split w3:p1 --direction down --ratio 0.28" \
    "the default banner did not split the frame as a 28% stacked band"
  assert_contains "$body" "pane swap --source-pane w3:p1 --target-pane $fleet" \
    "the default fleet-first order did not put the banner ahead of the supervisor"
  [ "$(layout_rows)" = "$fleet w3:p1 " ] \
    || fail "the fleet banner did not end up above the supervisor: $(layout_rows)"
  pass "the default banner is a stacked 28% fleet-on-top band announced before it is applied"
}

test_layout_config_sets_direction_order_and_ratio() {
  local out fleet body
  reset_layout_frame
  printf 'side-by-side fleet-last 0.35\n' > "$LAYOUT_HOME/config/cockpit-layout"
  out=$(run_layout_cockpit adopt 2>&1) || fail "configured banner adoption failed"
  body=$(cat "$HERDR_LOG")
  fleet=$(grep '^fleet_pane_id=' "$LAYOUT_HOME/state/.herdr-cockpit" | cut -d= -f2-)
  assert_contains "$body" "pane split w3:p1 --direction right --ratio 0.6500" \
    "a fleet-last side-by-side layout did not leave the supervisor the first 65%"
  assert_not_contains "$body" "pane swap" \
    "a fleet-last order still reordered the panes"
  [ "$(layout_rows)" = "w3:p1 $fleet " ] \
    || fail "the configured banner did not follow the supervisor: $(layout_rows)"
  pass "config/cockpit-layout sets the banner's direction, order, and ratio"
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
  local out rc fleet
  reset_layout_frame
  rmdir "$LAYOUT_HOME/state"
  touch "$LAYOUT_HOME/state" "$HERDR_STATE/fail-close"
  out=$(run_layout_cockpit adopt 2>&1)
  rc=$?
  rm -f "$LAYOUT_HOME/state" "$HERDR_STATE/fail-close"
  mkdir "$LAYOUT_HOME/state"
  [ "$rc" -ne 0 ] || fail "adoption accepted a frame record it could not publish"
  fleet=$(awk -F '\t' '$4 == "w3" && $1 != "w3:p1" {print $1}' "$HERDR_STATE/panes.tsv")
  [ -n "$fleet" ] || fail "the failed record rollback did not leave its pane in the fake screen"
  assert_contains "$out" "could not publish the cockpit frame record" \
    "a record-publication failure did not name its cause"
  assert_contains "$out" "NOT-RESTORED" \
    "a failed record rollback did not report that the screen remained changed"
  assert_contains "$out" "added fleet pane $fleet could not be removed" \
    "a failed record rollback did not name the pane still on screen"
  [ ! -e "$LAYOUT_HOME/state/.herdr-cockpit" ] \
    || fail "failed record publication left a frame record"
  pass "a failed record rollback reports the unrecorded pane still on screen"
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

set_fleet_pane_status() {  # <status>
  local fleet
  fleet=$(grep '^fleet_pane_id=' "$LAYOUT_HOME/state/.herdr-cockpit" | cut -d= -f2-)
  awk -F '\t' -v OFS='\t' -v pane="$fleet" -v status="$1" \
    '$1 == pane {$5=status} {print}' "$HERDR_STATE/panes.tsv" > "$HERDR_STATE/panes.next"
  mv "$HERDR_STATE/panes.next" "$HERDR_STATE/panes.tsv"
  printf '%s' "$fleet"
}

test_a_relative_path_fleet_view_still_counts_as_live() {
  local fleet out
  reset_layout_frame
  run_layout_cockpit adopt >/dev/null 2>&1 || fail "banner adoption failed"
  fleet=$(set_fleet_pane_status fleet-relative)
  out=$(run_layout_cockpit status 2>&1) \
    || fail "a fleet view started through a relative path was rejected: $out"
  assert_contains "$out" "COCKPIT: live session=fmtest" \
    "a relative-path fleet view did not report the frame live"

  FM_FAKE_FLEET_HOME="$LAYOUT_HOME"
  set_fleet_pane_status fleet-env-home >/dev/null
  out=$(run_layout_cockpit status 2>&1) \
    || fail "a fleet view publishing this home was rejected: $out"

  FM_FAKE_FLEET_HOME="$TMP_ROOT/other-home"
  run_layout_cockpit status >/dev/null 2>&1 \
    && fail "a fleet view publishing another home was accepted"
  FM_FAKE_FLEET_HOME=""
  pass "fleet-view identity survives a relative path but not another home"
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

test_fleet_diagnostics_name_the_check_that_failed() {
  local fleet out
  reset_layout_frame
  run_layout_cockpit adopt >/dev/null 2>&1 || fail "banner adoption failed"
  fleet=$(set_fleet_pane_status fleet-gone)
  out=$(run_layout_cockpit panel 2>&1) || fail "panel did not render an unreachable banner"
  assert_contains "$out" "FLEET column=$fleet [no-process-info]" \
    "an unreachable banner pane did not report that cause"

  set_fleet_pane_status fleet-unreadable >/dev/null
  out=$(run_layout_cockpit panel 2>&1) || fail "panel did not render an untrusted response"
  assert_contains "$out" "FLEET column=$fleet [unreadable]" \
    "an untrusted process report did not report that cause"

  set_fleet_pane_status fleet-no-watch >/dev/null
  out=$(run_layout_cockpit panel 2>&1) || fail "panel did not render a non-watching banner"
  assert_contains "$out" "FLEET column=$fleet [no-fleet-process]" \
    "a pane running no fleet view did not report that cause"
  pass "each fleet-banner failure reports its own cause instead of one collapsed verdict"
}

test_banner_zoom_is_reversible_and_moves_no_pane() {
  local fleet before out log
  reset_layout_frame
  run_layout_cockpit adopt >/dev/null 2>&1 || fail "banner adoption failed"
  fleet=$(grep '^fleet_pane_id=' "$LAYOUT_HOME/state/.herdr-cockpit" | cut -d= -f2-)
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
  pass "the banner zooms and unzooms without splitting, moving, or closing a pane"
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
test_layout_config_sets_direction_order_and_ratio
test_invalid_layout_config_refuses_without_changing_the_screen
test_failed_reorder_restores_the_original_screen
test_failed_reorder_reports_when_the_screen_cannot_be_restored
test_failed_record_publication_reports_when_the_screen_cannot_be_restored
test_re_adoption_neither_warns_nor_touches_the_screen
test_a_relative_path_fleet_view_still_counts_as_live
test_an_unresolved_home_path_still_matches_the_live_banner
test_fleet_diagnostics_name_the_check_that_failed
test_banner_zoom_is_reversible_and_moves_no_pane
test_status_names_the_check_that_failed
