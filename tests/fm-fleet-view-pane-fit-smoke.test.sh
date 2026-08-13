#!/usr/bin/env bash
# tests/fm-fleet-view-pane-fit-smoke.test.sh - real-terminal pane fit for the
# fleet panel and the cockpit panel.
#
# Every other panel test supplies LINES/COLUMNS, which takes the explicit
# override branch and never exercises the measurement a real pane depends on.
# A banner pane sets neither, so this is the one suite that renders into an
# actual short pane and checks what the operator would see. It uses a real tmux
# server on a private socket (`-L`) so it never touches the host's sessions.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-fleet-view-pane-fit)
HOME_DIR="$TMP_ROOT/home"
SOCKET=fm-pane-fit-$$
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/projects" "$HOME_DIR/config"

kill_server() { tmux -L "$SOCKET" kill-server 2>/dev/null || true; }
cleanup() {
  kill_server
  fm_test_cleanup
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

cat > "$HOME_DIR/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF

# Enough in-flight work that the frame cannot fit a short pane.
for n in 1 2 3 4 5 6 7 8; do
  fm_write_meta "$HOME_DIR/state/demo$n.meta" \
    "window=fmpane:fm-demo$n" "backend=tmux" "endpoint_task_id=demo$n" \
    "kind=crew" "mode=no-mistakes"
  printf 'working: step %s\n' "$n" > "$HOME_DIR/state/demo$n.status"
done

PANE_ROWS=

pane_rows() {  # <command> <rows> -> set PANE_ROWS to the pane's visible rows
  local command=$1 rows=$2
  kill_server
  tmux -L "$SOCKET" new-session -d -s fit -x 60 -y "$rows" "$command" \
    || fail "could not start a ${rows}-row pane"
  local waited=0 out=
  while [ "$waited" -lt 60 ]; do
    out=$(tmux -L "$SOCKET" capture-pane -p -t fit:0.0 2>/dev/null \
      | sed 's/[[:space:]]*$//')
    case "$out" in *[![:space:]]*) break ;; esac
    sleep 0.1
    waited=$((waited + 1))
  done
  PANE_ROWS=$out
  kill_server
}

test_fleet_panel_fits_a_short_pane_without_scrolling_its_head() {
  local out visible
  pane_rows "FM_HOME=$HOME_DIR $ROOT/bin/fm-fleet-view.sh --watch 1" 12
  out=$PANE_ROWS
  # The head is the panel's whole point: the first physical row must still be
  # the top of the frame, not whatever survived a scroll.
  [ "$(printf '%s\n' "$out" | head -1)" = "$(printf '=%.0s' $(seq 1 60))" ] \
    || fail "the panel's first row was not the top of the frame: $(printf '%s\n' "$out" | head -1)"
  assert_contains "$out" "FLEET STATUS" "a short pane lost the panel title"
  assert_contains "$out" "YOUR DECISIONS" "a short pane scrolled the decisions section away"
  assert_contains "$out" "more rows not shown" \
    "a short pane silently dropped rows instead of disclosing them"
  visible=$(printf '%s\n' "$out" | sed '/^$/d' | wc -l)
  [ "$visible" -le 12 ] || fail "the panel painted $visible rows into a 12-row pane"
  pass "the fleet panel fits a short pane, keeps its head, and discloses the truncated tail"
}

test_fleet_panel_uses_the_whole_pane_when_it_fits() {
  local out
  pane_rows "FM_HOME=$HOME_DIR $ROOT/bin/fm-fleet-view.sh --watch 1" 30
  out=$PANE_ROWS
  assert_contains "$out" "FLEET STATUS" "a tall pane lost the panel title"
  assert_contains "$out" "IN FLIGHT (8)" "a tall pane lost the in-flight section"
  assert_contains "$out" "demo8" "a tall pane truncated work it had room for"
  assert_not_contains "$out" "more rows not shown" \
    "a tall pane truncated a frame that already fitted"
  pass "the fleet panel uses the whole pane when the frame fits"
}

test_cockpit_panel_fits_a_short_pane_as_one_frame() {
  local out visible
  pane_rows "FM_HOME=$HOME_DIR $ROOT/bin/fm-cockpit.sh panel --watch 1" 12
  out=$PANE_ROWS
  # The cockpit header and the fleet view are one frame: budgeting them
  # separately fits each and overflows their sum, which scrolls the header off.
  [ "$(printf '%s\n' "$out" | head -1)" = "ORCHESTRATION COCKPIT" ] \
    || fail "the cockpit panel scrolled its own header away: $(printf '%s\n' "$out" | head -1)"
  assert_contains "$out" "BOUNDARY display=all-homes" \
    "the cockpit panel lost its display and steer boundary"
  assert_contains "$out" "FLEET STATUS" "the cockpit panel lost the fleet view entirely"
  visible=$(printf '%s\n' "$out" | sed '/^$/d' | wc -l)
  [ "$visible" -le 12 ] || fail "the cockpit panel painted $visible rows into a 12-row pane"
  pass "the cockpit panel fits a short pane as one frame, header first"
}

test_fleet_panel_fits_a_short_pane_without_scrolling_its_head
test_fleet_panel_uses_the_whole_pane_when_it_fits
test_cockpit_panel_fits_a_short_pane_as_one_frame
