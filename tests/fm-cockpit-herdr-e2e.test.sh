#!/usr/bin/env bash
# Real-Herdr executable-path test for cockpit placement and restart adoption.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || fail "jq not found; install jq before running the cockpit Herdr end-to-end test"
command -v treehouse >/dev/null 2>&1 || fail "treehouse not found; install the pinned Treehouse version before running the cockpit Herdr end-to-end test"

LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
SESSION=${HERDR_LAB_SESSION:-$("$LAB_HELPER" name cockpit-e2e)}
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-cockpit-e2e.XXXXXX")
HOME_DIR="$TMP_ROOT/home"
FAKEBIN="$TMP_ROOT/fakebin"
CLEANED=0

cleanup() {
  local id status=0
  [ "$CLEANED" = 0 ] || return 0
  CLEANED=1
  for id in cockpit-one cockpit-two cockpit-three; do
    if [ -f "$HOME_DIR/state/$id.meta" ]; then
      PATH="$FAKEBIN:$PATH" HERDR_SESSION="$SESSION" FM_HOME="$HOME_DIR" \
        FM_COCKPIT_LAB_HELPER="$LAB_HELPER" FM_COCKPIT_LAB_SESSION="$SESSION" \
        FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$HOME_DIR/state" \
        FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
        "$ROOT/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 || true
    fi
  done
  "$LAB_HELPER" teardown "$SESSION" || status=$?
  rm -rf "$TMP_ROOT"
  return "$status"
}
trap cleanup EXIT
"$LAB_HELPER" provision "$SESSION" || fail "could not provision the guarded Herdr lab"

lab() { "$LAB_HELPER" run "$SESSION" "$@"; }

mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$HOME_DIR/projects" "$FAKEBIN"
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
helper=${FM_COCKPIT_LAB_HELPER:?}
session=${FM_COCKPIT_LAB_SESSION:?}
args=()
while [ "$#" -gt 0 ]; do
  if [ "$1" = --session ]; then
    [ "${2:-}" = "$session" ] || exit 1
    shift 2
    continue
  fi
  args+=("$1")
  shift
done
"$helper" run "$session" "${args[@]}"
SH
chmod +x "$FAKEBIN/herdr"

make_scratch_project() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# scratch\n' > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm initial
  git clone --quiet --bare "$dir" "$dir.origin.git"
  git -C "$dir" remote add origin "file://$dir.origin.git"
}

PROJECT="$TMP_ROOT/project"
make_scratch_project "$PROJECT"
for id in cockpit-one cockpit-two; do
  mkdir -p "$HOME_DIR/data/$id"
  printf 'Run the supplied verification command and stop.\nDelivery contract: mode=no-mistakes\n' \
    > "$HOME_DIR/data/$id/brief.md"
done

WORKSPACE_OUT=$(lab workspace create --label firstmate --cwd "$HOME_DIR" --no-focus) \
  || fail "could not create the cockpit workspace"
