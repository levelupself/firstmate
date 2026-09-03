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
  for id in cockpit-one cockpit-two cockpit-three readyflip; do
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
fm_test_backlog_queue "$HOME_DIR" cockpit-one cockpit-two

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
fm_test_backlog_add_queue "$HOME_DIR" cockpit-three
spawn_real cockpit-three cockpit-three-ok >/dev/null \
  || fail "third executable-path cockpit spawn failed"
THIRD_META="$HOME_DIR/state/cockpit-three.meta"
[ -f "$THIRD_META" ] || fail "third cockpit spawn did not publish metadata"
THIRD_PANE=$(grep '^herdr_pane_id=' "$THIRD_META" | cut -d= -f2-)
[ -n "$THIRD_PANE" ] || fail "third cockpit spawn published no pane identity"
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

# Acceptance: the fleet region drops queued work the moment a worker takes it,
# from a real dispatch rather than a rewritten backlog document.
#
# Dispatch publishes state/<id>.meta and nothing else; the backlog row is moved
# to In flight later, by hand. Between the two the captain was being offered
# work that already had a worker on it, on a pane he is meant to act from
# without cross-checking. The panel has to reconcile that itself, on its own
# redraw, with no focus change and no manual refresh.
fleet_pane_for_section() {  # <section> -> the recorded pane painting it
  local want=$1 ids sections index=0 spec
  ids=$(grep '^fleet_pane_ids=' "$HOME_DIR/state/.herdr-cockpit" | cut -d= -f2-)
  sections=$(grep '^fleet_pane_sections=' "$HOME_DIR/state/.herdr-cockpit" | cut -d= -f2-)
  while IFS= read -r spec; do
    index=$((index + 1))
    [ "$spec" = "$want" ] || continue
    printf '%s' "$ids" | cut -d, -f"$index"
    return 0
  done <<EOF
$(printf '%s' "$sections" | tr '|' '\n')
EOF
  return 1
}

wait_for_pane_text() {  # <pane> <needle> <present|absent> -> 0 once it settles
  local pane=$1 needle=$2 want=$3 waited=0 text
  while [ "$waited" -lt 400 ]; do
    text=$(lab pane read "$pane" --source visible 2>/dev/null || printf '')
    case "$text" in
      *"$needle"*) [ "$want" != present ] || return 0 ;;
      *) [ "$want" != absent ] || return 0 ;;
    esac
    sleep 0.25
    waited=$((waited + 1))
  done
  return 1
}

READY_PANE=$(fleet_pane_for_section ready) \
  || fail "the adopted frame records no pane painting the ready section"
cat > "$HOME_DIR/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] readyflip - Queued work a worker is about to take (repo: alpha) (kind: ship)
  Implement the thing, with acceptance criteria.
EOF
wait_for_pane_text "$READY_PANE" readyflip present \
  || fail "the ready pane never showed the queued work: $(lab pane read "$READY_PANE" --source visible 2>/dev/null)"
mkdir -p "$HOME_DIR/data/readyflip"
printf 'Run the supplied verification command and stop.\nDelivery contract: mode=no-mistakes\n' \
  > "$HOME_DIR/data/readyflip/brief.md"
spawn_real readyflip readyflip-ok >/dev/null \
  || fail "could not dispatch the queued work for real"
[ -f "$HOME_DIR/state/readyflip.meta" ] \
  || fail "the real dispatch published no worker record"
wait_for_pane_text "$READY_PANE" readyflip absent \
  || fail "the ready pane kept offering work a worker already held: $(lab pane read "$READY_PANE" --source visible 2>/dev/null)"
READYFLIP_STATE=$(cd "$HOME_DIR" && tasks-axi show readyflip --full \
  | sed -n 's/^  state: //p' | head -1)
[ "$READYFLIP_STATE" = in_flight ] \
  || fail "the real dispatch did not record readyflip in flight: [$READYFLIP_STATE]"
