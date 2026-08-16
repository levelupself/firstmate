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

FAKE_CODEBURN="$TMP_ROOT/codeburn"
cat > "$FAKE_CODEBURN" <<'EOF'
#!/usr/bin/env bash
printf '{}\n'
EOF
chmod +x "$FAKE_CODEBURN"

kill_server() { tmux -L "$SOCKET" kill-server 2>/dev/null || true; }
pane_fit_cleanup() {
  kill_server
  fm_test_cleanup
}
trap pane_fit_cleanup EXIT
trap 'pane_fit_cleanup; exit 130' INT
trap 'pane_fit_cleanup; exit 143' TERM

[ -d "$HOME_DIR/state" ] \
  || fail "the pane fixture disappeared while its cleanup handler was registered"

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

pane_rows() {  # <command> <rows> <frame-marker> -> the pane's visible rows
  local command=$1 rows=$2 frame_marker=$3
  kill_server
  tmux -L "$SOCKET" new-session -d -s fit -x 60 -y "$rows" "$command" \
    || fail "could not start a ${rows}-row pane"
  local waited=0 out=
  while [ "$waited" -lt 60 ]; do
    out=$(tmux -L "$SOCKET" capture-pane -p -t fit:0.0 2>/dev/null \
      | sed 's/[[:space:]]*$//')
    case "$out" in *"$frame_marker"*) break ;; esac
    sleep 0.1
    waited=$((waited + 1))
  done
  printf '%s\n' "$out"
  kill_server
}

pane_rows_with_drawn_geometry() {  # <command> <pty-cols> <drawn-cols> <drawn-rows>
  local command=$1 pty_cols=$2 drawn_cols=$3 drawn_rows=$4 pane out waited=0 window_cols
  window_cols=$pty_cols
  [ "$window_cols" -gt "$drawn_cols" ] || window_cols=$((drawn_cols * 2))
  kill_server
  tmux -L "$SOCKET" new-session -d -s fit -x "$window_cols" -y "$drawn_rows" "sleep 30" \
    || fail "could not start the geometry-mismatch window"
  pane=$(tmux -L "$SOCKET" split-window -d -h -l "$drawn_cols" -P -F '#{pane_id}' \
    -t fit:0 "bash") || fail "could not create the drawn fleet rectangle"
  # Deliberately put the new pane's pty back at the wider parent size. This is
  # the Herdr defect's real counterfactual: only the authoritative drawn budget
  # changes while the lying pty stays wide.
  tmux -L "$SOCKET" send-keys -t "$pane" "stty cols $pty_cols rows 17; $command" Enter
  while [ "$waited" -lt 60 ]; do
    out=$(tmux -L "$SOCKET" capture-pane -p -t "$pane" 2>/dev/null \
      | sed 's/[[:space:]]*$//')
    case "$out" in *"IN FLIGHT"*) break ;; esac
    sleep 0.1
    waited=$((waited + 1))
  done
  # Watch mode must consult geometry again rather than caching the first frame.
  sleep 7
  out=$(tmux -L "$SOCKET" capture-pane -p -t "$pane" 2>/dev/null \
    | sed 's/[[:space:]]*$//')
  printf '%s\n' "$out"
  kill_server
}

test_fleet_panel_fits_a_short_pane_without_scrolling_its_head() {
  local out visible
  out=$(pane_rows "FM_CODEBURN_BIN=$FAKE_CODEBURN FM_HOME=$HOME_DIR $ROOT/bin/fm-fleet-view.sh --watch 1" 12 "FLEET STATUS")
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
  out=$(pane_rows "FM_CODEBURN_BIN=$FAKE_CODEBURN FM_HOME=$HOME_DIR $ROOT/bin/fm-fleet-view.sh --watch 1" 30 "FLEET STATUS")
  assert_contains "$out" "FLEET STATUS" "a tall pane lost the panel title"
  assert_contains "$out" "IN FLIGHT (8)" "a tall pane lost the in-flight section"
  assert_contains "$out" "demo8" "a tall pane truncated work it had room for"
  assert_not_contains "$out" "more rows not shown" \
    "a tall pane truncated a frame that already fitted"
  pass "the fleet panel uses the whole pane when the frame fits"
}

