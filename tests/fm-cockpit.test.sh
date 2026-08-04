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

case "${1:-} ${2:-}" in
  "status --json")
    printf '%s\n' '{"client":{"protocol":16,"version":"0.7.3"},"server":{"running":true}}'
    ;;
  "workspace list")
    printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"},{"workspace_id":"w2","label":"2ndmate-domain"}]}}'
    ;;
  "session list")
    printf '%s\n' '{"sessions":[{"name":"fmtest","running":true,"socket_path":"/tmp/fm-cockpit-test.sock"}]}'
    ;;
  "tab list")
    printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"cockpit"}]}}'
    ;;
  "tab get")
    printf '%s\n' '{"result":{"tab":{"tab_id":"w1:t1","workspace_id":"w1","label":"cockpit"}}}'
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
      IFS=$'\t' read -r id label tab workspace agent <<EOF
$row
EOF
      jq -n --arg id "$id" --arg label "$label" --arg tab "$tab" --arg workspace "$workspace" \
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
    IFS=$'\t' read -r source_id source_label tab workspace source_agent <<EOF
$row
EOF
    counter=$(cat "$state/counter")
    counter=$((counter + 1))
    printf '%s\n' "$counter" > "$state/counter"
    id="w1:p$counter"
    printf '%s\t\t%s\t%s\tno-agent\n' "$id" "$tab" "$workspace" >> "$state/panes.tsv"
    jq -n --arg id "$id" --arg tab "$tab" --arg workspace "$workspace" \
      '{result:{pane:{pane_id:$id,tab_id:$tab,workspace_id:$workspace}}}'
    ;;
  "pane run")
    printf '%s\n' '{"result":{"type":"command_started"}}'
    ;;
  "pane rename")
    id=$3
    label=$4
    awk -F '\t' -v OFS='\t' -v id="$id" -v label="$label" '$1 == id {$2=label} {print}' \
      "$state/panes.tsv" > "$state/panes.next"
    mv "$state/panes.next" "$state/panes.tsv"
    row=$(pane_row "$id")
    IFS=$'\t' read -r pane_id pane_label tab workspace agent <<EOF
$row
EOF
    jq -n --arg id "$pane_id" --arg label "$pane_label" --arg tab "$tab" --arg workspace "$workspace" \
      '{result:{pane:{pane_id:$id,label:$label,tab_id:$tab,workspace_id:$workspace}}}'
    ;;
  "pane close")
    id=$3
    awk -F '\t' -v id="$id" '$1 != id {print}' "$state/panes.tsv" > "$state/panes.next"
    mv "$state/panes.next" "$state/panes.tsv"
    printf '%s\n' '{"result":{"type":"pane_closed"}}'
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

run_cockpit_at() {  # <pane> <socket> <action>
  PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_DIR" \
    FM_FAKE_HERDR_STATE="$HERDR_STATE" \
    FM_FAKE_HERDR_LOG="$HERDR_LOG" \
    HERDR_ENV=1 \
    HERDR_SESSION=fmtest \
    HERDR_SOCKET_PATH="$2" \
    HERDR_PANE_ID="$1" \
    "$COCKPIT" "$3"
}

run_cockpit() {
  run_cockpit_at w1:p1 /tmp/fm-cockpit-test.sock "$1"
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
  pass "cockpit restart re-adopts the durable frame without rebuilding it"
}

test_space_switch_focuses_one_complete_frame_and_rejects_nesting() {
  local out rc
  printf 'w2:p1\tsecondmate-head\tw2:t1\tw2\tlive\n' >> "$HERDR_STATE/panes.tsv"
  printf 'w2:p2\tfirstmate-fleet\tw2:t1\tw2\tno-agent\n' >> "$HERDR_STATE/panes.tsv"
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
    HERDR_SESSION=fmtest \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_cockpit_create_task "$1/state" "$1" "$2" /tmp' \
      "$ROOT" "$HOME_DIR" "$1"
}

test_workers_land_in_persistent_viewport() {
  local first second log live
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
  [ "$second" = "w1:t1 w1:p4" ] || fail "second cockpit task returned unexpected ids: $second"
  log=$(cat "$HERDR_LOG")
  assert_contains "$log" "pane split w1:p3 --direction down --ratio 0.5" \
    "later child did not stay within the persistent viewport"
  assert_not_contains "$log" "tab create" "later child minted a peer tab"
  assert_grep 'viewport_pane_id=w1:p4' "$HOME_DIR/state/.herdr-cockpit" \
    "latest child did not advance the viewport anchor"

  live=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" \
    FM_FAKE_HERDR_STATE="$HERDR_STATE" FM_FAKE_HERDR_LOG="$HERDR_LOG" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_list_live fmtest' "$ROOT")
  assert_contains "$live" $'fmtest:w1:p3\tfm-one' "recovery inventory missed the first split-pane task"
  assert_contains "$live" $'fmtest:w1:p4\tfm-two' "recovery inventory missed the second split-pane task"
  pass "new Herdr workers land in the persistent viewport and remain recoverable"
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
  local out log
  awk -F '\t' -v OFS='\t' '
    $1 == "w1:p3" {$2="fm-claude-pane"; $5="working"}
    $1 == "w1:p4" {$2="fm-codex-pane"; $5="blocked"}
    {print}
  ' "$HERDR_STATE/panes.tsv" > "$HERDR_STATE/panes.next"
  mv "$HERDR_STATE/panes.next" "$HERDR_STATE/panes.tsv"
  : > "$HERDR_LOG"
  out=$(run_cockpit panel) || fail "cockpit panel could not render the live frame"
  assert_contains "$out" "ORCHESTRATION COCKPIT" "cockpit panel omitted its heading"
  assert_contains "$out" "NAVIGATOR Herdr sidebar (all spaces and agents)" \
    "cockpit panel did not identify its live navigator"
  assert_contains "$out" "PINNED firstmate head=w1:p1 [live]" \
    "cockpit panel did not identify the pinned controller"
  assert_contains "$out" "VIEWPORT tab=w1:t1" \
    "cockpit panel did not identify the persistent viewport"
  assert_contains "$out" "fm-claude-pane [working]" \
    "cockpit panel omitted the Herdr status for the Claude viewport worker"
  assert_contains "$out" "fm-codex-pane [blocked]" \
    "cockpit panel omitted the Herdr status for the Codex viewport worker"
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
  assert_contains "$log" "pane split w1:p9 --direction right --ratio 0.25" \
    "explicit clean-context adoption did not establish its fleet column"
  assert_not_contains "$log" "pane close" "clean-context adoption closed the prior head"
  pass "dead head stays visible until explicit clean-context re-adoption"
}

test_frame_re_adoption_is_idempotent
test_space_switch_focuses_one_complete_frame_and_rejects_nesting
test_adoption_requires_the_native_session_socket
test_workers_land_in_persistent_viewport
test_display_and_steer_boundary_remains_explicit
test_panel_renders_the_live_frame_and_fleet_view
test_panel_degrades_visibly_outside_herdr
test_dead_head_is_preserved_until_explicit_new_context