pass "a real dispatch records its in-flight transition and clears the ready pane on its own redraw"

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
FLEET_IDS=$(grep '^fleet_pane_ids=' "$HOME_DIR/state/.herdr-cockpit" | cut -d= -f2-)
FLEET_SECTIONS=$(grep '^fleet_pane_sections=' "$HOME_DIR/state/.herdr-cockpit" | cut -d= -f2-)
FLEET_FIRST=$(printf '%s' "$FLEET_IDS" | cut -d, -f1)
FLEET_SECTION=$(printf '%s' "$FLEET_SECTIONS" | cut -d'|' -f1)
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
  if [ -n "$(fleet_painter_pids "$1")" ]; then
    while IFS= read -r pid; do
      kill -KILL "$pid" 2>/dev/null || true
    done < <(fleet_painter_pids "$1")
    sleep 0.2
  fi
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

relaunch_painter() {  # <pane> <section> <root> <environment-mode> [<interval>]
  local pane=$1 section=$2 root=$3 environment_mode=$4 interval=${5:-2}
  local -a identity_environment=()
  local -a stated_identity=()
  [ "$environment_mode" != stripped ] \
    || identity_environment=(-u HERDR_SESSION -u HERDR_PANE_ID)
  # The identity the adapter states on the command line, which is the only
  # channel that does not depend on what Herdr chose to publish into the pane.
  [ "$environment_mode" != identified ] \
    || stated_identity=(--herdr-session "$SESSION" --herdr-pane "$pane")
  lab pane run "$pane" \
    env "${identity_environment[@]}" \
    "FM_HOME=$HOME_DIR" "FM_HERDR_LAB_HELPER=$LAB_HELPER" "FM_HERDR_LAB_SESSION=$SESSION" \
    "$root/bin/fm-fleet-view.sh" \
    --geometry-command "$root/bin/fm-herdr-pane-geometry.sh" \
    "${stated_identity[@]}" \
    --watch "$interval" --section "$section" >/dev/null \
    || fail "could not relaunch a painter into the existing pane $pane"
}

wait_for_fleet_painter() {  # <pane> -> 0 once the server reports one
  local pane=$1 waited=0
  while [ "$waited" -lt 200 ]; do
    [ -z "$(fleet_painter_pids "$pane")" ] || return 0
    sleep 0.1
    waited=$((waited + 1))
  done
  return 1
}

stop_fleet_painter "$FLEET_FIRST"
wait_for_fleet_state fleet-no-fleet-process \
  || fail "status kept reporting a live region after its painter stopped"

relaunch_painter "$FLEET_FIRST" "$FLEET_SECTION" "$ROOT" ambient
wait_for_fleet_state fleet-no-pane-identity \
  || fail "an ambient-only painter did not report fleet-no-pane-identity: $(cockpit_env "$ROOT/bin/fm-cockpit.sh" status 2>&1)"
pass "an ambient-only relaunch stays running but is refused by exact identity validation"

stop_fleet_painter "$FLEET_FIRST"
PRE_FIX_ROOT="$TMP_ROOT/pre-fix"
PRE_FIX_AVAILABLE=1
mkdir -p "$PRE_FIX_ROOT"
cp -R "$ROOT/bin" "$PRE_FIX_ROOT/bin"
for implementation in bin/fm-fleet-view.sh bin/fm-herdr-pane-geometry.sh bin/backends/herdr.sh; do
  if ! git show "d00d218c95eb6b6af8855089343ddf929713fca8:$implementation" \
    > "$PRE_FIX_ROOT/$implementation"; then
    PRE_FIX_AVAILABLE=0
    break
  fi
done