test_drawn_geometry_overrides_a_wider_pty_on_every_frame() {
  local geometry geometry_count out widest visible waited=0
  geometry="$TMP_ROOT/drawn-geometry"
  geometry_count="$TMP_ROOT/drawn-geometry-count"
  cat > "$geometry" <<'EOF'
#!/usr/bin/env bash
count=0
[ ! -f "$FM_TEST_GEOMETRY_COUNT" ] || count=$(cat "$FM_TEST_GEOMETRY_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$FM_TEST_GEOMETRY_COUNT"
if [ "$count" -eq 1 ]; then
  printf '18 6\n'
else
  printf '14 4\n'
fi
EOF
  chmod +x "$geometry"
  out=$(pane_rows_with_drawn_geometry \
    "FM_TEST_GEOMETRY_COUNT=$geometry_count FM_CODEBURN_BIN=$FAKE_CODEBURN FM_HOME=$HOME_DIR $ROOT/bin/fm-fleet-view.sh --geometry-command $geometry --watch 1 --section in-flight" \
    54 18 6)
  while [ "$waited" -lt 30 ] && [ "$(cat "$geometry_count" 2>/dev/null || printf 0)" -lt 2 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  widest=$(printf '%s\n' "$out" | jq -Rrs 'split("\n") | map(length) | max')
  visible=$(printf '%s\n' "$out" | sed '/^$/d' | wc -l)
  [ "$(cat "$geometry_count" 2>/dev/null || printf 0)" -ge 2 ] \
    || fail "the painter did not re-read drawn geometry on its next redraw"
  [ "$widest" -le 14 ] \
    || fail "the painter emitted a $widest-column row after the drawn rectangle narrowed to 14 columns: $out"
  [ "$visible" -le 4 ] \
    || fail "the painter emitted $visible rows after the drawn rectangle shortened to 4 rows"
  assert_contains "$out" "more rows" \
    "the drawn-height budget did not disclose the clipped tail"
  pass "authoritative drawn geometry bounds every redraw even while its pty reports a larger size"
}

test_overflow_summary_is_width_clipped_without_scrolling_the_head() {
  local geometry out first widest
  geometry="$TMP_ROOT/narrow-geometry"
  cat > "$geometry" <<'EOF'
#!/usr/bin/env bash
printf '21 8\n'
EOF
  chmod +x "$geometry"
  out=$(pane_rows_with_drawn_geometry \
    "FM_CODEBURN_BIN=$FAKE_CODEBURN FM_HOME=$HOME_DIR $ROOT/bin/fm-fleet-view.sh --geometry-command $geometry --watch 1 --section in-flight" \
    21 21 8)
  first=$(printf '%s\n' "$out" | head -1)
  widest=$(printf '%s\n' "$out" | jq -Rrs 'split("\n") | map(length) | max')
  [ "$first" = "IN FLIGHT (8)" ] \
    || fail "the overflow summary wrapped and scrolled the frame head to: $first"
  [ "$widest" -le 21 ] \
    || fail "the overflow summary allowed a $widest-column physical row in a 21-column pane"
  assert_contains "$out" "more rows" "the clipped overflow summary lost its meaning"
  pass "the overflow summary is clipped to the drawn width and cannot scroll a fitted frame"
}

test_cockpit_panel_fits_a_short_pane_as_one_frame() {
  local out visible
  out=$(pane_rows "FM_CODEBURN_BIN=$FAKE_CODEBURN FM_HOME=$HOME_DIR $ROOT/bin/fm-cockpit.sh panel --watch 1" 12 "ORCHESTRATION COCKPIT")
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
test_drawn_geometry_overrides_a_wider_pty_on_every_frame
test_overflow_summary_is_width_clipped_without_scrolling_the_head
test_cockpit_panel_fits_a_short_pane_as_one_frame