WORKSPACE=$(printf '%s' "$WORKSPACE_OUT" | jq -r '.result.workspace.workspace_id // empty')
TAB=$(printf '%s' "$WORKSPACE_OUT" | jq -r '.result.tab.tab_id // empty')
HEAD=$(printf '%s' "$WORKSPACE_OUT" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$WORKSPACE" ] && [ -n "$TAB" ] && [ -n "$HEAD" ] \
  || fail "workspace creation returned incomplete ids"
lab pane report-agent "$HEAD" --source fm-cockpit-e2e --agent firstmate --state idle >/dev/null \
  || fail "could not register the cockpit head"
LAB_SOCKET=$(lab session list --json \
  | jq -r --arg session "$SESSION" '.sessions[]? | select(.name == $session) | .socket_path')
[ -n "$LAB_SOCKET" ] || fail "could not resolve the guarded lab socket"

cockpit_env() {
  PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_DIR" \
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_COCKPIT_LAB_HELPER="$LAB_HELPER" \
    FM_COCKPIT_LAB_SESSION="$SESSION" \
    HERDR_ENV=1 \
    HERDR_SESSION="$SESSION" \
    HERDR_SOCKET_PATH="$LAB_SOCKET" \
    HERDR_PANE_ID="$HEAD" \
    "$@"
}

cockpit_env "$ROOT/bin/fm-cockpit.sh" adopt >/dev/null \
  || fail "could not adopt the real Herdr frame"

spawn_real() {  # <task-id> <sentinel>
  local id=$1 sentinel=$2
  cockpit_env env FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$PROJECT" "sh -c 'echo $sentinel'" \
      --mode no-mistakes --yolo off --backend herdr
}

spawn_real cockpit-one cockpit-one-ok >/dev/null \
  || fail "first executable-path cockpit spawn failed"
spawn_real cockpit-two cockpit-two-ok >/dev/null \
  || fail "second executable-path cockpit spawn failed"

FIRST_META="$HOME_DIR/state/cockpit-one.meta"
SECOND_META="$HOME_DIR/state/cockpit-two.meta"
[ -f "$FIRST_META" ] && [ -f "$SECOND_META" ] || fail "cockpit spawns did not publish metadata"
FIRST_PANE=$(grep '^herdr_pane_id=' "$FIRST_META" | cut -d= -f2-)
SECOND_PANE=$(grep '^herdr_pane_id=' "$SECOND_META" | cut -d= -f2-)
[ "$FIRST_PANE" != "$HEAD" ] && [ "$SECOND_PANE" != "$HEAD" ] \
  && [ "$FIRST_PANE" != "$SECOND_PANE" ] || fail "cockpit spawns returned duplicate panes"

# The viewport slot is single-occupancy and a background spawn never claims it
# from a worker already there: the first spawn fills the empty slot, and later
# spawns open on their own labelled peer tabs.
viewport_workers() {  # -> pane ids sharing the cockpit tab, minus head and fleet
  lab pane list --workspace "$WORKSPACE" | jq -r \
    --arg tab "$TAB" --arg head "$HEAD" '
      .result.panes[]
      | select(.tab_id == $tab and .pane_id != $head)
      | select((.label // "") | startswith("fm-"))
      | .pane_id'
}
pane_tab() {  # <pane> -> its current tab id
  lab pane get "$1" | jq -r '.result.pane.tab_id // empty'
}
pane_label() {  # <pane> -> its own label, not its tab's
  lab pane get "$1" | jq -r '.result.pane.label // ""'
}

[ "$(viewport_workers | tr '\n' ' ' | tr -s ' ' | sed 's/ $//')" = "$FIRST_PANE" ] \
  || fail "the viewport slot did not keep the worker that filled it"
[ "$(pane_tab "$SECOND_PANE")" != "$TAB" ] \
  || fail "a later spawn claimed the viewport instead of its own tab"
lab tab list --workspace "$WORKSPACE" | jq -e --arg want fm-cockpit-two \
  '[.result.tabs[] | select(.label == $want)] | length == 1' >/dev/null \
  || fail "the later spawn did not land on its own labelled tab"
[ "$(pane_label "$SECOND_PANE")" = fm-cockpit-two ] \
  || fail "the peer-tab worker's own pane carries no task label: [$(pane_label "$SECOND_PANE")]"
pass "real Herdr fm-spawn keeps the viewport occupant and gives later spawns their own labelled tab and pane"

# Acceptance: placing an off-cockpit agent puts that pane in the viewport, and
# the worker it displaces stays reachable on a tab of its own.
PARKED_TAB=$(pane_tab "$SECOND_PANE")
[ -n "$PARKED_TAB" ] && [ "$PARKED_TAB" != "$TAB" ] \
  || fail "the peer worker has no tab of its own to be selected from"
# The public show command hands the same pane to the same single-occupancy
# placement function used by focus-listen, without making this required lane
# depend on a detached listener or live focus-event delivery.
cockpit_env "$ROOT/bin/fm-cockpit.sh" show cockpit-two >/dev/null \
  || fail "could not place the peer worker in the viewport slot"

[ "$(viewport_workers | tr '\n' ' ' | tr -s ' ' | sed 's/ $//')" = "$SECOND_PANE" ] \
  || fail "placing an off-cockpit worker did not move it into the viewport slot"
[ "$(pane_tab "$FIRST_PANE")" != "$TAB" ] \
  || fail "the previous viewport occupant was not parked out"
[ -n "$(pane_tab "$FIRST_PANE")" ] \
  || fail "the previous viewport occupant became unreachable"
pass "real Herdr placement swaps the viewport occupant and keeps the displaced worker reachable"

# Acceptance: the slot still holds exactly one agent, at its stable width,
# after a third worker is placed.
mkdir -p "$HOME_DIR/data/cockpit-three"
printf 'Run the supplied verification command and stop.\nDelivery contract: mode=no-mistakes\n' \
  > "$HOME_DIR/data/cockpit-three/brief.md"
spawn_real cockpit-three cockpit-three-ok >/dev/null \
  || fail "third executable-path cockpit spawn failed"
[ "$(viewport_workers | wc -l | tr -d ' ')" = 1 ] \
  || fail "three placed workers left more than one agent in the viewport slot"
[ "$(viewport_workers | tr -d '\n')" = "$SECOND_PANE" ] \
  || fail "a background spawn replaced the worker the operator was reading"
[ "$(pane_tab "$THIRD_PANE")" != "$TAB" ] \
  || fail "the third spawn claimed the viewport instead of its own tab"
# The cockpit tab carries the default three-pane fleet region plus exactly one
# head-versus-viewport split at the fixed ratio. Four splits and five panes mean
# the slot was rebuilt the way it always is and never subdivided a second time
# to make room for another worker.
lab pane layout --pane "$HEAD" | jq -e '
    (.result.layout.panes | length) == 5
    and (.result.layout.splits | length) == 4
    and ([.result.layout.splits[]
          | select(((.ratio - 0.67) | fabs) < 0.001)] | length) == 1
  ' >/dev/null || fail "the viewport slot lost its single stable-width split"
pass "real Herdr viewport holds exactly one agent at a stable width with three placed"

PANEL_OUT=$(cockpit_env "$ROOT/bin/fm-cockpit.sh" panel) \
  || fail "real Herdr cockpit panel did not render"
assert_contains "$PANEL_OUT" "NAVIGATOR Herdr sidebar (all spaces and agents)" \
  "real cockpit panel omitted the all-space navigator"
assert_contains "$PANEL_OUT" "PINNED firstmate head=$HEAD [live]" \
  "real cockpit panel omitted the pinned controller"
assert_contains "$PANEL_OUT" "fm-cockpit-two" \
  "real cockpit panel omitted the current viewport worker"
assert_contains "$PANEL_OUT" "fm-cockpit-three" \
  "real cockpit panel omitted a worker parked on its own tab"
assert_contains "$PANEL_OUT" "BOUNDARY display=all-homes steer=current-home backend=herdr" \
  "real cockpit panel lost the display and steer boundary"
assert_contains "$PANEL_OUT" "FLEET STATUS" \
  "real cockpit panel omitted the read-only fleet view"
pass "real Herdr cockpit panel renders the navigator, pinned head, and viewport"

COUNT_BEFORE=$(lab pane list --workspace "$WORKSPACE" | jq '.result.panes | length')
RECORD_BEFORE=$(sha256sum "$HOME_DIR/state/.herdr-cockpit" | awk '{print $1}')
RESTART_OUT=$(cockpit_env "$ROOT/bin/fm-cockpit.sh" adopt) \
  || fail "real cockpit restart re-adoption failed"
PANES_AFTER=$(lab pane list --workspace "$WORKSPACE") || fail "could not inspect the re-adopted frame"
COUNT_AFTER=$(printf '%s' "$PANES_AFTER" | jq '.result.panes | length')
RECORD_AFTER=$(sha256sum "$HOME_DIR/state/.herdr-cockpit" | awk '{print $1}')
[ "$COUNT_BEFORE" = "$COUNT_AFTER" ] || fail "restart re-adoption changed the pane count"
[ "$RECORD_BEFORE" = "$RECORD_AFTER" ] || fail "restart re-adoption rewrote the frame record"
assert_contains "$RESTART_OUT" "re-adopted Herdr frame" "restart did not report re-adoption"
pass "real Herdr restart re-adopts the recorded frame without rebuilding it"

# Acceptance: a fleet painter started into a pane that already exists resolves
# its drawn rectangle exactly as the one the region build created, and a painter
# started into that same pane WITHOUT its identity is never reported live.
#
# The region build splits a pane and runs the painter into it in one motion, so
# every painter this adapter had ever started came from a brand-new pane. A
# painter relaunched into an existing recorded pane is the path an operator and
# every recovery take, and it is the one that was never exercised end to end.
# It has to reach the same result, and when it cannot it has to be visible as
# not-live rather than passing every argv check while painting a degraded panel.
FLEET_FIRST=$(grep '^fleet_pane_ids=' "$HOME_DIR/state/.herdr-cockpit" | cut -d= -f2- | cut -d, -f1)
FLEET_SECTION=$(grep '^fleet_pane_sections=' "$HOME_DIR/state/.herdr-cockpit" | cut -d= -f2- | cut -d'|' -f1)
[ -n "$FLEET_FIRST" ] && [ -n "$FLEET_SECTION" ] \
  || fail "the adopted frame recorded no fleet pane to relaunch into"

# The painter's own foreground process, reported by the server rather than
# matched against this host's whole process table, so nothing outside this lab
# session can be selected.
fleet_painter_pids() {  # <pane> -> pids of fleet-view processes the server reports
  local pid cmd
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null) || continue
    case "$cmd" in *fm-fleet-view.sh*) ;; *) continue ;; esac
    grep -qa "FM_HOME=$HOME_DIR" "/proc/$pid/environ" 2>/dev/null || continue
    printf '%s\n' "$pid"
  done < <(lab pane process-info --pane "$1" \
    | jq -r '.result.process_info.foreground_processes[]?.pid // empty')
}