if [ "$PRE_FIX_AVAILABLE" = 1 ]; then
  chmod +x "$PRE_FIX_ROOT/bin/fm-fleet-view.sh" "$PRE_FIX_ROOT/bin/fm-herdr-pane-geometry.sh"
  PRE_FIX_RECORD="$TMP_ROOT/pre-fix-cockpit-record"
  cp "$HOME_DIR/state/.herdr-cockpit" "$PRE_FIX_RECORD"
  awk -v pane="$FLEET_FIRST" -v section="$FLEET_SECTION" '
    /^fleet_pane_ids=/ { print "fleet_pane_ids=" pane; next }
    /^fleet_pane_sections=/ { print "fleet_pane_sections=" section; next }
    { print }
  ' "$PRE_FIX_RECORD" > "$HOME_DIR/state/.herdr-cockpit.tmp"
  mv "$HOME_DIR/state/.herdr-cockpit.tmp" "$HOME_DIR/state/.herdr-cockpit"
  chmod 0600 "$HOME_DIR/state/.herdr-cockpit"
  relaunch_painter "$FLEET_FIRST" "$FLEET_SECTION" "$PRE_FIX_ROOT" stripped 20
  PRE_FIX_TEXT=
  PRE_FIX_STATUS=
  PRE_FIX_MATCHED=0
  PRE_FIX_WAITED=0
  while [ "$PRE_FIX_WAITED" -lt 100 ]; do
    PRE_FIX_TEXT=$(lab pane read "$FLEET_FIRST" --source visible) \
      || fail "could not read the pre-fix stripped-identity relaunch"
    PRE_FIX_STATUS=$(cockpit_env env FM_ROOT_OVERRIDE="$PRE_FIX_ROOT" \
      "$PRE_FIX_ROOT/bin/fm-cockpit.sh" status 2>&1) || true
    if [[ $PRE_FIX_TEXT == *"FLEET VIEW DEGRADED"* ]] \
      && [[ $PRE_FIX_STATUS == COCKPIT:\ live* ]]; then
      PRE_FIX_MATCHED=1
      break
    fi
    sleep 0.1
    PRE_FIX_WAITED=$((PRE_FIX_WAITED + 1))
  done
  stop_fleet_painter "$FLEET_FIRST"
  mv "$PRE_FIX_RECORD" "$HOME_DIR/state/.herdr-cockpit"
  [ "$PRE_FIX_MATCHED" = 1 ] \
    || fail "pre-fix stripped identity did not show a degraded pane while status reported live: pane=[$PRE_FIX_TEXT] status=[$PRE_FIX_STATUS]"
  pass "pre-fix stripped identity degrades while cockpit status reports live"
else
  echo "skip: pre-fix relaunch blobs unavailable at d00d218c95eb6b6af8855089343ddf929713fca8"
fi

STRIPPED_PROBE_STATUS=0
env -u HERDR_SESSION -u HERDR_PANE_ID \
  FM_HERDR_LAB_HELPER="$LAB_HELPER" FM_HERDR_LAB_SESSION="$SESSION" \
  "$ROOT/bin/fm-herdr-pane-geometry.sh" >/dev/null 2>&1 \
  || STRIPPED_PROBE_STATUS=$?
[ "$STRIPPED_PROBE_STATUS" -eq 64 ] \
  || fail "the current production probe did not classify stripped identity as permanent: $STRIPPED_PROBE_STATUS"

lab pane run "$FLEET_FIRST" clear >/dev/null \
  || fail "could not clear the fleet pane before the current stripped-identity relaunch"
POST_FIX_CAPTURE="$HOME_DIR/state/post-fix-stripped-painter.log"
POST_FIX_RUNNER="$HOME_DIR/state/post-fix-stripped-painter.sh"
cat > "$POST_FIX_RUNNER" <<SH
#!/usr/bin/env bash
"$ROOT/bin/fm-fleet-view.sh" --geometry-command "$ROOT/bin/fm-herdr-pane-geometry.sh" \
  --watch 1 --section "$FLEET_SECTION" > "$POST_FIX_CAPTURE" 2>&1
status=\$?
printf '\nrc=%s\n' "\$status" >> "$POST_FIX_CAPTURE"
SH
chmod +x "$POST_FIX_RUNNER"
lab pane run "$FLEET_FIRST" \
  "env -u HERDR_SESSION -u HERDR_PANE_ID FM_HOME=$HOME_DIR FM_HERDR_LAB_HELPER=$LAB_HELPER FM_HERDR_LAB_SESSION=$SESSION $POST_FIX_RUNNER" \
  >/dev/null \
  || fail "could not launch the current stripped-identity painter capture"
