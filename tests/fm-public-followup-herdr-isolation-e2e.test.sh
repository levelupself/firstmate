#!/usr/bin/env bash
# Real-Herdr regression for public-followup startup-test isolation.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
SESSION=$("$LAB_HELPER" name public-followup-isolation)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-public-followup-herdr.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
CLEANED=0

cleanup() {
  local status=0
  [ "$CLEANED" -eq 0 ] || return 0
  CLEANED=1
  "$LAB_HELPER" teardown "$SESSION" || status=$?
  rm -rf "$TMP_ROOT"
  return "$status"
}

on_exit() {
  local status=$?
  cleanup || status=$?
  trap - EXIT
  exit "$status"
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || fail "jq not found"

trap on_exit EXIT
"$LAB_HELPER" provision "$SESSION" || fail "could not provision the guarded Herdr lab"
lab() { "$LAB_HELPER" run "$SESSION" "$@"; }

mkdir -p "$TMP_ROOT/controller" "$FAKEBIN"
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

created=$(lab workspace create --cwd "$TMP_ROOT/controller" --label firstmate --no-focus) \
  || fail "could not create the isolated controller workspace"
workspace=$(printf '%s' "$created" | jq -r '.result.workspace.workspace_id // empty')
tab=$(printf '%s' "$created" | jq -r '.result.tab.tab_id // empty')
head=$(printf '%s' "$created" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$workspace" ] && [ -n "$tab" ] && [ -n "$head" ] \
  || fail "the controller workspace returned incomplete identity"
lab pane report-agent "$head" --source public-followup-isolation \
  --agent firstmate --state idle >/dev/null \
  || fail "could not publish the isolated controller identity"
socket=$(lab session list --json \
  | jq -r --arg session "$SESSION" '.sessions[]? | select(.name == $session) | .socket_path')
[ -n "$socket" ] || fail "could not resolve the guarded lab socket"

pane_inventory() {
  lab pane list --workspace "$workspace" | jq -c '
    [.result.panes[] | {pane_id,tab_id,foreground_cwd,label}] | sort_by(.pane_id)
  '
}

baseline=$(pane_inventory) || fail "could not capture the baseline pane inventory"
for run in 1 2; do
  log="$TMP_ROOT/public-followup-$run.log"
  if ! env PATH="$FAKEBIN:$PATH" \
    FM_COCKPIT_LAB_HELPER="$LAB_HELPER" FM_COCKPIT_LAB_SESSION="$SESSION" \
    HERDR_ENV=1 HERDR_SESSION="$SESSION" HERDR_SOCKET_PATH="$socket" \
    HERDR_WORKSPACE_ID="$workspace" HERDR_TAB_ID="$tab" HERDR_PANE_ID="$head" \
    bash "$ROOT/tests/fm-public-followup.test.sh" > "$log" 2>&1; then
    fail "public-followup run $run failed: $(tail -20 "$log")"
  fi
  after=$(pane_inventory) || fail "could not inspect panes after public-followup run $run"
  [ "$after" = "$baseline" ] \
    || fail "public-followup run $run leaked live cockpit panes or deleted-cwd processes"$'\n'"baseline=$baseline"$'\n'"after=$after"
done

pass "two public-followup runs leave no live cockpit panes or deleted-cwd processes"