stop_fleet_painter() {  # <pane>
  local pid waited=0
  while IFS= read -r pid; do
    kill "$pid" 2>/dev/null || true
  done < <(fleet_painter_pids "$1")
  while [ -n "$(fleet_painter_pids "$1")" ] && [ "$waited" -lt 100 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -z "$(fleet_painter_pids "$1")" ] || fail "the painter in $1 would not stop"
}

wait_for_fleet_state() {  # <expected> -> 0 once status settles, 1 on timeout
  local want=$1 waited=0
  while [ "$waited" -lt 150 ]; do
    if [ "$want" = live ]; then
      cockpit_env "$ROOT/bin/fm-cockpit.sh" status >/dev/null 2>&1 && return 0
    else
      cockpit_env "$ROOT/bin/fm-cockpit.sh" status 2>&1 >/dev/null | grep -q "$want" && return 0
    fi
    sleep 0.2
    waited=$((waited + 1))
  done
  return 1
}

relaunch_painter() {  # <pane> <section> [<identity arguments...>]
  local pane=$1 section=$2
  shift 2
  lab pane run "$pane" \
    env "FM_HOME=$HOME_DIR" "FM_HERDR_LAB_HELPER=$LAB_HELPER" "FM_HERDR_LAB_SESSION=$SESSION" \
    "$ROOT/bin/fm-fleet-view.sh" \
    --geometry-command "$ROOT/bin/fm-herdr-pane-geometry.sh" \
    "$@" --watch --section "$section" >/dev/null \
    || fail "could not relaunch a painter into the existing pane $pane"
}