POST_FIX_WAITED=0
while [ "$POST_FIX_WAITED" -lt 300 ]; do
  if cockpit_env "$ROOT/bin/fm-cockpit.sh" status >/dev/null 2>&1; then
    fail "current stripped-identity relaunch was reported live"
  fi
  if [ -f "$POST_FIX_CAPTURE" ] && grep -q '^rc=' "$POST_FIX_CAPTURE"; then
    break
  fi
  sleep 0.1
  POST_FIX_WAITED=$((POST_FIX_WAITED + 1))
done
if [ ! -f "$POST_FIX_CAPTURE" ] || ! grep -q '^rc=' "$POST_FIX_CAPTURE"; then
  fail "current stripped-identity relaunch never recorded its exit status: $(lab pane read "$FLEET_FIRST" --source visible 2>/dev/null)"
fi
POST_FIX_TEXT=$(cat "$POST_FIX_CAPTURE")
POST_FIX_RC=$(sed -n 's/^rc=//p' "$POST_FIX_CAPTURE" | tail -n 1)
case "$POST_FIX_RC" in
  ''|0|*[!0-9]*) fail "current stripped-identity painter did not terminate unsuccessfully: rc=[$POST_FIX_RC] output=[$POST_FIX_TEXT]" ;;
esac
case "$POST_FIX_TEXT" in
  *"FLEET VIEW STOPPING"*"no Herdr pane identity available"*) ;;
  *) fail "current stripped-identity painter did not report unusable pane identity: $POST_FIX_TEXT" ;;
esac
case "$POST_FIX_TEXT" in
  *"cwd is gone"*|*"cwd is permanently unavailable"*)
    fail "current stripped-identity painter blamed a cwd it never read: $POST_FIX_TEXT" ;;
esac
case "$POST_FIX_TEXT" in
  *"FLEET STATUS"*|*"YOUR DECISIONS"*) fail "current stripped-identity relaunch painted a fleet section: $POST_FIX_TEXT" ;;
esac
pass "current stripped identity is permanent and never reports a live fleet frame"

# Acceptance: the captain's observed cockpit split, end to end on real Herdr -
# two fleet panes stopped while the third rendered normally beside them. Herdr
# publishes HERDR_PANE_ID into a pane but never HERDR_SESSION, so a banner
# relaunched without the adapter's stated identity holds half a pane identity
# and can never resolve a rectangle, whatever the pane itself is doing. Its
# sibling, still carrying the identity the adapter gave it, is untouched.
# The two that stop must name the identity, because "geometry unavailable" is
# what left three healthy panes looking like a broken cockpit.
SPLIT_RENDERING=$(fleet_pane_for_section ready) \
  || fail "the adopted frame records no pane painting the ready section"
SPLIT_ONE=$(printf '%s' "$FLEET_IDS" | cut -d, -f1)
SPLIT_THREE=$(printf '%s' "$FLEET_IDS" | cut -d, -f3)
SPLIT_ONE_SECTION=$(printf '%s' "$FLEET_SECTIONS" | cut -d'|' -f1)
SPLIT_THREE_SECTION=$(printf '%s' "$FLEET_SECTIONS" | cut -d'|' -f3)
[ -n "$SPLIT_THREE" ] && [ "$SPLIT_THREE" != "$SPLIT_ONE" ] \
  && [ "$SPLIT_RENDERING" != "$SPLIT_ONE" ] && [ "$SPLIT_RENDERING" != "$SPLIT_THREE" ] \
  || fail "the adopted frame did not record three distinct fleet panes: [$FLEET_IDS]"

stripped_capture() {  # <pane> <section> <capture-file> <tag>
  local pane=$1 section=$2 capture=$3 tag=$4 runner
  runner="$HOME_DIR/state/stripped-$tag.sh"
  rm -f "$capture"
  cat > "$runner" <<SH
#!/usr/bin/env bash
"$ROOT/bin/fm-fleet-view.sh" --geometry-command "$ROOT/bin/fm-herdr-pane-geometry.sh" \
  --watch 1 --section "$section" > "$capture" 2>&1
status=\$?
printf '\nrc=%s\n' "\$status" >> "$capture"
SH
  chmod +x "$runner"
  lab pane run "$pane" clear >/dev/null \
    || fail "could not clear $pane before its stripped-identity relaunch"
  lab pane run "$pane" \
    "env -u HERDR_SESSION -u HERDR_PANE_ID FM_HOME=$HOME_DIR FM_HERDR_LAB_HELPER=$LAB_HELPER FM_HERDR_LAB_SESSION=$SESSION $runner" \
    >/dev/null || fail "could not launch the stripped-identity painter in $pane"
}

