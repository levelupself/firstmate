#!/usr/bin/env bash
# Behavior tests for the Herdr-only orchestration cockpit frame.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

COCKPIT="$ROOT/bin/fm-cockpit.sh"
TMP_ROOT=$(fm_test_tmproot fm-cockpit)
HOME_DIR="$TMP_ROOT/home"
FAKE_DIR="$TMP_ROOT/fake"
FAKEBIN=$(fm_fakebin "$FAKE_DIR")
HERDR_STATE="$FAKE_DIR/herdr-state"
HERDR_LOG="$FAKE_DIR/herdr.log"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$HOME_DIR/projects" "$HERDR_STATE"
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
  "tab list")
    printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"cockpit"}]}}'
    ;;
  "pane list")
    jq -Rn '
      [inputs | split("\t")
       | {pane_id:.[0],label:.[1],tab_id:.[2],workspace_id:.[3],agent_status:(if .[4] == "live" then "idle" else "unknown" end)}]
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
  *)
    printf 'unexpected fake herdr call: %s\n' "$*" >&2
    exit 1
    ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

run_cockpit() {
  PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_DIR" \
    FM_FAKE_HERDR_STATE="$HERDR_STATE" \
    FM_FAKE_HERDR_LOG="$HERDR_LOG" \
    HERDR_ENV=1 \
    HERDR_SESSION=fmtest \
    HERDR_WORKSPACE_ID=w1 \
    HERDR_TAB_ID=w1:t1 \
    HERDR_PANE_ID=w1:p1 \
    "$COCKPIT" "$1"
}

test_frame_re_adoption_is_idempotent() {
  local first second before after log
  first=$(run_cockpit adopt) || fail "first cockpit adoption failed"
  assert_contains "$first" "adopted Herdr frame" "first adoption did not report its frame"
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
  [ "$first" = "w1:t1 w1:p2" ] || fail "first cockpit task returned unexpected ids: $first"
  log=$(cat "$HERDR_LOG")
  assert_contains "$log" "pane split w1:p1 --direction right --ratio 0.67" \
    "first child did not split right from the pinned head"
  assert_not_contains "$log" "tab create" "first child minted a peer tab"
  assert_grep 'viewport_pane_id=w1:p2' "$HOME_DIR/state/.herdr-cockpit" \
    "first child did not become the durable viewport anchor"

  : > "$HERDR_LOG"
  second=$(place_task fm-two) || fail "second cockpit task placement failed"
  [ "$second" = "w1:t1 w1:p3" ] || fail "second cockpit task returned unexpected ids: $second"
  log=$(cat "$HERDR_LOG")
  assert_contains "$log" "pane split w1:p2 --direction down --ratio 0.5" \
    "later child did not stay within the persistent viewport"
  assert_not_contains "$log" "tab create" "later child minted a peer tab"
  assert_grep 'viewport_pane_id=w1:p3' "$HOME_DIR/state/.herdr-cockpit" \
    "latest child did not advance the viewport anchor"

  live=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" \
    FM_FAKE_HERDR_STATE="$HERDR_STATE" FM_FAKE_HERDR_LOG="$HERDR_LOG" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_list_live fmtest' "$ROOT")
  assert_contains "$live" $'fmtest:w1:p2\tfm-one' "recovery inventory missed the first split-pane task"
  assert_contains "$live" $'fmtest:w1:p3\tfm-two' "recovery inventory missed the second split-pane task"
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

  out=$(env -u HERDR_ENV -u TMUX FM_HOME="$HOME_DIR" "$COCKPIT" status) \
    || fail "non-Herdr cockpit fallback should remain usable"
  assert_contains "$out" "unavailable on runtime backend none" "non-Herdr fallback was silent"
  assert_contains "$out" "fm-fleet-view.sh --watch" "non-Herdr fallback omitted the plain live panel"
  pass "whole-session display remains distinct from explicit home-scoped steering"
}

test_frame_re_adoption_is_idempotent
test_workers_land_in_persistent_viewport
test_frame_re_adoption_is_idempotent
test_display_and_steer_boundary_remains_explicit