stop_fleet_painter "$FLEET_FIRST"
wait_for_fleet_state fleet-no-fleet-process \
  || fail "status kept reporting a live region after its painter stopped"

# Unidentified relaunch: the exact executable, the exact home, the recorded
# section, and --geometry-command - everything the old liveness check looked at.
relaunch_painter "$FLEET_FIRST" "$FLEET_SECTION"
wait_for_fleet_state fleet-no-pane-identity \
  || fail "a painter relaunched with no pane identity was reported live: $(cockpit_env "$ROOT/bin/fm-cockpit.sh" status 2>&1)"
pass "a painter relaunched into an existing pane without its identity is never reported live"

# Identified relaunch: the shape the adapter itself uses.
stop_fleet_painter "$FLEET_FIRST"
relaunch_painter "$FLEET_FIRST" "$FLEET_SECTION" --herdr-session "$SESSION" --herdr-pane "$FLEET_FIRST"
wait_for_fleet_state live \
  || fail "a painter relaunched with its own identity never became live: $(cockpit_env "$ROOT/bin/fm-cockpit.sh" status 2>&1)"

RELAUNCH_DRAWN=$(FM_HERDR_LAB_HELPER="$LAB_HELPER" FM_HERDR_LAB_SESSION="$SESSION" \
  "$ROOT/bin/fm-herdr-pane-geometry.sh" --session "$SESSION" --pane "$FLEET_FIRST") \
  || fail "the relaunched pane's authoritative rectangle could not be read"
case "$RELAUNCH_DRAWN" in
  [1-9]*' '[1-9]*) ;;
  *) fail "the relaunched pane reported an unusable rectangle: $RELAUNCH_DRAWN" ;;
esac

# Liveness is satisfied as soon as the process exists, which can be before its
# first repaint, so the screen is read until the previous generation's degraded
# frame is gone rather than once at an arbitrary moment.
RELAUNCH_TEXT=
RELAUNCH_WAITED=0
while [ "$RELAUNCH_WAITED" -lt 150 ]; do
  RELAUNCH_TEXT=$(lab pane read "$FLEET_FIRST" --source visible) \
    || fail "could not read the relaunched pane"
  case "$RELAUNCH_TEXT" in
    *"FLEET VIEW DEGRADED"*) ;;
    *) break ;;
  esac
  sleep 0.2
  RELAUNCH_WAITED=$((RELAUNCH_WAITED + 1))
done
case "$RELAUNCH_TEXT" in
  *"FLEET VIEW DEGRADED"*) fail "the relaunched painter degraded instead of drawing: $RELAUNCH_TEXT" ;;
esac
pass "a painter relaunched into an existing recorded pane draws from the same authoritative rectangle"

for id in cockpit-one cockpit-two cockpit-three; do
  cockpit_env env FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" "$ROOT/bin/fm-teardown.sh" "$id" >/dev/null \
    || fail "could not tear down $id"
done

if ! cleanup; then
  trap - EXIT
  fail "guarded Herdr lab teardown failed or changed the default fleet"
fi
trap - EXIT
pass "real Herdr cockpit lab leaves the default fleet byte-identical"
