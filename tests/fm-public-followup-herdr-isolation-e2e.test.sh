#!/usr/bin/env bash
# Real-Herdr regression for public-followup startup-test isolation.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
SESSION=$("$LAB_HELPER" name public-followup-isolation)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-public-followup-herdr.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
CLEANED=0

cleanup_targets() {
  local helper=$1 session=$2 fixture=$3
  "$helper" teardown "$session" || return $?
  rm -rf "$fixture"
}

cleanup() {
  [ "$CLEANED" -eq 0 ] || return 0
  cleanup_targets "$LAB_HELPER" "$SESSION" "$TMP_ROOT" || return $?
  CLEANED=1
}

test_failed_teardown_preserves_fixture() {
  local fixture="$TMP_ROOT/teardown-failure-fixture" helper="$TMP_ROOT/failing-lab-helper" rc=0
  mkdir -p "$fixture"
  printf '%s\n' diagnostic > "$fixture/evidence"
  cat > "$helper" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = teardown ] || exit 2
exit 19
SH
  chmod +x "$helper"
  cleanup_targets "$helper" fm-lab-cleanup-test "$fixture" || rc=$?
  [ "$rc" -eq 19 ] || fail "the teardown-failure fixture returned $rc instead of 19"
  [ -f "$fixture/evidence" ] || fail "failed teardown removed diagnostic fixture state"
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
test_failed_teardown_preserves_fixture
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
baseline_ids=$(printf '%s' "$baseline" | jq -r '.[].pane_id')

close_created_panes() {
  local ids=$1 pane status=0
  while IFS= read -r pane; do
    [ -n "$pane" ] || continue
    lab pane close "$pane" >/dev/null 2>&1 || status=1
  done <<< "$ids"
  return "$status"
}

deleted_cwd_processes() {
  local fixture=$1 cwd
  for cwd in /proc/[0-9]*/cwd; do
    [ -L "$cwd" ] || continue
    case "$(readlink "$cwd" 2>/dev/null || true)" in
      "$fixture"*' (deleted)') printf '%s\n' "${cwd#/proc/}" ;;
    esac
  done
}

run_scenario() {
  local scenario=$1 expected=$2 fixture log rc=0 after created_ids remaining leaked
  fixture="$TMP_ROOT/fixture-$scenario-$RANDOM"
  log="$TMP_ROOT/public-followup-$scenario.log"
  mkdir -p "$fixture"
  env PATH="$FAKEBIN:$PATH" \
    FM_COCKPIT_LAB_HELPER="$LAB_HELPER" FM_COCKPIT_LAB_SESSION="$SESSION" \
    HERDR_ENV=1 HERDR_SESSION="$SESSION" HERDR_SOCKET_PATH="$socket" \
    HERDR_WORKSPACE_ID="$workspace" HERDR_TAB_ID="$tab" HERDR_PANE_ID="$head" \
    FM_TEST_PUBLIC_FOLLOWUP_TMP_ROOT="$fixture" \
    FM_TEST_PUBLIC_FOLLOWUP_HERDR_STARTUP=1 \
    FM_TEST_PUBLIC_FOLLOWUP_HERDR_SCENARIO="$scenario" \
    bash "$ROOT/tests/fm-public-followup.test.sh" > "$log" 2>&1 || rc=$?
  after=$(pane_inventory) || fail "could not inspect panes after $scenario"
  created_ids=$(jq -nr --argjson after "$after" --arg baseline "$baseline_ids" '
    ($baseline | split("\n") | map(select(length > 0))) as $before
    | $after | map(.pane_id) | map(select(. as $id | $before | index($id) | not))[]
  ')
  [ -n "$created_ids" ] || fail "$scenario bypassed Herdr cockpit pane creation: $(tail -20 "$log")"
  close_created_panes "$created_ids" || fail "$scenario could not close every created pane"
  remaining=$(pane_inventory) || fail "could not inspect panes after $scenario cleanup"
  [ "$remaining" = "$baseline" ] \
    || fail "$scenario did not restore the exact baseline pane inventory"
  rm -rf "$fixture"
  leaked=$(deleted_cwd_processes "$fixture")
  [ -z "$leaked" ] || fail "$scenario retained deleted fixture cwd processes: $leaked"
  [ "$rc" -eq "$expected" ] \
    || fail "$scenario returned $rc instead of $expected: $(tail -20 "$log")"
}

run_scenario success 0
run_scenario success 0
run_scenario failure 17
run_scenario early-exit 23

pass "repeated, failed, and early-exit startups restore panes before fixture deletion"