wait_for_capture() {  # <capture-file>
  local capture=$1 waited=0
  while [ "$waited" -lt 400 ]; do
    if [ -f "$capture" ] && grep -q '^rc=' "$capture"; then
      return 0
    fi
    sleep 0.25
    waited=$((waited + 1))
  done
  return 1
}

SPLIT_RENDERING_SECTION=$(printf '%s' "$FLEET_SECTIONS" | cut -d'|' -f2)
stop_fleet_painter "$SPLIT_RENDERING"
stop_fleet_painter "$SPLIT_THREE"
relaunch_painter "$SPLIT_RENDERING" "$SPLIT_RENDERING_SECTION" "$ROOT" identified 1
wait_for_fleet_painter "$SPLIT_RENDERING" \
  || fail "the identity-bearing relaunch never started in $SPLIT_RENDERING"
SPLIT_ONE_CAPTURE="$HOME_DIR/state/split-one.log"
SPLIT_THREE_CAPTURE="$HOME_DIR/state/split-three.log"
stripped_capture "$SPLIT_ONE" "$SPLIT_ONE_SECTION" "$SPLIT_ONE_CAPTURE" one
stripped_capture "$SPLIT_THREE" "$SPLIT_THREE_SECTION" "$SPLIT_THREE_CAPTURE" three

for capture in "$SPLIT_ONE_CAPTURE" "$SPLIT_THREE_CAPTURE"; do
  wait_for_capture "$capture" \
    || fail "a half-identified fleet banner never terminated: $(cat "$capture" 2>/dev/null)"
  SPLIT_TEXT=$(cat "$capture")
  SPLIT_RC=$(sed -n 's/^rc=//p' "$capture" | tail -n 1)
  case "$SPLIT_RC" in
    ''|0|*[!0-9]*) fail "a half-identified fleet banner did not stop unsuccessfully: rc=[$SPLIT_RC] $SPLIT_TEXT" ;;
  esac
  case "$SPLIT_TEXT" in
    *"no Herdr pane identity available"*) ;;
    *) fail "a half-identified fleet banner did not name the missing identity: $SPLIT_TEXT" ;;
  esac
  case "$SPLIT_TEXT" in
    *"cwd is gone"*|*"cwd is permanently unavailable"*)
      fail "a half-identified fleet banner blamed a cwd it never read: $SPLIT_TEXT" ;;
  esac
  case "$SPLIT_TEXT" in
    *"FLEET STATUS"*|*"READY"*|*"YOUR DECISIONS"*)
      fail "a half-identified fleet banner painted a section it could not size: $SPLIT_TEXT" ;;
  esac
done

wait_for_pane_text "$SPLIT_RENDERING" READY present \
  || fail "the fleet pane that kept its identity stopped with its peers: $(lab pane read "$SPLIT_RENDERING" --source visible 2>/dev/null)"
[ -n "$(fleet_painter_pids "$SPLIT_RENDERING")" ] \
  || fail "the fleet pane that kept its identity lost its painter"
SPLIT_RENDERING_TEXT=$(lab pane read "$SPLIT_RENDERING" --source visible)
case "$SPLIT_RENDERING_TEXT" in
  *"no Herdr pane identity available"*|*"FLEET VIEW"*)
    fail "the fleet pane that kept its identity did not render its section: $SPLIT_RENDERING_TEXT" ;;
esac
stop_fleet_painter "$SPLIT_RENDERING"
pass "on real Herdr a half-supplied identity stops exactly its own two panes and names why"


for id in cockpit-one cockpit-two cockpit-three readyflip; do
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
