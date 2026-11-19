#!/usr/bin/env bash
# Opt-in credentialed Claude live regression for the tool-boundary progress
# marker (state/<id>.turn-progress) that fm-watch.sh's busy-turn bound ages.
# Proves, against the real installed Claude Code and the hook settings the real
# bin/fm-spawn.sh generates, that the marker is touched at the end of a
# successful tool call, at the end of a failing tool call, and for a subagent's
# own tool call, and that nothing touches it while a single call is still
# running - the distinction between a long healthy turn and a hung call.
# The project, worktree, and FM_HOME are isolated scratch; Claude keeps using its
# existing managed authentication and loads only the generated local settings.
# Disposition: MANUAL-ONLY. Standard CI has neither the Claude binary nor its
# credentials, so run it on demand after Claude upgrades and before refreshing
# the dated evidence in docs/verification/supervision.md.
set -u

if [ "${FM_CLAUDE_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CLAUDE_LIVE_E2E=1 to run the Claude tool-boundary progress regression"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLAUDE_BIN=$(command -v claude || true)
[ -n "$CLAUDE_BIN" ] || fail "claude not found: the tool-boundary progress guard checked nothing"
command -v jq >/dev/null 2>&1 || fail "jq not found"
CLAUDE_VERSION=$("$CLAUDE_BIN" --version)
command -v perl >/dev/null 2>&1 || fail "claude $CLAUDE_VERSION guard requires perl"
MODEL=${FM_CLAUDE_LIVE_MODEL:-claude-haiku-4-5-20251001}
TMP_ROOT=$(fm_test_tmproot fm-claude-tool-progress-live)
ID=progress-live
SAMPLER=

# Millisecond mtime of <file>, from GNU or BSD stat's fractional seconds.
mtime_ms() {  # <file>
  local m
  if [ "$(uname)" = Darwin ]; then m=$(stat -f %Fm "$1"); else m=$(stat -c %.3Y "$1"); fi || return 1
  awk -v m="$m" 'BEGIN { printf "%.0f\n", m * 1000 }'
}

cleanup() {
  [ -z "$SAMPLER" ] || { kill "$SAMPLER" 2>/dev/null || true; wait "$SAMPLER" 2>/dev/null || true; }
}
trap cleanup EXIT

# Real fm-spawn against a fake tmux pane, as tests/fm-busy-adapter-wiring.test.sh
# does, so the settings under test are exactly what a worker launch writes.
CASE_DIR="$TMP_ROOT/case"
HOME_DIR="$CASE_DIR/home"
PROJ_DIR="$CASE_DIR/project"
WT_DIR="$CASE_DIR/wt"
FAKEBIN=$(fm_fakebin "$CASE_DIR/fake")
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/tmux"
fm_fake_pane_shell "$FAKEBIN/tmux"
fm_fake_exit0 "$FAKEBIN" claude
fm_fake_treehouse_lease "$FAKEBIN"
mkdir -p "$HOME_DIR/data/$ID" "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config"
printf 'claude\n' > "$HOME_DIR/config/crew-harness"
fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-progress-live"
touch "$HOME_DIR/state/.last-watcher-beat"
printf 'brief for %s\n' "$ID" > "$HOME_DIR/data/$ID/brief.md"
fm_test_backlog_queue "$HOME_DIR" "$ID"
out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
  FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
  FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" PATH="$FAKEBIN:$PATH" \
  "$ROOT/bin/fm-spawn.sh" "$ID" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1) \
  || fail "fm-spawn could not generate the Claude settings: $out"
SETTINGS="$WT_DIR/.claude/settings.local.json"
[ -f "$SETTINGS" ] || fail "fm-spawn wrote no Claude settings"
STATE_REAL=$(cd "$HOME_DIR/state" && pwd -P)
MARKER="$STATE_REAL/$ID.turn-progress"
rm -f "$MARKER"

# Sample the marker's mtime; every distinct value is one observed touch.
TOUCHES="$CASE_DIR/touches"
: > "$TOUCHES"
(
  prev=
  while :; do
    m=$(mtime_ms "$MARKER" 2>/dev/null || true)
    if [ -n "$m" ] && [ "$m" != "$prev" ]; then printf '%s\n' "$m" >> "$TOUCHES"; prev=$m; fi
    sleep 0.05
  done
) &
SAMPLER=$!

MARKS="$CASE_DIR/marks"
mkdir -p "$MARKS"
CLOCK="perl -MTime::HiRes=time -e 'printf \"%.0f\\n\", time*1000'"
prompt="Do exactly these steps in order, then reply DONE. Do not run any other tools.
1) Use one Bash call to run: $CLOCK > '$MARKS/a-start'; sleep 8; $CLOCK > '$MARKS/a-end'
2) Use one Bash call to run: $CLOCK > '$MARKS/b-start'; sleep 4; $CLOCK > '$MARKS/b-end'; exit 3
3) Use one Bash call to run only: $CLOCK > '$MARKS/after-b-start'
4) Use the Agent tool to launch a general-purpose subagent whose only job is to run exactly two sequential Bash calls and then return. Its first Bash call must run: $CLOCK > '$MARKS/c-start'; sleep 3; $CLOCK > '$MARKS/c-end'
Its second Bash call must run only: sleep 3"
(cd "$WT_DIR" && timeout 300 "$CLAUDE_BIN" -p --model "$MODEL" --setting-sources local \
  --permission-mode bypassPermissions "$prompt") > "$CASE_DIR/claude.out" 2>&1 \
  || fail "claude $CLAUDE_VERSION run failed: $(tail -5 "$CASE_DIR/claude.out")"
sleep 1
kill "$SAMPLER" 2>/dev/null || true; wait "$SAMPLER" 2>/dev/null || true; SAMPLER=

for f in a-start a-end b-start b-end after-b-start c-start c-end; do
  [ -s "$MARKS/$f" ] || fail "claude $CLAUDE_VERSION did not run step $f; the guard checked nothing: $(tail -5 "$CASE_DIR/claude.out")"
done
[ -s "$TOUCHES" ] || fail "claude $CLAUDE_VERSION never touched the tool-boundary marker"

touched_within() {
  awk -v lo="$1" -v hi="$2" -v required="${3:-1}" '$1 >= lo && $1 <= hi { seen[$1]=1 } END { for (m in seen) count++; exit count < required }' "$TOUCHES"
}
a_start=$(cat "$MARKS/a-start"); a_end=$(cat "$MARKS/a-end")
b_start=$(cat "$MARKS/b-start"); b_end=$(cat "$MARKS/b-end")
after_b_start=$(cat "$MARKS/after-b-start"); c_end=$(cat "$MARKS/c-end")
touched_within $(( a_start + 500 )) $(( a_end - 500 )) \
  && fail "claude $CLAUDE_VERSION touched the marker while a single tool call was still running: $(tr '\n' ' ' < "$TOUCHES")"
touched_within "$a_end" "$b_start" 2 \
  || fail "claude $CLAUDE_VERSION PostToolUse did not touch the marker when a successful call ended: $(tr '\n' ' ' < "$TOUCHES")"
touched_within "$b_end" "$after_b_start" 2 \
  || fail "claude $CLAUDE_VERSION PostToolUseFailure did not touch the marker when a failing call ended: $(tr '\n' ' ' < "$TOUCHES")"
touched_within "$c_end" $(( c_end + 1000 )) \
  || fail "claude $CLAUDE_VERSION did not touch the marker for a subagent's tool call: $(tr '\n' ' ' < "$TOUCHES")"
pass "claude $CLAUDE_VERSION touches the tool-boundary progress marker at every successful, failing, and subagent tool call end, and never mid-call"
